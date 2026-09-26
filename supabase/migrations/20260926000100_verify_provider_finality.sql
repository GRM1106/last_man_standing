-- FPL completion flags are cumulative: completed fixtures report both true.
-- Missing/NULL/unsupported provider values cannot establish positive evidence.
-- Replace only the final ingestion base and readiness boundary; retain wrappers,
-- locks, audited overrides and the September 19 processor NULL protections.
begin;

CREATE OR REPLACE FUNCTION public.sync_fpl_data_p2_base(selected_season text, fpl_teams jsonb, fpl_fixtures jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    coalesce((fixture->>'started')::boolean,false),(fixture->'finished' = 'true'::jsonb) is true,
    coalesce((fixture->>'provisional_start_time')::boolean,false),
    case when (fixture->'finished' = 'true'::jsonb) is true then 'finished'
      when coalesce((fixture->>'started')::boolean,false) then 'live' else 'scheduled' end,
    (fixture->'finished_provisional' = 'true'::jsonb) is true,now(),now()
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_effective_fixture_result(selected_fixture_id bigint)
 RETURNS TABLE(fixture_id bigint, raw_home_score integer, raw_away_score integer, raw_status text, effective_home_score integer, effective_away_score integer, effective_status text, result_source text, override_id uuid, provider_synced_at timestamp with time zone, raw_finished boolean, raw_finished_provisional boolean, processable boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      else fixture.finished is true and fixture.finished_provisional is true and fixture.status='finished'
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
$function$
;

-- CREATE OR REPLACE retains the existing owner-only permissions. Explicitly
-- retain that boundary for fresh installations as well.
revoke all on function public.sync_fpl_data_p2_base(text,jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.get_effective_fixture_result(bigint) from public,anon,authenticated,service_role;
commit;
