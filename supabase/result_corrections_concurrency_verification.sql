-- Run after all three two-session concurrency cases in the disposable database.
do $$ begin
  if (select count(*) from public.fixture_result_overrides where fixture_id=-28304)<>1 then
    raise exception 'Concurrent corrections did not produce exactly one root';
  end if;
  if not exists(select 1 from public.player_picks where id=-28401 and outcome='won'
    and resolved_home_score=1 and resolved_away_score=0 and resolved_fixture_status='finished') then
    raise exception 'Processing did not preserve its locked authoritative snapshot';
  end if;
  if not exists(select 1 from public.football_fixtures where id=-28301 and home_score=0 and away_score=2) then
    raise exception 'Waiting synchronization did not run after processing committed';
  end if;
  if not exists(select 1 from public.pot_gameweek_processes where pot_id='00000000-0000-0000-0000-000000002301'
    and gameweek_number=1 and summary->>'winners'='1') then raise exception 'Locked process summary is inconsistent'; end if;
  if exists(select 1 from public.fixture_result_overrides where fixture_id=-28305) then
    raise exception 'Concurrent processing accepted a stale correction';
  end if;
  if not exists(select 1 from public.player_picks where id=-28402 and outcome='won'
    and resolved_home_score=1 and resolved_away_score=0) then raise exception 'Correction race changed the processing snapshot'; end if;
end; $$;
