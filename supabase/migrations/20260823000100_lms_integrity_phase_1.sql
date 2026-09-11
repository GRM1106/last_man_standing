-- LMS Integrity Phase 1
-- Forward-only migration. Requires the complete modules 1-22, P1 result
-- provenance foundation, and P2 controlled fixture corrections at d09613e.
-- Apply once through a migration runner; never re-run superseded setup modules.

begin;

do $$
begin
  if to_regprocedure('public.get_effective_fixture_result(bigint)') is null
    or to_regprocedure('public.create_fixture_result_override(bigint,integer,integer,text,text,text)') is null
    or to_regclass('public.fixture_result_overrides') is null then
    raise exception 'LMS Integrity Phase 1 requires the complete P1 and P2 schema';
  end if;
  if to_regprocedure('public.sync_fpl_data_p2_base(text,jsonb,jsonb)') is not null
    or to_regprocedure('public.process_pot_gameweek_p2_base(uuid,integer,boolean)') is not null then
    raise exception 'LMS Integrity Phase 1 has already been installed';
  end if;
end;
$$;

alter table public.pot_gameweeks
  add column pick_deadline_at timestamptz;

alter table public.player_picks
  add column selected_fixture_gameweek integer,
  add column selected_home_team_id bigint references public.football_teams(id),
  add column selected_away_team_id bigint references public.football_teams(id),
  add column selected_kickoff_at timestamptz,
  add column fixture_context_changed boolean not null default false;

update public.pot_gameweeks gameweek
set pick_deadline_at=(
  select min(fixture.kickoff_at)
  from public.pots pot
  join public.football_fixtures fixture on fixture.season=pot.season
    and fixture.gameweek_number=gameweek.gameweek_number
  where pot.id=gameweek.pot_id and fixture.kickoff_at is not null
);

update public.player_picks pick
set selected_fixture_gameweek=pick.gameweek_number,
    selected_home_team_id=fixture.home_team_id,
    selected_away_team_id=fixture.away_team_id,
    selected_kickoff_at=fixture.kickoff_at
from public.football_fixtures fixture
where fixture.id=pick.fixture_id;

alter table public.player_picks
  alter column selected_fixture_gameweek set not null,
  alter column selected_home_team_id set not null,
  alter column selected_away_team_id set not null;

alter table public.player_picks
  add constraint player_picks_selected_fixture_gameweek_check
    check(selected_fixture_gameweek between 1 and 38),
  add constraint player_picks_selected_fixture_teams_check
    check(selected_home_team_id<>selected_away_team_id),
  add constraint player_picks_selected_team_participated_check
    check(team_id in(selected_home_team_id,selected_away_team_id));

create or replace function public.set_initial_pot_gameweek_deadline()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.pick_deadline_at is null then
    select min(fixture.kickoff_at) into new.pick_deadline_at
    from public.pots pot
    join public.football_fixtures fixture on fixture.season=pot.season
      and fixture.gameweek_number=new.gameweek_number
    where pot.id=new.pot_id and fixture.kickoff_at is not null;
  end if;
  return new;
end;
$$;
revoke all on function public.set_initial_pot_gameweek_deadline() from public,anon,authenticated;

create trigger pot_gameweeks_initial_deadline
before insert on public.pot_gameweeks
for each row execute function public.set_initial_pot_gameweek_deadline();

create or replace function public.refresh_open_pot_gameweek_deadlines(selected_season text)
returns void language plpgsql security definer set search_path='' as $$
begin
  update public.pot_gameweeks gameweek
  set pick_deadline_at=case
    when gameweek.pick_deadline_at is not null and gameweek.pick_deadline_at<=now()
      then gameweek.pick_deadline_at
    when calculated.value is null then gameweek.pick_deadline_at
    else calculated.value
  end
  from (
    select candidate_gameweek.pot_id,candidate_gameweek.gameweek_number,min(fixture.kickoff_at) value
    from public.pot_gameweeks candidate_gameweek
    join public.pots pot on pot.id=candidate_gameweek.pot_id
    left join public.football_fixtures fixture on fixture.season=pot.season
      and fixture.gameweek_number=candidate_gameweek.gameweek_number and fixture.kickoff_at is not null
    where pot.season=trim(selected_season)
    group by candidate_gameweek.pot_id,candidate_gameweek.gameweek_number
  ) calculated
  where gameweek.pot_id=calculated.pot_id and gameweek.gameweek_number=calculated.gameweek_number;
end;
$$;
revoke all on function public.refresh_open_pot_gameweek_deadlines(text) from public,anon,authenticated;

create or replace function public.current_pot_gameweek(selected_pot_id uuid)
returns integer language sql stable security definer set search_path='' as $$
  select min(gameweek.gameweek_number)
  from public.pot_gameweeks gameweek
  join public.pots pot on pot.id=gameweek.pot_id
  where gameweek.pot_id=selected_pot_id
    and not exists(
      select 1 from public.pot_gameweek_processes processed
      where processed.pot_id=gameweek.pot_id
        and processed.gameweek_number=gameweek.gameweek_number
    )
    and exists(
      select 1 from public.football_fixtures fixture
      where fixture.season=pot.season
        and fixture.gameweek_number=gameweek.gameweek_number
    );
$$;
revoke all on function public.current_pot_gameweek(uuid) from public,anon,authenticated;

create or replace function public.get_gameweek_deadline(selected_pot_id uuid,selected_gameweek integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare deadline timestamptz; declare test_enabled boolean;
begin
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
    and not (select public.is_current_user_admin()) then raise exception 'You are not assigned to this pot'; end if;
  select gameweek.pick_deadline_at,pot.test_mode into deadline,test_enabled
  from public.pot_gameweeks gameweek join public.pots pot on pot.id=gameweek.pot_id
  where gameweek.pot_id=selected_pot_id and gameweek.gameweek_number=selected_gameweek;
  if not found then raise exception 'Gameweek is not part of this pot'; end if;
  return jsonb_build_object('deadline',deadline,'deadline_passed',deadline is not null and now()>=deadline,
    'test_mode',test_enabled,'permanently_closed',deadline is not null and now()>=deadline);
end;
$$;
revoke all on function public.get_gameweek_deadline(uuid,integer) from public,anon,authenticated;
grant execute on function public.get_gameweek_deadline(uuid,integer) to authenticated;

create or replace function public.confirm_team_pick(selected_pot_id uuid,selected_fixture_id bigint,selected_team_id bigint)
returns void language plpgsql security definer set search_path='' as $$
declare membership public.pot_players%rowtype;
declare fixture public.football_fixtures%rowtype;
declare current_gameweek integer;
declare deadline timestamptz;
begin
  select * into membership from public.pot_players
  where pot_id=selected_pot_id and player_id=(select auth.uid());
  if not found then raise exception 'You are not assigned to this pot'; end if;
  if membership.player_status<>'active' then raise exception 'You are not active in this pot'; end if;
  if membership.payment_status<>'paid' then raise exception 'Your entry payment must be confirmed before selecting a team'; end if;
  if not exists(select 1 from public.profiles where id=(select auth.uid()) and approved) then
    raise exception 'Your account is awaiting approval';
  end if;

  select football_fixture.* into fixture
  from public.football_fixtures football_fixture
  join public.pots pot on pot.id=selected_pot_id and pot.season=football_fixture.season
  where football_fixture.id=selected_fixture_id;
  if not found then raise exception 'Fixture not found for this pot'; end if;

  current_gameweek:=public.current_pot_gameweek(selected_pot_id);
  if current_gameweek is null then raise exception 'No gameweek is currently available for selection'; end if;
  if fixture.gameweek_number is distinct from current_gameweek then
    raise exception 'Selections are only accepted for the current gameweek';
  end if;

  select gameweek.pick_deadline_at into deadline
  from public.pot_gameweeks gameweek
  where gameweek.pot_id=selected_pot_id and gameweek.gameweek_number=current_gameweek
  for update;
  if deadline is null then raise exception 'The gameweek deadline is not available yet'; end if;
  if now()>=deadline then raise exception 'The gameweek pick deadline has passed'; end if;
  if fixture.kickoff_at is null or fixture.kickoff_at<=now() or fixture.started or fixture.finished then
    raise exception 'That fixture is no longer available for selection';
  end if;
  if selected_team_id not in(fixture.home_team_id,fixture.away_team_id) then
    raise exception 'Select a team playing in this fixture';
  end if;
  if exists(select 1 from public.player_picks where pot_id=selected_pot_id
    and player_id=(select auth.uid()) and gameweek_number=current_gameweek) then
    raise exception 'Your pick for this gameweek is already locked';
  end if;
  if exists(select 1 from public.player_picks where pot_id=selected_pot_id
    and player_id=(select auth.uid()) and team_id=selected_team_id) then
    raise exception 'You have already used that team in this pot';
  end if;

  insert into public.player_picks(
    pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,selection_reason,
    selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
  ) values(
    selected_pot_id,(select auth.uid()),current_gameweek,fixture.id,selected_team_id,'manual',
    'Player confirmed before the gameweek deadline',fixture.gameweek_number,fixture.home_team_id,
    fixture.away_team_id,fixture.kickoff_at
  );
end;
$$;
revoke all on function public.confirm_team_pick(uuid,bigint,bigint) from public,anon,authenticated;
grant execute on function public.confirm_team_pick(uuid,bigint,bigint) to authenticated;

create or replace function public.assign_random_missing_picks(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype; declare missing_count integer; declare no_team_count integer; declare inserted_count integer:=0;
declare deadline timestamptz; declare current_gameweek integer; declare problems text[]:=array[]::text[];
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  current_gameweek:=public.current_pot_gameweek(selected_pot_id);
  if current_gameweek is null or selected_gameweek<>current_gameweek then
    problems:=array_append(problems,'Random picks are only available for the current gameweek.');
  end if;
  select pick_deadline_at into deadline from public.pot_gameweeks
  where pot_id=selected_pot_id and gameweek_number=selected_gameweek;
  if not found then raise exception 'Gameweek is not part of this pot'; end if;
  if exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then
    problems:=array_append(problems,'This gameweek has already been processed.');
  end if;
  select count(*) into missing_count from public.pot_players membership
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id
      and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek);
  select count(*) into no_team_count from public.pot_players membership
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id
      and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
    and not exists(
      select 1 from (
        select fixture.id fixture_id,fixture.home_team_id team_id
        from public.football_fixtures fixture
        where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
          and fixture.kickoff_at is not null and fixture.kickoff_at>now() and not fixture.started and not fixture.finished
        union all
        select fixture.id,fixture.away_team_id
        from public.football_fixtures fixture
        where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
          and fixture.kickoff_at is not null and fixture.kickoff_at>now() and not fixture.started and not fixture.finished
      ) option_team
      where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id
        and used.player_id=membership.player_id and used.team_id=option_team.team_id)
    );
  if deadline is null then problems:=array_append(problems,'The gameweek deadline is not available.');
  elsif not selected_pot.test_mode and now()<deadline then
    problems:=array_append(problems,'Random picks cannot be assigned before the gameweek deadline.');
  end if;
  if missing_count=0 then problems:=array_append(problems,'Every paid active player already has a pick.'); end if;
  if no_team_count>0 then
    problems:=array_append(problems,'No eligible unstarted fixture remains for random assignment.');
  end if;
  if not apply_changes then return jsonb_build_object('ready',cardinality(problems)=0,'missing',missing_count,
    'test_mode',selected_pot.test_mode,'deadline',deadline,'deadline_passed',selected_pot.test_mode or
      (deadline is not null and now()>=deadline),'problems',to_jsonb(problems)); end if;
  if cardinality(problems)>0 then raise exception '%',array_to_string(problems,' '); end if;

  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),selected_gameweek);
  insert into public.player_picks(
    pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,selection_reason,
    selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
  )
  select selected_pot_id,membership.player_id,selected_gameweek,candidate.fixture_id,candidate.team_id,'random',
    case when selected_pot.test_mode then 'Test-mode random assignment for a missing pick'
      else 'No player pick was received before the gameweek deadline' end,
    candidate.gameweek_number,candidate.home_team_id,candidate.away_team_id,candidate.kickoff_at
  from public.pot_players membership
  cross join lateral (
    select option.fixture_id,option.team_id,option.gameweek_number,option.home_team_id,option.away_team_id,option.kickoff_at
    from (
      select fixture.id fixture_id,fixture.home_team_id team_id,fixture.gameweek_number,
        fixture.home_team_id,fixture.away_team_id,fixture.kickoff_at
      from public.football_fixtures fixture
      where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
        and fixture.kickoff_at is not null and fixture.kickoff_at>now() and not fixture.started and not fixture.finished
      union all
      select fixture.id,fixture.away_team_id,fixture.gameweek_number,
        fixture.home_team_id,fixture.away_team_id,fixture.kickoff_at
      from public.football_fixtures fixture
      where fixture.season=selected_pot.season and fixture.gameweek_number=selected_gameweek
        and fixture.kickoff_at is not null and fixture.kickoff_at>now() and not fixture.started and not fixture.finished
    ) option
    where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id
      and used.player_id=membership.player_id and used.team_id=option.team_id)
    order by random() limit 1
  ) candidate
  where membership.pot_id=selected_pot_id and membership.player_status='active' and membership.payment_status='paid'
    and not exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id
      and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek)
  on conflict do nothing;
  get diagnostics inserted_count=row_count;
  return jsonb_build_object('ready',true,'assigned',inserted_count,'test_mode',selected_pot.test_mode,
    'deadline',deadline,'problems','[]'::jsonb);
end;
$$;
revoke all on function public.assign_random_missing_picks(uuid,integer,boolean) from public,anon,authenticated;
grant execute on function public.assign_random_missing_picks(uuid,integer,boolean) to authenticated;

create or replace function public.reset_test_gameweek(selected_pot_id uuid,selected_gameweek integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then
    raise exception 'This is not a draft pot in test mode';
  end if;
  if not exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id
    and gameweek_number=selected_gameweek and test_run) then raise exception 'No processed test run was found'; end if;

  update public.pot_players membership
  set player_status='active',buy_back_status='available',buy_back_claimed_at=null,buy_back_used_at=null
  where membership.pot_id=selected_pot_id
    and exists(select 1 from public.player_picks pick where pick.pot_id=selected_pot_id
      and pick.gameweek_number=selected_gameweek and pick.player_id=membership.player_id and pick.outcome='lost');
  delete from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek;
  delete from public.pot_fixture_test_results test_result using public.football_fixtures fixture
    where test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id
      and fixture.gameweek_number=selected_gameweek;
  delete from public.player_picks where pot_id=selected_pot_id and gameweek_number=selected_gameweek;
end;
$$;
revoke all on function public.reset_test_gameweek(uuid,integer) from public,anon,authenticated;
grant execute on function public.reset_test_gameweek(uuid,integer) to authenticated;

create or replace function public.set_pot_test_mode(selected_pot_id uuid,enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft') then
    raise exception 'Only draft pots can use test mode';
  end if;
  if not enabled and exists(select 1 from public.pots where id=selected_pot_id and test_mode) and (
    exists(select 1 from public.player_picks where pot_id=selected_pot_id)
    or exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id)
    or exists(select 1 from public.pot_fixture_test_results where pot_id=selected_pot_id)
    or exists(select 1 from public.pot_players where pot_id=selected_pot_id and
      (player_status<>'active' or buy_back_status<>'available' or buy_back_claimed_at is not null or buy_back_used_at is not null))
  ) then raise exception 'Reset all test progress before disabling test mode'; end if;
  update public.pots set test_mode=enabled where id=selected_pot_id;
end;
$$;
revoke all on function public.set_pot_test_mode(uuid,boolean) from public,anon,authenticated;
grant execute on function public.set_pot_test_mode(uuid,boolean) to authenticated;

create or replace function public.complete_pot_with_winner(selected_pot_id uuid,selected_winner_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found or selected_pot.status='complete' then raise exception 'Pot not found or already complete'; end if;
  if selected_pot.test_mode then raise exception 'A pot in test mode cannot be completed'; end if;
  if selected_pot.status<>'active' then raise exception 'Only an active pot can be completed'; end if;
  if not exists(select 1 from public.pot_players where pot_id=selected_pot_id
    and player_id=selected_winner_id and player_status='active') then
    raise exception 'Winner must be an active player in this pot';
  end if;
  if not exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id) then
    raise exception 'Process at least one gameweek before completing the pot';
  end if;
  if (select count(*) from public.pot_players where pot_id=selected_pot_id and player_status='active')<>1 then
    raise exception 'The pot can only be completed when exactly one active player remains';
  end if;
  if exists(select 1 from public.pot_players where pot_id=selected_pot_id and buy_back_status='claimed') then
    raise exception 'Resolve pending buy-back claims before completing the pot';
  end if;
  update public.pot_players set player_status='winner'
  where pot_id=selected_pot_id and player_id=selected_winner_id;
  update public.pots set status='complete',test_mode=false where id=selected_pot_id;
end;
$$;
revoke all on function public.complete_pot_with_winner(uuid,uuid) from public,anon,authenticated;
grant execute on function public.complete_pot_with_winner(uuid,uuid) to authenticated;

alter function public.sync_fpl_data(text,jsonb,jsonb) rename to sync_fpl_data_p2_base;
revoke all on function public.sync_fpl_data_p2_base(text,jsonb,jsonb) from public,anon,authenticated;

create or replace function public.sync_fpl_data(selected_season text,fpl_teams jsonb,fpl_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; declare normalized_season text:=trim(selected_season);
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;

  update public.pots pot
  set review_status='needs_review',
      review_reason='A referenced fixture changed gameweek or participants during provider synchronization',
      review_status_changed_at=now()
  where pot.id in(
    select distinct pick.pot_id
    from public.player_picks pick
    join public.football_fixtures stored on stored.id=pick.fixture_id
    join jsonb_array_elements(fpl_fixtures) supplied(fixture)
      on stored.season=normalized_season and stored.fpl_fixture_id=(fixture->>'id')::integer
    left join public.football_teams proposed_home on proposed_home.season=normalized_season
      and proposed_home.fpl_team_id=(fixture->>'team_h')::integer
    left join public.football_teams proposed_away on proposed_away.season=normalized_season
      and proposed_away.fpl_team_id=(fixture->>'team_a')::integer
    where stored.gameweek_number is distinct from nullif(fixture->>'event','')::integer
      or stored.home_team_id is distinct from proposed_home.id
      or stored.away_team_id is distinct from proposed_away.id
  );

  update public.player_picks pick set fixture_context_changed=true
  from public.football_fixtures stored
  join jsonb_array_elements(fpl_fixtures) supplied(fixture)
    on stored.season=normalized_season and stored.fpl_fixture_id=(fixture->>'id')::integer
  left join public.football_teams proposed_home on proposed_home.season=normalized_season
    and proposed_home.fpl_team_id=(fixture->>'team_h')::integer
  left join public.football_teams proposed_away on proposed_away.season=normalized_season
    and proposed_away.fpl_team_id=(fixture->>'team_a')::integer
  where pick.fixture_id=stored.id and (
    stored.gameweek_number is distinct from nullif(fixture->>'event','')::integer
    or stored.home_team_id is distinct from proposed_home.id
    or stored.away_team_id is distinct from proposed_away.id
  );

  result:=public.sync_fpl_data_p2_base(selected_season,fpl_teams,fpl_fixtures);
  perform public.refresh_open_pot_gameweek_deadlines(normalized_season);
  return result;
end;
$$;
revoke all on function public.sync_fpl_data(text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.sync_fpl_data(text,jsonb,jsonb) to authenticated;

alter function public.process_pot_gameweek(uuid,integer,boolean) rename to process_pot_gameweek_p2_base;
revoke all on function public.process_pot_gameweek_p2_base(uuid,integer,boolean) from public,anon,authenticated;

create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare base_result jsonb; declare mutation_count integer;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select count(*) into mutation_count from public.player_picks
  where pot_id=selected_pot_id and gameweek_number=selected_gameweek and fixture_context_changed;
  if mutation_count>0 then
    if apply_changes then
      raise exception 'Referenced fixture context changed; administrator review is required before processing';
    end if;
    base_result:=public.process_pot_gameweek_p2_base(selected_pot_id,selected_gameweek,false);
    return jsonb_set(jsonb_set(base_result,'{ready}','false'::jsonb),'{problems}',
      coalesce(base_result->'problems','[]'::jsonb)||jsonb_build_array(
        'Referenced fixture context changed; administrator review is required before processing'));
  end if;
  return public.process_pot_gameweek_p2_base(selected_pot_id,selected_gameweek,apply_changes);
end;
$$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public,anon,authenticated;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

commit;
