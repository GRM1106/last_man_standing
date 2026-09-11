-- Critical #4: sensitive review ledgers are administrator-only. Member projections
-- deliberately omit reasons, evidence, snapshots, case IDs and administrator IDs.
begin;
-- Governed review also copies a case summary into pots.review_reason. The player
-- dashboard already reads an explicit safe projection through get_my_dashboard().
-- Remove this alternate direct-table leak; administrator pot queries retain access.
drop policy "Players can view assigned pots" on public.pots;
drop policy "Members see review summaries" on public.lms_review_cases;
drop policy "Members see completion adjudications" on public.pot_completion_adjudications;
drop policy "Members see adjudicated winners" on public.pot_adjudicated_winners;
revoke all on public.lms_review_cases,public.lms_review_resolution_events,
  public.pot_completion_adjudications,public.pot_adjudicated_winners from public,anon,authenticated;
grant select on public.lms_review_cases,public.lms_review_resolution_events,
  public.pot_completion_adjudications,public.pot_adjudicated_winners to authenticated;
create policy "Administrators see review cases" on public.lms_review_cases
for select to authenticated using((select public.is_current_user_admin()));
create policy "Administrators see adjudications" on public.pot_completion_adjudications
for select to authenticated using((select public.is_current_user_admin()));
create policy "Administrators see adjudicated winners" on public.pot_adjudicated_winners
for select to authenticated using((select public.is_current_user_admin()));
-- lms_review_resolution_events already has an administrator-only policy.

create or replace function public.get_my_pot_review_state(selected_pot_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
  or (select public.is_current_user_admin()) then jsonb_build_object(
    'under_review',exists(select 1 from public.lms_review_cases where pot_id=selected_pot_id and status='open'),
    'open_count',(select count(*) from public.lms_review_cases where pot_id=selected_pot_id and status='open'),
    'resolved_count',(select count(*) from public.lms_review_cases where pot_id=selected_pot_id and status='resolved'),
    'dismissed_count',(select count(*) from public.lms_review_cases where pot_id=selected_pot_id and status='dismissed'),
    'cases',case when (select public.is_current_user_admin()) then coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'type',case_type,'status',status,'summary',summary,'opened_at',opened_at,'round_id',source_round_id,
      'fixture_id',fixture_id,'player_id',player_id,'evidence',evidence,'impact',impact_snapshot) order by opened_at)
      from public.lms_review_cases where pot_id=selected_pot_id),'[]') else '[]'::jsonb end)
  else null end;
$$;
revoke all on function public.get_my_pot_review_state(uuid) from public,anon;
grant execute on function public.get_my_pot_review_state(uuid) to authenticated;

-- Replaces direct member access to adjudication rows with their public outcome only.
-- This does not change the existing completion UI or its original-history semantics.
create function public.get_my_pot_review_outcome(selected_pot_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
  or (select public.is_current_user_admin()) then (
    select jsonb_build_object('revision',a.revision_number,'decided_at',a.created_at,
      'total_prize_pence',a.original_total_prize_pence,'winners',coalesce((
        select jsonb_agg(jsonb_build_object(
          'name',coalesce(nullif(trim(concat_ws(' ',p.first_name,p.last_name)),''),p.display_name,'Player'),
          'is_me',w.player_id=(select auth.uid()),'prize_share_pence',w.prize_share_pence) order by w.share_order)
        from public.pot_adjudicated_winners w join public.profiles p on p.id=w.player_id
        where w.adjudication_id=a.id),'[]'::jsonb))
    from public.pot_completion_adjudications a where a.pot_id=selected_pot_id order by a.revision_number desc limit 1
  ) else null end;
$$;
revoke all on function public.get_my_pot_review_outcome(uuid) from public,anon;
grant execute on function public.get_my_pot_review_outcome(uuid) to authenticated;
commit;
