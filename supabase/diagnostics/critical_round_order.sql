-- Read-only. Run as a database operator; returns no rows when mappings are correct.
begin read only;
with expected as (
  select g.pot_id,g.gameweek_number,row_number() over(partition by g.pot_id order by g.gameweek_number) expected_sequence,
    r.id round_id,r.sequence_number actual_sequence
  from public.pot_gameweeks g left join public.pot_rounds r
    on r.pot_id=g.pot_id and r.gameweek_number=g.gameweek_number
), affected as (
  select pot_id,jsonb_agg(jsonb_build_object('round_id',round_id,'gameweek',gameweek_number,
    'actual_sequence',actual_sequence,'expected_sequence',expected_sequence) order by gameweek_number) mappings
  from expected group by pot_id having bool_or(actual_sequence is distinct from expected_sequence)
)
select a.*,p.lifecycle_status,p.membership_locked_at,
  (select count(*) from public.player_picks x where x.pot_id=a.pot_id) pick_count,
  (select count(*) from public.pot_gameweek_processes x where x.pot_id=a.pot_id) processed_round_count,
  (select count(*) from public.pot_player_buyback_events x where x.pot_id=a.pot_id) buyback_event_count
from affected a join public.pots p on p.id=a.pot_id order by a.pot_id;
rollback;
