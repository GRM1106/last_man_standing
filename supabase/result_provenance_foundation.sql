-- 24 — Result provenance, audit and cross-season integrity foundation (Phase P1)
-- Run once in the Supabase SQL Editor after player_team_availability.sql.
--
-- This is a forward migration for already-deployed databases. It deliberately
-- does not change result processing, postponement, correction, buy-back or pot
-- completion behaviour.

begin;

do $$
begin
  if to_regclass('public.football_teams') is null
    or to_regclass('public.football_fixtures') is null
    or to_regclass('public.player_picks') is null
    or to_regclass('public.pots') is null then
    raise exception 'Phase P1 requires football_teams, football_fixtures, player_picks and pots. Apply every documented pre-P1 SQL module first.';
  end if;
end;
$$;

-- A team row currently has no season. Infer it only where the deployed data is
-- unambiguous. A team referenced by fixtures from multiple seasons is evidence
-- that historical identities have already been merged and must be reviewed.
alter table public.football_teams add column if not exists season text;

do $$
declare ambiguous_team_count integer;
declare known_season_count integer;
declare fallback_season text;
begin
  select count(*) into ambiguous_team_count
  from (
    select team_id
    from (
      select home_team_id as team_id,season from public.football_fixtures
      union all
      select away_team_id,season from public.football_fixtures
    ) fixture_team
    group by team_id
    having count(distinct season) > 1
  ) ambiguous;

  if ambiguous_team_count > 0 then
    raise exception 'Phase P1 cannot infer season for % football team row(s) referenced by multiple seasons. No data was changed; reconcile these rows explicitly.',ambiguous_team_count;
  end if;

  if exists (
    select 1
    from public.player_picks pick
    join public.pots pot on pot.id=pick.pot_id
    join public.football_fixtures fixture on fixture.id=pick.fixture_id
    where pot.season<>fixture.season
  ) then
    raise exception 'Phase P1 found picks whose pot season differs from the referenced fixture season. Historical data may already be corrupted; migration stopped without deleting or merging rows.';
  end if;

  update public.football_teams team
  set season=inferred.season
  from (
    select team_id,min(season) as season
    from (
      select home_team_id as team_id,season from public.football_fixtures
      union all
      select away_team_id,season from public.football_fixtures
    ) fixture_team
    group by team_id
  ) inferred
  where inferred.team_id=team.id and team.season is null;

  select count(distinct season),min(season) into known_season_count,fallback_season
  from (
    select season from public.football_fixtures
    union all
    select season from public.pots
  ) known
  where nullif(trim(season),'') is not null;

  if exists(select 1 from public.football_teams where season is null) then
    if known_season_count<>1 then
      raise exception 'Phase P1 found unreferenced football teams but could not infer one unambiguous season. No rows were deleted; assign their season explicitly and rerun.';
    end if;
    update public.football_teams set season=fallback_season where season is null;
  end if;

  if exists(select 1 from public.football_teams where nullif(trim(season),'') is null) then
    raise exception 'Phase P1 requires a non-empty season for every football team.';
  end if;
  if exists(
    select 1 from public.football_fixtures fixture
    join public.football_teams home on home.id=fixture.home_team_id
    join public.football_teams away on away.id=fixture.away_team_id
    where home.season<>fixture.season or away.season<>fixture.season
  ) then
    raise exception 'Phase P1 found a fixture whose internal home/away team belongs to a different season. Migration stopped without rewriting references.';
  end if;
end;
$$;

alter table public.football_teams alter column season set not null;

do $$
declare constraint_record record;
declare team_id_attnum smallint;
declare fixture_id_attnum smallint;
begin
  select attnum into team_id_attnum from pg_attribute
  where attrelid='public.football_teams'::regclass and attname='fpl_team_id' and not attisdropped;
  select attnum into fixture_id_attnum from pg_attribute
  where attrelid='public.football_fixtures'::regclass and attname='fpl_fixture_id' and not attisdropped;

  -- Derive and remove the deployed single-column unique constraint names from
  -- the catalog rather than assuming PostgreSQL's generated names.
  for constraint_record in
    select conname from pg_constraint
    where conrelid='public.football_teams'::regclass and contype='u'
      and conkey=array[team_id_attnum]::smallint[]
  loop
    execute format('alter table public.football_teams drop constraint %I',constraint_record.conname);
  end loop;

  for constraint_record in
    select conname from pg_constraint
    where conrelid='public.football_fixtures'::regclass and contype='u'
      and conkey=array[fixture_id_attnum]::smallint[]
  loop
    execute format('alter table public.football_fixtures drop constraint %I',constraint_record.conname);
  end loop;
end;
$$;

do $$
begin
  if exists(select 1 from public.football_teams group by season,fpl_team_id having count(*)>1) then
    raise exception 'Phase P1 found duplicate (season,fpl_team_id) rows. No destructive deduplication was attempted.';
  end if;
  if exists(select 1 from public.football_fixtures group by season,fpl_fixture_id having count(*)>1) then
    raise exception 'Phase P1 found duplicate (season,fpl_fixture_id) rows. No destructive deduplication was attempted.';
  end if;
end;
$$;

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.football_teams'::regclass and conname='football_teams_season_fpl_team_id_key') then
    alter table public.football_teams add constraint football_teams_season_fpl_team_id_key unique(season,fpl_team_id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.football_fixtures'::regclass and conname='football_fixtures_season_fpl_fixture_id_key') then
    alter table public.football_fixtures add constraint football_fixtures_season_fpl_fixture_id_key unique(season,fpl_fixture_id);
  end if;
end;
$$;

do $$
declare team_columns smallint[];
declare fixture_columns smallint[];
begin
  select array_agg(attnum order by array_position(array['season','fpl_team_id'],attname::text)) into team_columns
  from pg_attribute where attrelid='public.football_teams'::regclass and attname=any(array['season','fpl_team_id']) and not attisdropped;
  select array_agg(attnum order by array_position(array['season','fpl_fixture_id'],attname::text)) into fixture_columns
  from pg_attribute where attrelid='public.football_fixtures'::regclass and attname=any(array['season','fpl_fixture_id']) and not attisdropped;
  if not exists(select 1 from pg_constraint where conrelid='public.football_teams'::regclass and contype='u' and conkey=team_columns) then
    raise exception 'Phase P1 expected an exact unique constraint on football_teams(season,fpl_team_id), but the catalog does not contain one.';
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.football_fixtures'::regclass and contype='u' and conkey=fixture_columns) then
    raise exception 'Phase P1 expected an exact unique constraint on football_fixtures(season,fpl_fixture_id), but the catalog does not contain one.';
  end if;
end;
$$;

create index if not exists football_teams_season_name_idx on public.football_teams(season,name);

-- Provider facts. These columns remain independent of future authoritative
-- overrides. P1 does not infer postponement from time or fixture movement.
alter table public.football_fixtures add column if not exists status text;
alter table public.football_fixtures add column if not exists finished_provisional boolean;
alter table public.football_fixtures add column if not exists provider_synced_at timestamptz;

update public.football_fixtures
set status=case when finished then 'finished' when started then 'live' else 'scheduled' end
where status is null;
update public.football_fixtures set finished_provisional=false where finished_provisional is null;
update public.football_fixtures set provider_synced_at=updated_at where provider_synced_at is null;

alter table public.football_fixtures alter column status set default 'scheduled';
alter table public.football_fixtures alter column status set not null;
alter table public.football_fixtures alter column finished_provisional set default false;
alter table public.football_fixtures alter column finished_provisional set not null;
alter table public.football_fixtures alter column provider_synced_at set default now();
alter table public.football_fixtures alter column provider_synced_at set not null;

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.football_fixtures'::regclass and conname='football_fixtures_status_check') then
    alter table public.football_fixtures add constraint football_fixtures_status_check
      check(status in ('scheduled','live','finished','postponed','abandoned','void'));
  end if;
end;
$$;
create index if not exists football_fixtures_season_status_gameweek_idx on public.football_fixtures(season,status,gameweek_number);

-- Nullable immutable resolution snapshots. Current processing deliberately
-- continues to read/write only the existing fixture facts and outcome column.
alter table public.player_picks add column if not exists resolved_home_team_id bigint references public.football_teams(id);
alter table public.player_picks add column if not exists resolved_away_team_id bigint references public.football_teams(id);
alter table public.player_picks add column if not exists resolved_home_score integer;
alter table public.player_picks add column if not exists resolved_away_score integer;
alter table public.player_picks add column if not exists result_source text;
alter table public.player_picks add column if not exists resolved_at timestamptz;
alter table public.player_picks add column if not exists resolved_fixture_season text;
alter table public.player_picks add column if not exists resolved_fixture_status text;

do $$
declare outcome_constraint record;
begin
  for outcome_constraint in
    select conname from pg_constraint
    where conrelid='public.player_picks'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%outcome%'
  loop
    execute format('alter table public.player_picks drop constraint %I',outcome_constraint.conname);
  end loop;
  alter table public.player_picks add constraint player_picks_outcome_check
    check(outcome in ('pending','won','lost','postponed','survived'));
end;
$$;

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass and conname='player_picks_result_source_check') then
    alter table public.player_picks add constraint player_picks_result_source_check
      check(result_source is null or result_source in ('api','admin_override','postponed','abandoned','void','test','legacy_backfill'));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass and conname='player_picks_resolved_scores_check') then
    alter table public.player_picks add constraint player_picks_resolved_scores_check
      check((resolved_home_score is null or resolved_home_score>=0) and (resolved_away_score is null or resolved_away_score>=0));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass and conname='player_picks_resolved_fixture_status_check') then
    alter table public.player_picks add constraint player_picks_resolved_fixture_status_check
      check(resolved_fixture_status is null or resolved_fixture_status in ('scheduled','live','finished','postponed','abandoned','void'));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass and conname='player_picks_resolved_fixture_season_check') then
    alter table public.player_picks add constraint player_picks_resolved_fixture_season_check
      check(resolved_fixture_season is null or nullif(trim(resolved_fixture_season),'') is not null);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.player_picks'::regclass and conname='player_picks_resolution_snapshot_check') then
    alter table public.player_picks add constraint player_picks_resolution_snapshot_check check(
      (resolved_at is null and resolved_home_team_id is null and resolved_away_team_id is null
        and resolved_home_score is null and resolved_away_score is null and result_source is null
        and resolved_fixture_season is null and resolved_fixture_status is null)
      or
      (resolved_at is not null and resolved_home_team_id is not null and resolved_away_team_id is not null
        and result_source is not null and resolved_fixture_season is not null and resolved_fixture_status is not null)
    );
  end if;
end;
$$;

with backfill as (
  select pick.id,fixture.home_team_id,fixture.away_team_id,
    case when process.test_run and test_result.fixture_id is not null then test_result.home_score else fixture.home_score end as home_score,
    case when process.test_run and test_result.fixture_id is not null then test_result.away_score else fixture.away_score end as away_score,
    case when process.test_run then 'test' else 'legacy_backfill' end as source,
    coalesce(process.processed_at,pick.confirmed_at) as resolution_time,
    fixture.season,
    case when process.test_run and coalesce(test_result.postponed,false) then 'postponed'
      when process.test_run and test_result.fixture_id is not null then 'finished'
      else fixture.status end as fixture_status
  from public.player_picks pick
  join public.football_fixtures fixture on fixture.id=pick.fixture_id
  left join public.pot_gameweek_processes process on process.pot_id=pick.pot_id and process.gameweek_number=pick.gameweek_number
  left join public.pot_fixture_test_results test_result on test_result.pot_id=pick.pot_id and test_result.fixture_id=fixture.id
  where pick.outcome<>'pending' and pick.resolved_at is null
    and (
      (process.test_run and coalesce(test_result.postponed,false))
      or (
        (case when process.test_run and test_result.fixture_id is not null then test_result.home_score else fixture.home_score end) is not null
        and (case when process.test_run and test_result.fixture_id is not null then test_result.away_score else fixture.away_score end) is not null
      )
    )
)
update public.player_picks pick
set resolved_home_team_id=backfill.home_team_id,
    resolved_away_team_id=backfill.away_team_id,
    resolved_home_score=backfill.home_score,
    resolved_away_score=backfill.away_score,
    result_source=backfill.source,
    resolved_at=backfill.resolution_time,
    resolved_fixture_season=backfill.season,
    resolved_fixture_status=backfill.fixture_status
from backfill where backfill.id=pick.id;

do $$
declare unresolved_backfill_count integer;
begin
  select count(*) into unresolved_backfill_count from public.player_picks where outcome<>'pending' and resolved_at is null;
  if unresolved_backfill_count>0 then
    raise warning 'Phase P1 could not safely backfill % resolved pick(s). Inspect public.get_p1_provenance_backfill_report() before later behaviour phases.',unresolved_backfill_count;
  end if;
end;
$$;

create or replace function public.prevent_pick_resolution_snapshot_change()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.resolved_at is not null and (
    new.resolved_home_team_id is distinct from old.resolved_home_team_id
    or new.resolved_away_team_id is distinct from old.resolved_away_team_id
    or new.resolved_home_score is distinct from old.resolved_home_score
    or new.resolved_away_score is distinct from old.resolved_away_score
    or new.result_source is distinct from old.result_source
    or new.resolved_at is distinct from old.resolved_at
    or new.resolved_fixture_season is distinct from old.resolved_fixture_season
    or new.resolved_fixture_status is distinct from old.resolved_fixture_status
  ) then
    raise exception 'Resolved pick provenance is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_pick_resolution_snapshot_change() from public;
drop trigger if exists player_picks_resolution_snapshot_immutable on public.player_picks;
create trigger player_picks_resolution_snapshot_immutable before update on public.player_picks
for each row execute function public.prevent_pick_resolution_snapshot_change();

-- Append-only audit/provenance storage. No client role receives table access and
-- no policy permits forged inserts. Controlled mutation RPCs arrive in P2+.
create table if not exists public.fixture_result_overrides (
  id uuid primary key default gen_random_uuid(),
  fixture_id bigint not null references public.football_fixtures(id),
  administrator_id uuid not null,
  reason text not null check(nullif(trim(reason),'') is not null),
  previous_home_score integer check(previous_home_score is null or previous_home_score>=0),
  previous_away_score integer check(previous_away_score is null or previous_away_score>=0),
  previous_status text not null check(previous_status in ('scheduled','live','finished','postponed','abandoned','void')),
  new_home_score integer check(new_home_score is null or new_home_score>=0),
  new_away_score integer check(new_away_score is null or new_away_score>=0),
  new_status text not null check(new_status in ('scheduled','live','finished','postponed','abandoned','void')),
  source text not null check(source in ('admin_correction','provider_correction','postponement','abandonment','void')),
  supersedes_id uuid unique references public.fixture_result_overrides(id),
  created_at timestamptz not null default now()
);

create table if not exists public.admin_audit_events (
  id uuid primary key default gen_random_uuid(),
  administrator_id uuid not null,
  action text not null check(nullif(trim(action),'') is not null),
  target_type text not null check(nullif(trim(target_type),'') is not null),
  target_identifier text not null check(nullif(trim(target_identifier),'') is not null),
  before_state jsonb,
  after_state jsonb,
  reason text,
  correlation_id uuid,
  created_at timestamptz not null default now(),
  check(reason is null or nullif(trim(reason),'') is not null)
);

create table if not exists public.pot_player_status_history (
  id uuid primary key default gen_random_uuid(),
  pot_id uuid not null references public.pots(id),
  player_id uuid not null references public.profiles(id),
  gameweek_number integer check(gameweek_number between 1 and 38),
  previous_status text check(previous_status is null or previous_status in ('active','eliminated','winner','withdrawn')),
  new_status text not null check(new_status in ('active','eliminated','winner','withdrawn')),
  cause text not null check(cause in ('processing','recalculation','buy_back','decision_window','admin_correction','test_reset','legacy_backfill')),
  correlation_id uuid,
  created_at timestamptz not null default now(),
  check(previous_status is distinct from new_status)
);

create index if not exists fixture_result_overrides_fixture_created_idx on public.fixture_result_overrides(fixture_id,created_at desc);
create index if not exists admin_audit_events_target_created_idx on public.admin_audit_events(target_type,target_identifier,created_at desc);
create index if not exists admin_audit_events_correlation_idx on public.admin_audit_events(correlation_id) where correlation_id is not null;
create index if not exists pot_player_status_history_player_gameweek_idx on public.pot_player_status_history(pot_id,player_id,gameweek_number,created_at);
create index if not exists pot_player_status_history_correlation_idx on public.pot_player_status_history(correlation_id) where correlation_id is not null;

alter table public.fixture_result_overrides enable row level security;
alter table public.admin_audit_events enable row level security;
alter table public.pot_player_status_history enable row level security;
revoke all on table public.fixture_result_overrides,public.admin_audit_events,public.pot_player_status_history from public,authenticated;

create or replace function public.reject_audit_row_mutation()
returns trigger language plpgsql set search_path='' as $$
begin
  raise exception '% is append-only',tg_table_name;
end;
$$;
revoke all on function public.reject_audit_row_mutation() from public;

drop trigger if exists fixture_result_overrides_append_only on public.fixture_result_overrides;
create trigger fixture_result_overrides_append_only before update or delete on public.fixture_result_overrides
for each row execute function public.reject_audit_row_mutation();
drop trigger if exists admin_audit_events_append_only on public.admin_audit_events;
create trigger admin_audit_events_append_only before update or delete on public.admin_audit_events
for each row execute function public.reject_audit_row_mutation();
drop trigger if exists pot_player_status_history_append_only on public.pot_player_status_history;
create trigger pot_player_status_history_append_only before update or delete on public.pot_player_status_history
for each row execute function public.reject_audit_row_mutation();

alter table public.pots add column if not exists review_status text;
alter table public.pots add column if not exists review_reason text;
alter table public.pots add column if not exists review_status_changed_at timestamptz;
update public.pots set review_status='none' where review_status is null;
update public.pots set review_status_changed_at=coalesce(review_status_changed_at,created_at,now()) where review_status_changed_at is null;
alter table public.pots alter column review_status set default 'none';
alter table public.pots alter column review_status set not null;
alter table public.pots alter column review_status_changed_at set default now();
alter table public.pots alter column review_status_changed_at set not null;
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.pots'::regclass and conname='pots_review_status_check') then
    alter table public.pots add constraint pots_review_status_check check(review_status in ('none','needs_review','reviewed'));
  end if;
end;
$$;

create or replace function public.get_p1_provenance_backfill_report()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  return jsonb_build_object(
    'resolved_picks', (select count(*) from public.player_picks where outcome<>'pending'),
    'snapshotted_picks', (select count(*) from public.player_picks where resolved_at is not null),
    'unresolved_backfill_rows', (select count(*) from public.player_picks where outcome<>'pending' and resolved_at is null),
    'unresolved_score_rows', (select count(*) from public.player_picks pick
      join public.football_fixtures fixture on fixture.id=pick.fixture_id
      left join public.pot_gameweek_processes process on process.pot_id=pick.pot_id and process.gameweek_number=pick.gameweek_number
      left join public.pot_fixture_test_results test_result on test_result.pot_id=pick.pot_id and test_result.fixture_id=fixture.id
      where pick.outcome<>'pending' and pick.resolved_at is null
        and not (coalesce(process.test_run,false) and coalesce(test_result.postponed,false))
        and ((case when process.test_run and test_result.fixture_id is not null then test_result.home_score else fixture.home_score end) is null
          or (case when process.test_run and test_result.fixture_id is not null then test_result.away_score else fixture.away_score end) is null)),
    'pending_picks_with_snapshot', (select count(*) from public.player_picks where outcome='pending' and resolved_at is not null)
  );
end;
$$;
revoke all on function public.get_p1_provenance_backfill_report() from public;
grant execute on function public.get_p1_provenance_backfill_report() to authenticated;

-- Mechanical compatibility for season-scoped team rows. This is the effective
-- module-17 definition with only remaining_teams restricted to the pot season.
create or replace function public.get_pot_selection(selected_pot_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare membership public.pot_players%rowtype;
declare selected_gameweek integer;
declare saved_pick jsonb;
declare fixture_options jsonb;
declare remaining_teams jsonb;
begin
  select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid());
  if not found then raise exception 'You are not assigned to this pot'; end if;

  select pick.gameweek_number into selected_gameweek from public.player_picks pick
  where pick.pot_id=selected_pot_id and pick.player_id=(select auth.uid()) and pick.outcome='pending'
  order by pick.gameweek_number desc limit 1;

  if selected_gameweek is null then
    select gameweek.gameweek_number into selected_gameweek
    from public.pot_gameweeks gameweek join public.pots pot on pot.id=gameweek.pot_id
    where gameweek.pot_id=selected_pot_id
      and not exists(select 1 from public.pot_gameweek_processes processed
        where processed.pot_id=selected_pot_id and processed.gameweek_number=gameweek.gameweek_number)
      and exists(select 1 from public.football_fixtures fixture
        where fixture.season=pot.season and fixture.gameweek_number=gameweek.gameweek_number
          and fixture.kickoff_at>now() and not fixture.finished)
    order by gameweek.gameweek_number limit 1;
  end if;

  select jsonb_build_object('id',pick.id,'gameweek_number',pick.gameweek_number,'team_id',pick.team_id,
    'fixture_id',pick.fixture_id,'outcome',pick.outcome,'confirmed_at',pick.confirmed_at,
    'team_name',team.name,'emblem_url',team.emblem_url,'home_name',home.name,'away_name',away.name,'kickoff_at',fixture.kickoff_at)
  into saved_pick from public.player_picks pick
  join public.football_teams team on team.id=pick.team_id
  join public.football_fixtures fixture on fixture.id=pick.fixture_id
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  where pick.pot_id=selected_pot_id and pick.player_id=(select auth.uid()) and pick.gameweek_number=selected_gameweek;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',fixture.id,'gameweek_number',fixture.gameweek_number,'kickoff_at',fixture.kickoff_at,
    'started',fixture.started,'finished',fixture.finished,'home_score',fixture.home_score,'away_score',fixture.away_score,
    'home_team',jsonb_build_object('id',home.id,'name',home.name,'short_name',home.short_name,'emblem_url',home.emblem_url,
      'form',coalesce((select to_jsonb(form.last_five) from public.football_team_form form where form.team_id=home.id),'[]'::jsonb),
      'available',not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=(select auth.uid()) and used.team_id=home.id)),
    'away_team',jsonb_build_object('id',away.id,'name',away.name,'short_name',away.short_name,'emblem_url',away.emblem_url,
      'form',coalesce((select to_jsonb(form.last_five) from public.football_team_form form where form.team_id=away.id),'[]'::jsonb),
      'available',not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id and used.player_id=(select auth.uid()) and used.team_id=away.id))
  ) order by fixture.kickoff_at),'[]'::jsonb) into fixture_options
  from public.football_fixtures fixture
  join public.pots pot on pot.id=selected_pot_id and pot.season=fixture.season
  join public.football_teams home on home.id=fixture.home_team_id
  join public.football_teams away on away.id=fixture.away_team_id
  where fixture.gameweek_number=selected_gameweek;

  select coalesce(jsonb_agg(jsonb_build_object('id',team.id,'name',team.name,'short_name',team.short_name,'emblem_url',team.emblem_url)
    order by team.name),'[]'::jsonb) into remaining_teams from public.football_teams team
  join public.pots pot on pot.id=selected_pot_id and pot.season=team.season
  where not exists(select 1 from public.player_picks used where used.pot_id=selected_pot_id
    and used.player_id=(select auth.uid()) and used.team_id=team.id);

  return jsonb_build_object('gameweek_number',selected_gameweek,'payment_status',membership.payment_status,
    'player_status',membership.player_status,'pick',saved_pick,'fixtures',fixture_options,'remaining_teams',remaining_teams);
end;
$$;
revoke all on function public.get_pot_selection(uuid) from public;
grant execute on function public.get_pot_selection(uuid) to authenticated;

-- The existing public signatures and return shapes remain unchanged, but
-- provider identities, sync joins and the selection list are season-scoped.
create or replace function public.sync_fpl_data(selected_season text,fpl_teams jsonb,fpl_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare team_count integer;
declare fixture_count integer;
declare normalized_season text:=trim(selected_season);
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if normalized_season is null or normalized_season='' then raise exception 'Season is required'; end if;
  if jsonb_typeof(fpl_teams)<>'array' or jsonb_typeof(fpl_fixtures)<>'array' then raise exception 'Invalid FPL data'; end if;

  insert into public.football_teams(season,fpl_team_id,code,name,short_name,emblem_url,updated_at)
  select normalized_season,(team->>'id')::integer,(team->>'code')::integer,team->>'name',team->>'short_name',
    'https://resources.premierleague.com/premierleague/badges/100/t'||(team->>'code')||'.png',now()
  from jsonb_array_elements(fpl_teams) as supplied(team)
  on conflict(season,fpl_team_id) do update set code=excluded.code,name=excluded.name,short_name=excluded.short_name,
    emblem_url=excluded.emblem_url,updated_at=now();
  get diagnostics team_count=row_count;

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
  from jsonb_array_elements(fpl_fixtures) as supplied(fixture)
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

commit;
