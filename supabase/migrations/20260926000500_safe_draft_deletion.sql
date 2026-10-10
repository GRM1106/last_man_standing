-- Delete disposable draft data in dependency order without weakening historical
-- foreign keys, immutable-history triggers or browser-role permissions.
begin;
create or replace function public.delete_draft_pot(selected_pot_id uuid, confirmation_name text)
returns void language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;

  -- Match competition/schedule serialisation. Lock deadlines before the pot:
  -- player confirmation already locks its deadline before inserting a pick.
  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),-2);
  perform 1 from public.pot_gameweeks where pot_id=selected_pot_id order by gameweek_number for update;
  select * into selected_pot from public.pots where id=selected_pot_id for update;
  if not found then raise exception 'Pot not found'; end if;
  if selected_pot.status<>'draft' then raise exception 'Only draft pots can be deleted'; end if;
  if confirmation_name is distinct from selected_pot.name then raise exception 'Pot name confirmation did not match'; end if;
  if selected_pot.lifecycle_status<>'setup' or selected_pot.membership_locked_at is not null then
    raise exception 'Only an unlocked setup draft can be deleted';
  end if;
  perform 1 from public.pot_rounds where pot_id=selected_pot_id order by sequence_number for update;
  if exists(select 1 from public.pot_rounds where pot_id=selected_pot_id and cohort_finalized_at is not null)
    or exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id)
    or exists(select 1 from public.player_picks where pot_id=selected_pot_id and outcome<>'pending')
    or exists(select 1 from public.pot_completions where pot_id=selected_pot_id)
    or exists(select 1 from public.pot_player_status_history where pot_id=selected_pot_id)
    or exists(select 1 from public.round_collective_reinstatements where pot_id=selected_pot_id)
    or exists(select 1 from public.pot_player_buyback_events where pot_id=selected_pot_id)
    or exists(select 1 from public.lms_review_cases where pot_id=selected_pot_id)
    or exists(select 1 from public.lms_automation_runs where pot_id=selected_pot_id) then
    raise exception 'A draft with competition or review history cannot be deleted';
  end if;

  -- Reset can leave normal, unfinalised cohort entries. Remove pending picks
  -- before those entries, and rounds before their gameweeks/memberships cascade.
  delete from public.player_picks where pot_id=selected_pot_id;
  delete from public.pot_round_players where pot_id=selected_pot_id;
  delete from public.pot_rounds where pot_id=selected_pot_id;
  delete from public.pots where id=selected_pot_id;
end;
$$;
-- CREATE OR REPLACE retains the established ACL; state the browser boundary too.
revoke execute on function public.delete_draft_pot(uuid,text) from public,anon;
grant execute on function public.delete_draft_pot(uuid,text) to authenticated;
commit;
