-- 24 — Controlled fixture-result corrections
-- Forward-only Domain Phase P2 migration. Apply only after
-- result_provenance_foundation.sql. Never apply to production without a
-- separately approved production migration plan, backup and preflight.

begin;

revoke all on table public.fixture_result_overrides,public.admin_audit_events,public.pot_player_status_history
from public,anon,authenticated;

-- All result writers lock fixture IDs in ascending order. Operations which also
-- affect pots acquire pot locks only after every fixture lock. This order is
-- shared by synchronization, correction preview/mutation and processing.
create or replace function public.fixture_result_lock_key(selected_fixture_id bigint)
returns bigint language sql immutable set search_path='' as $$
  select hashtextextended('fixture-result:'||selected_fixture_id::text,0);
$$;
revoke all on function public.fixture_result_lock_key(bigint) from public;

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.fixture_result_overrides'::regclass
    and conname='fixture_result_overrides_fixture_id_id_key') then
    alter table public.fixture_result_overrides add constraint fixture_result_overrides_fixture_id_id_key unique(fixture_id,id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.fixture_result_overrides'::regclass
    and conname='fixture_result_overrides_same_fixture_supersedes_fk') then
    alter table public.fixture_result_overrides add constraint fixture_result_overrides_same_fixture_supersedes_fk
      foreign key(fixture_id,supersedes_id) references public.fixture_result_overrides(fixture_id,id);
  end if;
end;
$$;
create unique index if not exists fixture_result_overrides_one_root_per_fixture
  on public.fixture_result_overrides(fixture_id) where supersedes_id is null;

create or replace function public.validate_fixture_result_override(
  selected_home_score integer,
  selected_away_score integer,
  selected_status text,
  selected_reason text
)
returns void language plpgsql immutable set search_path='' as $$
begin
  if nullif(trim(selected_reason),'') is null then raise exception 'A correction reason is required'; end if;
  if selected_status not in ('finished','postponed','abandoned','void') then raise exception 'Administrators cannot set that fixture status'; end if;
  if selected_home_score is not null and selected_home_score<0
    or selected_away_score is not null and selected_away_score<0 then raise exception 'Scores cannot be negative'; end if;
  if (selected_home_score is null)<>(selected_away_score is null) then raise exception 'Both scores must be supplied together'; end if;
  if selected_status='finished' and (selected_home_score is null or selected_away_score is null) then
    raise exception 'Finished fixtures require both scores';
  end if;
  if selected_status in ('postponed','abandoned','void')
    and (selected_home_score is not null or selected_away_score is not null) then
    raise exception '% fixtures cannot have scores',initcap(selected_status);
  end if;
end;
$$;
revoke all on function public.validate_fixture_result_override(integer,integer,text,text) from public;

create or replace function public.get_effective_fixture_result(selected_fixture_id bigint)
returns table(
  fixture_id bigint,
  raw_home_score integer,
  raw_away_score integer,
  raw_status text,
  effective_home_score integer,
  effective_away_score integer,
  effective_status text,
  result_source text,
  override_id uuid,
  provider_synced_at timestamptz,
  raw_finished boolean,
  raw_finished_provisional boolean,
  processable boolean
)
language plpgsql stable security definer set search_path='' as $$
declare override_count integer; declare active_count integer;
begin
  select count(*),count(*) filter(where not exists(select 1 from public.fixture_result_overrides successor
    where successor.supersedes_id=candidate.id)) into override_count,active_count
  from public.fixture_result_overrides candidate where candidate.fixture_id=selected_fixture_id;
  if override_count>0 and active_count<>1 then raise exception 'Fixture override chain is invalid'; end if;
  return query select fixture.id,fixture.home_score,fixture.away_score,fixture.status,
    case when current_override.id is null then fixture.home_score else current_override.new_home_score end,
    case when current_override.id is null then fixture.away_score else current_override.new_away_score end,
    case when current_override.id is null then fixture.status else current_override.new_status end,
    case when current_override.id is null then 'api'
      when current_override.source in ('admin_correction','provider_correction') then 'admin_override'
      when current_override.source='postponement' then 'postponed'
      when current_override.source='abandonment' then 'abandoned'
      else 'void' end,
    current_override.id,fixture.provider_synced_at,fixture.finished,fixture.finished_provisional,
    case when current_override.id is not null then current_override.new_status='finished'
        and current_override.new_home_score is not null and current_override.new_away_score is not null
      else fixture.finished and not fixture.finished_provisional and fixture.status='finished'
        and fixture.home_score is not null and fixture.away_score is not null end
  from public.football_fixtures fixture
  left join lateral (
    select candidate.* from public.fixture_result_overrides candidate
    where candidate.fixture_id=fixture.id
      and not exists(select 1 from public.fixture_result_overrides successor where successor.supersedes_id=candidate.id)
    order by candidate.created_at desc,candidate.id desc limit 1
  ) current_override on true
  where fixture.id=selected_fixture_id;
end;
$$;
revoke all on function public.get_effective_fixture_result(bigint) from public;

create or replace function public.fixture_override_impact(selected_fixture_id bigint)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('pot_id',affected.id,'pot_name',affected.name,
    'pot_status',affected.status,'gameweek_number',affected.gameweek_number,'processed',affected.processed,
    'requires_review',affected.processed or affected.status='complete') order by affected.id,affected.gameweek_number),'[]'::jsonb)
  from (select distinct pot.id,pot.name,pot.status,pick.gameweek_number,
    exists(select 1 from public.pot_gameweek_processes process where process.pot_id=pot.id
      and process.gameweek_number=pick.gameweek_number) processed
    from public.player_picks pick join public.pots pot on pot.id=pick.pot_id
    where pick.fixture_id=selected_fixture_id) affected;
$$;
revoke all on function public.fixture_override_impact(bigint) from public;

create or replace function public.fixture_effective_version(selected_fixture_id bigint)
returns text language plpgsql stable security definer set search_path='' as $$
declare effective record; declare impact jsonb;
begin
  select * into effective from public.get_effective_fixture_result(selected_fixture_id);
  if not found then raise exception 'Fixture not found'; end if;
  impact:=public.fixture_override_impact(selected_fixture_id);
  return md5(jsonb_build_object('fixture_id',effective.fixture_id,'raw_home_score',effective.raw_home_score,
    'raw_away_score',effective.raw_away_score,'raw_status',effective.raw_status,'raw_finished',effective.raw_finished,
    'raw_finished_provisional',effective.raw_finished_provisional,'provider_synced_at',effective.provider_synced_at,
    'override_id',effective.override_id,'effective_home_score',effective.effective_home_score,
    'effective_away_score',effective.effective_away_score,'effective_status',effective.effective_status,
    'impact',impact)::text);
end;
$$;
revoke all on function public.fixture_effective_version(bigint) from public;

drop function if exists public.preview_fixture_result_override(bigint,integer,integer,text,text,text);
drop function if exists public.create_fixture_result_override(bigint,integer,integer,text,text,text);

create or replace function public.preview_fixture_result_override(
  selected_fixture_id bigint,
  selected_home_score integer,
  selected_away_score integer,
  selected_status text,
  selected_reason text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare effective record;
declare impact jsonb;
declare affected record;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.validate_fixture_result_override(selected_home_score,selected_away_score,selected_status,selected_reason);
  perform pg_advisory_xact_lock(public.fixture_result_lock_key(selected_fixture_id));
  for affected in select distinct pick.pot_id,pick.gameweek_number from public.player_picks pick
    where pick.fixture_id=selected_fixture_id order by pick.pot_id,pick.gameweek_number
  loop perform pg_advisory_xact_lock(hashtext(affected.pot_id::text),affected.gameweek_number); end loop;
  select * into effective from public.get_effective_fixture_result(selected_fixture_id);
  if not found then raise exception 'Fixture not found'; end if;
  if not ((effective.effective_status in ('scheduled','live') and selected_status in ('finished','postponed','abandoned','void'))
    or (effective.effective_status='finished' and selected_status in ('finished','postponed','abandoned','void'))
    or (effective.effective_status in ('postponed','abandoned') and selected_status in ('finished','void'))
    or (effective.effective_status='void' and selected_status='finished')) then raise exception 'Unsupported fixture status transition'; end if;
  if effective.effective_home_score is not distinct from selected_home_score
    and effective.effective_away_score is not distinct from selected_away_score
    and effective.effective_status is not distinct from selected_status then raise exception 'The proposed correction does not change the effective result'; end if;

  impact:=public.fixture_override_impact(selected_fixture_id);

  return jsonb_build_object(
    'fixture_id',selected_fixture_id,
    'raw',jsonb_build_object('home_score',effective.raw_home_score,'away_score',effective.raw_away_score,'status',effective.raw_status),
    'effective_before',jsonb_build_object('home_score',effective.effective_home_score,'away_score',effective.effective_away_score,
      'status',effective.effective_status,'source',effective.result_source,'override_id',effective.override_id),
    'proposed',jsonb_build_object('home_score',selected_home_score,'away_score',selected_away_score,'status',selected_status,
      'source',case selected_status when 'finished' then 'admin_correction' when 'postponed' then 'postponement'
        when 'abandoned' then 'abandonment' else 'void' end),
    'affected_pots',impact,
    'review_count',(select count(*) from jsonb_array_elements(impact) item where (item->>'requires_review')::boolean),
    'effective_version',public.fixture_effective_version(selected_fixture_id)
  );
end;
$$;
revoke all on function public.preview_fixture_result_override(bigint,integer,integer,text,text) from public;
grant execute on function public.preview_fixture_result_override(bigint,integer,integer,text,text) to authenticated;

create or replace function public.create_fixture_result_override(
  selected_fixture_id bigint,
  selected_home_score integer,
  selected_away_score integer,
  selected_status text,
  selected_reason text,
  expected_effective_version text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare administrator_id uuid:=(select auth.uid());
declare effective record;
declare created_override public.fixture_result_overrides%rowtype;
declare correlation uuid:=gen_random_uuid();
declare affected record;
declare review_count integer:=0;
declare selected_source text;
begin
  if administrator_id is null or not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  perform public.validate_fixture_result_override(selected_home_score,selected_away_score,selected_status,selected_reason);
  if nullif(expected_effective_version,'') is null then raise exception 'Result changed; preview again'; end if;
  perform pg_advisory_xact_lock(public.fixture_result_lock_key(selected_fixture_id));
  perform 1 from public.football_fixtures where id=selected_fixture_id for update;
  if not found then raise exception 'Fixture not found'; end if;
  for affected in select distinct pick.pot_id,pick.gameweek_number from public.player_picks pick
    where pick.fixture_id=selected_fixture_id order by pick.pot_id,pick.gameweek_number
  loop perform pg_advisory_xact_lock(hashtext(affected.pot_id::text),affected.gameweek_number); end loop;
  if public.fixture_effective_version(selected_fixture_id)<>expected_effective_version then raise exception 'Result changed; preview again'; end if;
  select * into effective from public.get_effective_fixture_result(selected_fixture_id);
  if not ((effective.effective_status in ('scheduled','live') and selected_status in ('finished','postponed','abandoned','void'))
    or (effective.effective_status='finished' and selected_status in ('finished','postponed','abandoned','void'))
    or (effective.effective_status in ('postponed','abandoned') and selected_status in ('finished','void'))
    or (effective.effective_status='void' and selected_status='finished')) then raise exception 'Unsupported fixture status transition'; end if;
  if effective.effective_home_score is not distinct from selected_home_score
    and effective.effective_away_score is not distinct from selected_away_score
    and effective.effective_status is not distinct from selected_status then raise exception 'The proposed correction does not change the effective result'; end if;

  selected_source:=case selected_status when 'finished' then 'admin_correction' when 'postponed' then 'postponement'
    when 'abandoned' then 'abandonment' else 'void' end;
  insert into public.fixture_result_overrides(
    fixture_id,administrator_id,reason,previous_home_score,previous_away_score,previous_status,
    new_home_score,new_away_score,new_status,source,supersedes_id
  ) values(
    selected_fixture_id,administrator_id,trim(selected_reason),effective.effective_home_score,effective.effective_away_score,effective.effective_status,
    selected_home_score,selected_away_score,selected_status,selected_source,effective.override_id
  ) returning * into created_override;

  insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier,before_state,after_state,reason,correlation_id)
  values(administrator_id,'fixture_result_overridden','football_fixture',selected_fixture_id::text,
    jsonb_build_object('home_score',effective.effective_home_score,'away_score',effective.effective_away_score,'status',effective.effective_status,
      'source',effective.result_source,'override_id',effective.override_id),
    jsonb_build_object('home_score',selected_home_score,'away_score',selected_away_score,'status',selected_status,
      'source',selected_source,'override_id',created_override.id,'mutation_channel','administrator_rpc'),trim(selected_reason),correlation);

  for affected in
    select distinct pot.id,pot.name,pot.status,pot.review_status,pot.review_reason,pick.gameweek_number,
      exists(select 1 from public.pot_gameweek_processes process
        where process.pot_id=pot.id and process.gameweek_number=pick.gameweek_number) processed
    from public.player_picks pick join public.pots pot on pot.id=pick.pot_id
    where pick.fixture_id=selected_fixture_id
      and (pot.status='complete' or exists(select 1 from public.pot_gameweek_processes process
        where process.pot_id=pot.id and process.gameweek_number=pick.gameweek_number))
  loop
    update public.pots set review_status='needs_review',
      review_reason='Fixture correction requires review: '||trim(selected_reason),review_status_changed_at=now()
    where id=affected.id;
    insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier,before_state,after_state,reason,correlation_id)
    values(administrator_id,'pot_flagged_for_result_review','pot',affected.id::text,
      jsonb_build_object('review_status',affected.review_status,'review_reason',affected.review_reason,'pot_status',affected.status,
        'gameweek_number',affected.gameweek_number,'processed',affected.processed),
      jsonb_build_object('review_status','needs_review','review_reason','Fixture correction requires review: '||trim(selected_reason),
        'pot_status',affected.status,'gameweek_number',affected.gameweek_number,'processed',affected.processed),
      trim(selected_reason),correlation);
    review_count:=review_count+1;
  end loop;

  return jsonb_build_object('override_id',created_override.id,'fixture_id',selected_fixture_id,'created_at',created_override.created_at,
    'supersedes_id',created_override.supersedes_id,'review_count',review_count,'correlation_id',correlation);
end;
$$;
revoke all on function public.create_fixture_result_override(bigint,integer,integer,text,text,text) from public;
grant execute on function public.create_fixture_result_override(bigint,integer,integer,text,text,text) to authenticated;

create or replace function public.get_admin_fixture_results(selected_season text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',fixture.id,'fpl_fixture_id',fixture.fpl_fixture_id,'season',fixture.season,'gameweek_number',fixture.gameweek_number,
    'kickoff_at',fixture.kickoff_at,'home_team',jsonb_build_object('id',home.id,'name',home.name,'short_name',home.short_name,'emblem_url',home.emblem_url),
    'away_team',jsonb_build_object('id',away.id,'name',away.name,'short_name',away.short_name,'emblem_url',away.emblem_url),
    'raw',jsonb_build_object('home_score',effective.raw_home_score,'away_score',effective.raw_away_score,'status',effective.raw_status,
      'provider_synced_at',fixture.provider_synced_at,'finished',effective.raw_finished,
      'finished_provisional',effective.raw_finished_provisional),
    'effective',jsonb_build_object('home_score',effective.effective_home_score,'away_score',effective.effective_away_score,
      'status',effective.effective_status,'source',effective.result_source,'override_id',effective.override_id,
      'processable',effective.processable),
    'overrides',coalesce((select jsonb_agg(jsonb_build_object('id',history.id,'reason',history.reason,'source',history.source,
      'home_score',history.new_home_score,'away_score',history.new_away_score,'status',history.new_status,
      'supersedes_id',history.supersedes_id,'created_at',history.created_at) order by history.created_at desc)
      from public.fixture_result_overrides history where history.fixture_id=fixture.id),'[]'::jsonb)
  ) order by fixture.kickoff_at nulls last,fixture.id),'[]'::jsonb) into result
  from public.football_fixtures fixture
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  join lateral public.get_effective_fixture_result(fixture.id) effective on true
  where fixture.season=trim(selected_season);
  return result;
end;
$$;
revoke all on function public.get_admin_fixture_results(text) from public;
grant execute on function public.get_admin_fixture_results(text) to authenticated;

-- Provider synchronization continues to own only raw fixture facts. Overrides
-- live in their append-only table and are neither changed nor superseded here.
create or replace function public.sync_fpl_data(selected_season text,fpl_teams jsonb,fpl_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare team_count integer;
declare fixture_count integer;
declare normalized_season text:=trim(selected_season);
declare locked_fixture record;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if normalized_season is null or normalized_season='' then raise exception 'Season is required'; end if;
  if jsonb_typeof(fpl_teams)<>'array' or jsonb_typeof(fpl_fixtures)<>'array' then raise exception 'Invalid FPL data'; end if;
  insert into public.football_teams(season,fpl_team_id,code,name,short_name,emblem_url,updated_at)
  select normalized_season,(team->>'id')::integer,(team->>'code')::integer,team->>'name',team->>'short_name',
    'https://resources.premierleague.com/premierleague/badges/100/t'||(team->>'code')||'.png',now()
  from jsonb_array_elements(fpl_teams) supplied(team)
  on conflict(season,fpl_team_id) do update set code=excluded.code,name=excluded.name,short_name=excluded.short_name,
    emblem_url=excluded.emblem_url,updated_at=now();
  get diagnostics team_count=row_count;
  for locked_fixture in
    select stored.id from public.football_fixtures stored
    join jsonb_array_elements(fpl_fixtures) supplied(fixture)
      on stored.season=normalized_season and stored.fpl_fixture_id=(fixture->>'id')::integer
    order by stored.id
  loop perform pg_advisory_xact_lock(public.fixture_result_lock_key(locked_fixture.id)); end loop;
  insert into public.football_fixtures(fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
    home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
  select (fixture->>'id')::integer,normalized_season,nullif(fixture->>'event','')::integer,
    nullif(fixture->>'kickoff_time','')::timestamptz,home.id,away.id,
    nullif(fixture->>'team_h_score','')::integer,nullif(fixture->>'team_a_score','')::integer,
    coalesce((fixture->>'started')::boolean,false),coalesce((fixture->>'finished')::boolean,false),
    coalesce((fixture->>'provisional_start_time')::boolean,false),
    case when coalesce((fixture->>'finished')::boolean,false) then 'finished'
      when coalesce((fixture->>'started')::boolean,false) then 'live' else 'scheduled' end,
    coalesce((fixture->>'finished_provisional')::boolean,false),now(),now()
  from jsonb_array_elements(fpl_fixtures) supplied(fixture)
  join public.football_teams home on home.season=normalized_season and home.fpl_team_id=(fixture->>'team_h')::integer
  join public.football_teams away on away.season=normalized_season and away.fpl_team_id=(fixture->>'team_a')::integer
  on conflict(season,fpl_fixture_id) do update set gameweek_number=excluded.gameweek_number,kickoff_at=excluded.kickoff_at,
    home_team_id=excluded.home_team_id,away_team_id=excluded.away_team_id,home_score=excluded.home_score,away_score=excluded.away_score,
    started=excluded.started,finished=excluded.finished,provisional_start_time=excluded.provisional_start_time,status=excluded.status,
    finished_provisional=excluded.finished_provisional,provider_synced_at=excluded.provider_synced_at,updated_at=now();
  get diagnostics fixture_count=row_count;
  return jsonb_build_object('teams',team_count,'fixtures',fixture_count,'synced_at',now());
end;
$$;
revoke all on function public.sync_fpl_data(text,jsonb,jsonb) from public;
grant execute on function public.sync_fpl_data(text,jsonb,jsonb) to authenticated;

create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype;
declare player_count integer; declare winners integer; declare losers integer; declare postponed_count integer;
declare unpaid_count integer; declare missing_count integer; declare unavailable_count integer; declare already_processed boolean;
declare problems text[]:=array[]::text[]; declare result jsonb; declare authoritative_results jsonb; declare locked_fixture record;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  if selected_pot.test_mode and selected_pot.status<>'draft' then raise exception 'Test mode is only allowed on draft pots'; end if;

  for locked_fixture in select distinct pick.fixture_id from public.player_picks pick
    where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek order by pick.fixture_id
  loop perform pg_advisory_xact_lock(public.fixture_result_lock_key(locked_fixture.fixture_id)); end loop;
  perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),selected_gameweek);

  select coalesce(jsonb_agg(jsonb_build_object('pick_id',pick.id,'player_id',pick.player_id,'fixture_id',fixture.id,
    'home_team_id',fixture.home_team_id,'away_team_id',fixture.away_team_id,'season',fixture.season,
    'home_score',case when selected_pot.test_mode then test_result.home_score else effective.effective_home_score end,
    'away_score',case when selected_pot.test_mode then test_result.away_score else effective.effective_away_score end,
    'status',case when selected_pot.test_mode and coalesce(test_result.postponed,false) then 'postponed'
      when selected_pot.test_mode then 'finished' else effective.effective_status end,
    'source',case when selected_pot.test_mode then 'test' else effective.result_source end,
    'processable',case when selected_pot.test_mode then test_result.fixture_id is not null and
        (test_result.postponed or (test_result.home_score is not null and test_result.away_score is not null))
      else effective.processable end,
    'outcome',case when selected_pot.test_mode and test_result.postponed then 'postponed'
      when selected_pot.test_mode and test_result.home_score=test_result.away_score then 'lost'
      when selected_pot.test_mode and ((pick.team_id=fixture.home_team_id and test_result.home_score>test_result.away_score)
        or (pick.team_id=fixture.away_team_id and test_result.away_score>test_result.home_score)) then 'won'
      when selected_pot.test_mode then 'lost'
      when not effective.processable then 'pending'
      when effective.effective_home_score=effective.effective_away_score then 'lost'
      when (pick.team_id=fixture.home_team_id and effective.effective_home_score>effective.effective_away_score)
        or (pick.team_id=fixture.away_team_id and effective.effective_away_score>effective.effective_home_score) then 'won'
      else 'lost' end) order by pick.id),'[]'::jsonb) into authoritative_results
  from public.player_picks pick join public.football_fixtures fixture on fixture.id=pick.fixture_id
  join lateral public.get_effective_fixture_result(fixture.id) effective on true
  left join public.pot_fixture_test_results test_result on test_result.pot_id=selected_pot_id and test_result.fixture_id=fixture.id
  where pick.pot_id=selected_pot_id and pick.gameweek_number=selected_gameweek;

  select exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) into already_processed;
  select count(*) into player_count from public.pot_players where pot_id=selected_pot_id and player_status='active';
  select count(*) into unpaid_count from public.pot_players where pot_id=selected_pot_id and player_status='active' and payment_status<>'paid';
  select count(*) into missing_count from public.pot_players membership where membership.pot_id=selected_pot_id
    and membership.player_status='active' and membership.payment_status='paid' and not exists(select 1 from public.player_picks pick
      where pick.pot_id=selected_pot_id and pick.player_id=membership.player_id and pick.gameweek_number=selected_gameweek);
  select count(*) into unavailable_count from jsonb_to_recordset(authoritative_results)
    as locked_result(pick_id bigint,processable boolean) where not locked_result.processable;
  if already_processed then problems:=array_append(problems,'This gameweek has already been processed.'); end if;
  if unpaid_count>0 then problems:=array_append(problems,unpaid_count||' active player(s) still need payment confirmation.'); end if;
  if missing_count>0 then problems:=array_append(problems,missing_count||' paid active player(s) do not have a locked pick.'); end if;
  if unavailable_count>0 then problems:=array_append(problems,unavailable_count||' pick result(s) are not available yet.'); end if;

  select count(*) filter(where outcome='won'),count(*) filter(where outcome='lost'),count(*) filter(where outcome='postponed')
    into winners,losers,postponed_count from jsonb_to_recordset(authoritative_results)
      as locked_result(outcome text);
  result:=jsonb_build_object('pot_id',selected_pot_id,'pot_name',selected_pot.name,'gameweek_number',selected_gameweek,
    'test_mode',selected_pot.test_mode,'processed',already_processed,'ready',cardinality(problems)=0,'player_count',player_count,
    'winners',coalesce(winners,0),'losers',coalesce(losers,0),'postponed',coalesce(postponed_count,0),'problems',to_jsonb(problems));
  if not apply_changes then return result; end if;
  if cardinality(problems)>0 then raise exception '%',array_to_string(problems,' '); end if;
  if exists(select 1 from public.pot_gameweek_processes where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'This gameweek has already been processed'; end if;
  if exists(select 1 from jsonb_to_recordset(authoritative_results) as locked_result(processable boolean,status text,home_score integer,away_score integer)
    where not locked_result.processable or (not selected_pot.test_mode and
      (locked_result.status<>'finished' or locked_result.home_score is null or locked_result.away_score is null))) then
    raise exception 'A locked fixture result is not final; process the preview again';
  end if;

  with resolved as (
    select * from jsonb_to_recordset(authoritative_results) as locked_result(pick_id bigint,player_id uuid,
      home_team_id bigint,away_team_id bigint,home_score integer,away_score integer,source text,season text,status text,outcome text)
  ), updated_picks as (
    update public.player_picks pick set outcome=resolved.outcome,resolved_home_team_id=resolved.home_team_id,
      resolved_away_team_id=resolved.away_team_id,resolved_home_score=resolved.home_score,
      resolved_away_score=resolved.away_score,result_source=resolved.source,resolved_at=now(),
      resolved_fixture_season=resolved.season,resolved_fixture_status=resolved.status
    from resolved where pick.id=resolved.pick_id and pick.resolved_at is null returning pick.player_id,pick.outcome
  ) update public.pot_players membership set player_status='eliminated'
    where membership.pot_id=selected_pot_id and membership.player_status='active'
      and exists(select 1 from updated_picks pick where pick.player_id=membership.player_id and pick.outcome='lost');
  insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
  values(selected_pot_id,selected_gameweek,selected_pot.test_mode,result,(select auth.uid()));
  return result||jsonb_build_object('processed',true);
end;
$$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

commit;
