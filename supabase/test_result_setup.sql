-- 12 — Draft pot result testing
-- Run once in the Supabase SQL Editor after admin_pick_overview.sql.

alter table public.pots add column if not exists test_mode boolean not null default false;

create table if not exists public.pot_fixture_test_results (
  pot_id uuid not null references public.pots(id) on delete cascade,
  fixture_id bigint not null references public.football_fixtures(id) on delete cascade,
  home_score integer check (home_score>=0),
  away_score integer check (away_score>=0),
  postponed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (pot_id,fixture_id),
  check (postponed or (home_score is not null and away_score is not null))
);
alter table public.pot_fixture_test_results enable row level security;
revoke all on table public.pot_fixture_test_results from public,authenticated;

create or replace function public.set_pot_test_mode(selected_pot_id uuid,enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft') then raise exception 'Only draft pots can use test mode'; end if;
  update public.pots set test_mode=enabled where id=selected_pot_id;
  if not enabled then delete from public.pot_fixture_test_results where pot_id=selected_pot_id; end if;
end;
$$;
revoke all on function public.set_pot_test_mode(uuid,boolean) from public;
grant execute on function public.set_pot_test_mode(uuid,boolean) to authenticated;

create or replace function public.set_test_pick_scenario(selected_pot_id uuid,selected_pick_id bigint,scenario text)
returns void language plpgsql security definer set search_path = '' as $$
declare selected_pick public.player_picks%rowtype;
declare selected_fixture public.football_fixtures%rowtype;
declare selected_is_home boolean;
declare test_home integer;
declare test_away integer;
declare test_postponed boolean := false;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then raise exception 'Enable test mode on this draft pot first'; end if;
  if scenario not in ('won','drawn','lost','postponed') then raise exception 'Invalid test scenario'; end if;
  select * into selected_pick from public.player_picks where id=selected_pick_id and pot_id=selected_pot_id;
  if not found then raise exception 'Pick not found in this pot'; end if;
  select * into selected_fixture from public.football_fixtures where id=selected_pick.fixture_id;
  selected_is_home := selected_pick.team_id=selected_fixture.home_team_id;
  if scenario='postponed' then test_postponed:=true;
  elsif scenario='drawn' then test_home:=0;test_away:=0;
  elsif (scenario='won' and selected_is_home) or (scenario='lost' and not selected_is_home) then test_home:=1;test_away:=0;
  else test_home:=0;test_away:=1;
  end if;
  insert into public.pot_fixture_test_results(pot_id,fixture_id,home_score,away_score,postponed,updated_at)
  values(selected_pot_id,selected_fixture.id,test_home,test_away,test_postponed,now())
  on conflict(pot_id,fixture_id) do update set home_score=excluded.home_score,away_score=excluded.away_score,postponed=excluded.postponed,updated_at=now();
end;
$$;
revoke all on function public.set_test_pick_scenario(uuid,bigint,text) from public;
grant execute on function public.set_test_pick_scenario(uuid,bigint,text) to authenticated;

create or replace function public.get_admin_pick_overview(selected_pot_id uuid,selected_gameweek integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;
  if not exists(select 1 from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=selected_gameweek) then raise exception 'Gameweek is not part of this pot'; end if;
  select jsonb_build_object('pot_id',pot.id,'pot_name',pot.name,'pot_status',pot.status,'test_mode',pot.test_mode,'gameweek_number',selected_gameweek,
    'players',coalesce(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',coalesce(nullif(trim(concat_ws(' ',profile.first_name,profile.last_name)),''),profile.display_name,profile.email),
      'email',profile.email,'player_status',membership.player_status,'payment_status',membership.payment_status,
      'pick',case when pick.id is null then null else jsonb_build_object(
        'id',pick.id,'team_name',team.name,'emblem_url',team.emblem_url,'home_name',home.name,'away_name',away.name,
        'kickoff_at',fixture.kickoff_at,'selection_source',pick.selection_source,'outcome',pick.outcome,
        'preview_outcome',case
          when not pot.test_mode or test_result.fixture_id is null then pick.outcome
          when test_result.postponed then 'postponed'
          -- In Last Man Standing, a draw eliminates the player just like a loss.
          when test_result.home_score=test_result.away_score then 'lost'
          when (pick.team_id=fixture.home_team_id and test_result.home_score>test_result.away_score)
            or (pick.team_id=fixture.away_team_id and test_result.away_score>test_result.home_score) then 'won'
          else 'lost' end,
        'confirmed_at',pick.confirmed_at
      ) end
    ) order by coalesce(profile.first_name,profile.display_name,profile.email)),'[]'::jsonb)) into result
  from public.pots pot
  left join public.pot_players membership on membership.pot_id=pot.id
  left join public.profiles profile on profile.id=membership.player_id
  left join public.player_picks pick on pick.pot_id=pot.id and pick.player_id=profile.id and pick.gameweek_number=selected_gameweek
  left join public.football_teams team on team.id=pick.team_id
  left join public.football_fixtures fixture on fixture.id=pick.fixture_id
  left join public.football_teams home on home.id=fixture.home_team_id
  left join public.football_teams away on away.id=fixture.away_team_id
  left join public.pot_fixture_test_results test_result on test_result.pot_id=pot.id and test_result.fixture_id=fixture.id
  where pot.id=selected_pot_id group by pot.id,pot.name,pot.status,pot.test_mode;
  return result;
end;
$$;
revoke all on function public.get_admin_pick_overview(uuid,integer) from public;
grant execute on function public.get_admin_pick_overview(uuid,integer) to authenticated;
