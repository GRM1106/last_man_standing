-- Phase 2A: lifecycle foundation, permanent membership lock, and eligibility decoupling.
-- Requires P1, P2, and 20260823000100_lms_integrity_phase_1.sql.
begin;

do $$ begin
  if to_regprocedure('public.current_pot_gameweek(uuid)') is null
    or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='pot_gameweeks' and column_name='pick_deadline_at') then
    raise exception 'Phase 2A requires the Phase 1 integrity migration';
  end if;
end $$;

alter table public.pots add column lifecycle_status text;
alter table public.pots add column membership_locked_at timestamptz;
alter table public.pots add constraint pots_lifecycle_status_check
  check(lifecycle_status in ('setup','open','in_progress','review','complete'));

update public.pots set lifecycle_status=case
  when status='draft' then 'setup' when status='open' then 'open'
  when status='active' then 'in_progress' else 'complete' end;
alter table public.pots alter column lifecycle_status set not null;
alter table public.pots alter column lifecycle_status set default 'setup';

update public.pots pot set membership_locked_at=(select min(gameweek.pick_deadline_at)
  from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id)
where (select min(gameweek.pick_deadline_at) from public.pot_gameweeks gameweek
  where gameweek.pot_id=pot.id)<=now();

create or replace function public.lock_pot_membership_if_due(selected_pot_id uuid)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare stored_lock timestamptz; declare first_deadline timestamptz;
begin
  select membership_locked_at into stored_lock from public.pots where id=selected_pot_id for update;
  if not found then raise exception 'Pot not found'; end if;
  if stored_lock is not null then return stored_lock; end if;
  select min(pick_deadline_at) into first_deadline from public.pot_gameweeks where pot_id=selected_pot_id;
  if first_deadline is not null and now()>=first_deadline then
    update public.pots set membership_locked_at=first_deadline,
      lifecycle_status=case when lifecycle_status in('complete','review') then lifecycle_status else 'in_progress' end
    where id=selected_pot_id returning membership_locked_at into stored_lock;
  end if;
  return stored_lock;
end; $$;
revoke all on function public.lock_pot_membership_if_due(uuid) from public,anon,authenticated;

create or replace function public.add_player_to_pot(selected_pot_id uuid,selected_player_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype; declare first_deadline timestamptz;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),0);
  perform public.lock_pot_membership_if_due(selected_pot_id);
  select * into selected_pot from public.pots where id=selected_pot_id for update;
  if not found then raise exception 'Pot not found'; end if;
  if selected_pot.lifecycle_status not in('setup','open') then raise exception 'Membership is locked for this pot'; end if;
  if selected_pot.membership_locked_at is not null then raise exception 'Membership is permanently locked for this pot'; end if;
  select min(pick_deadline_at) into first_deadline from public.pot_gameweeks where pot_id=selected_pot_id;
  if first_deadline is not null and now()>=first_deadline then raise exception 'Membership is permanently locked for this pot'; end if;
  if not exists(select 1 from public.profiles where id=selected_player_id) then raise exception 'Player profile not found'; end if;
  insert into public.pot_players(pot_id,player_id) values(selected_pot_id,selected_player_id)
  on conflict(pot_id,player_id) do nothing;
end; $$;
revoke all on function public.add_player_to_pot(uuid,uuid) from public,anon;
grant execute on function public.add_player_to_pot(uuid,uuid) to authenticated;

create or replace function public.set_pot_lifecycle(selected_pot_id uuid,new_lifecycle text)
returns void language plpgsql security definer set search_path='' as $$
declare current_lifecycle text; declare locked_at timestamptz;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if new_lifecycle not in('setup','open') then raise exception 'Only setup and open are manual lifecycle transitions'; end if;
  locked_at:=public.lock_pot_membership_if_due(selected_pot_id);
  select lifecycle_status into current_lifecycle from public.pots where id=selected_pot_id for update;
  if current_lifecycle in('in_progress','review','complete') or locked_at is not null then
    raise exception 'A locked, reviewed, or completed pot cannot return to setup or open';
  end if;
  update public.pots set lifecycle_status=new_lifecycle,
    status=case new_lifecycle when 'setup' then 'draft' else 'open' end where id=selected_pot_id;
end; $$;
revoke all on function public.set_pot_lifecycle(uuid,text) from public,anon;
grant execute on function public.set_pot_lifecycle(uuid,text) to authenticated;

create or replace function public.get_my_dashboard()
returns jsonb language sql stable security definer set search_path='' as $$
  with player as(select id,email,first_name,approved from public.profiles where id=(select auth.uid()))
  select jsonb_build_object('approved',coalesce(player.approved,false),'email',player.email,'first_name',player.first_name,
    'pots',coalesce((select jsonb_agg(jsonb_build_object('id',pot.id,'name',pot.name,'season',pot.season,
      'status',pot.status,'lifecycle_status',pot.lifecycle_status,'membership_locked_at',pot.membership_locked_at,
      'entry_fee_pence',pot.entry_fee_pence,'buy_back_fee_pence',pot.buy_back_fee_pence,
      'player_status',membership.player_status,'payment_status',membership.payment_status,
      'buy_back_status',membership.buy_back_status,'gameweeks',coalesce((select jsonb_agg(g.gameweek_number order by g.gameweek_number)
        from public.pot_gameweeks g where g.pot_id=pot.id),'[]'::jsonb)) order by pot.created_at desc)
      from public.pot_players membership join public.pots pot on pot.id=membership.pot_id
      where membership.player_id=player.id),'[]'::jsonb)) from player;
$$;
revoke all on function public.get_my_dashboard() from public,anon;
grant execute on function public.get_my_dashboard() to authenticated;

create or replace function public.create_pot(pot_name text,pot_season text,entry_fee_pence integer,
  buy_back_fee_pence integer,gameweek_numbers integer[],player_ids uuid[])
returns uuid language plpgsql security definer set search_path='' as $$
declare new_pot_id uuid;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if nullif(trim(pot_name),'') is null then raise exception 'Enter a pot name'; end if;
  if nullif(trim(pot_season),'') is null then raise exception 'Enter a season'; end if;
  if coalesce(array_length(gameweek_numbers,1),0)=0 then raise exception 'Select at least one gameweek'; end if;
  if coalesce(array_length(player_ids,1),0)=0 then raise exception 'Assign at least one player'; end if;
  if exists(select 1 from unnest(gameweek_numbers) gw where gw not between 1 and 38) then raise exception 'Gameweeks must be between 1 and 38'; end if;
  if exists(select 1 from unnest(player_ids) player_id where not exists(select 1 from public.profiles where id=player_id)) then
    raise exception 'Every assigned player must have a registered profile';
  end if;
  insert into public.pots(name,season,entry_fee_pence,buy_back_fee_pence,created_by,lifecycle_status)
  values(trim(pot_name),trim(pot_season),entry_fee_pence,buy_back_fee_pence,(select auth.uid()),'setup') returning id into new_pot_id;
  insert into public.pot_gameweeks(pot_id,gameweek_number) select new_pot_id,gw from(select distinct unnest(gameweek_numbers) gw) selected;
  insert into public.pot_players(pot_id,player_id) select new_pot_id,player_id from(select distinct unnest(player_ids) player_id) selected;
  return new_pot_id;
end; $$;
revoke all on function public.create_pot(text,text,integer,integer,integer[],uuid[]) from public,anon;
grant execute on function public.create_pot(text,text,integer,integer,integer[],uuid[]) to authenticated;

-- These effective functions are deliberately derived from the exact installed Phase 1/P2 definitions.
-- Guarded replacements fail the migration if the expected baseline fragments are absent.
do $$ declare definition text; before_definition text; begin
  definition:=pg_get_functiondef('public.confirm_team_pick(uuid,bigint,bigint)'::regprocedure); before_definition:=definition;
  definition:=replace(definition,'  if membership.payment_status<>''paid'' then raise exception ''Your entry payment must be confirmed before selecting a team''; end if;'||chr(10),'');
  definition:=replace(definition,'  if not exists(select 1 from public.profiles where id=(select auth.uid()) and approved) then'||chr(10)||'    raise exception ''Your account is awaiting approval'';'||chr(10)||'  end if;'||chr(10),'');
  if definition=before_definition or position('payment_status<>''paid''' in definition)>0 or position('account is awaiting approval' in definition)>0 then raise exception 'Unexpected confirm_team_pick baseline'; end if;
  execute definition;

  definition:=pg_get_functiondef('public.assign_random_missing_picks(uuid,integer,boolean)'::regprocedure); before_definition:=definition;
  definition:=replace(definition,' and membership.payment_status=''paid''','');
  definition:=replace(definition,'Every paid active player already has a pick.','Every active player already has a pick.');
  if definition=before_definition or position('membership.payment_status=''paid''' in definition)>0 then raise exception 'Unexpected random-pick baseline'; end if;
  execute definition;

  definition:=pg_get_functiondef('public.process_pot_gameweek_p2_base(uuid,integer,boolean)'::regprocedure); before_definition:=definition;
  definition:=replace(definition,'declare unpaid_count integer; ','');
  definition:=replace(definition,'  select count(*) into unpaid_count from public.pot_players where pot_id=selected_pot_id and player_status=''active'' and payment_status<>''paid'';'||chr(10),'');
  definition:=replace(definition,' and membership.payment_status=''paid''','');
  definition:=replace(definition,'  if unpaid_count>0 then problems:=array_append(problems,unpaid_count||'' active player(s) still need payment confirmation.''); end if;'||chr(10),'');
  definition:=replace(definition,'paid active player(s) do not have a locked pick.','active player(s) do not have a locked pick.');
  if definition=before_definition or position('unpaid_count' in definition)>0 or position('membership.payment_status=''paid''' in definition)>0 then raise exception 'Unexpected processing baseline'; end if;
  execute definition;

end $$;

revoke all on function public.confirm_team_pick(uuid,bigint,bigint) from public,anon;
grant execute on function public.confirm_team_pick(uuid,bigint,bigint) to authenticated;
revoke all on function public.assign_random_missing_picks(uuid,integer,boolean) from public,anon;
grant execute on function public.assign_random_missing_picks(uuid,integer,boolean) to authenticated;
revoke all on function public.process_pot_gameweek_p2_base(uuid,integer,boolean) from public,anon,authenticated;
revoke all on function public.create_pot(text,text,integer,integer,integer[],uuid[]) from public,anon;
grant execute on function public.create_pot(text,text,integer,integer,integer[],uuid[]) to authenticated;

commit;
