-- Phase P1 read-only preflight
-- Run after the representative pre-migration seed and before applying P1.
-- Returns sanitized counts and catalog names only. It performs no writes.

select current_setting('server_version') as postgres_version;

select count(*) as teams_referenced_by_multiple_seasons
from (
  select team_id from (
    select home_team_id as team_id,season from public.football_fixtures
    union all select away_team_id,season from public.football_fixtures
  ) fixture_team
  group by team_id having count(distinct season)>1
) ambiguous;

select count(*) as pot_fixture_season_mismatches
from public.player_picks pick
join public.pots pot on pot.id=pick.pot_id
join public.football_fixtures fixture on fixture.id=pick.fixture_id
where pot.season<>fixture.season;

select count(*) as duplicate_scoped_fixture_ids
from (select season,fpl_fixture_id from public.football_fixtures group by season,fpl_fixture_id having count(*)>1) duplicate;

select count(*) filter(where outcome<>'pending') as resolved_picks,count(*) filter(where outcome='pending') as pending_picks,
  count(*) filter(where outcome<>'pending' and (fixture.home_score is null or fixture.away_score is null)) as resolved_picks_with_incomplete_provider_scores
from public.player_picks pick join public.football_fixtures fixture on fixture.id=pick.fixture_id;

select table_name,constraint_name,constraint_type
from information_schema.table_constraints
where table_schema='public' and table_name in ('football_teams','football_fixtures','player_picks')
order by table_name,constraint_name;
