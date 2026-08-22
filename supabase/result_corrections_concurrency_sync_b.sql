-- Session B: start while processing session A sleeps. The shared fixture lock
-- makes this wait; the later raw update cannot alter A's committed snapshot.
begin;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where is_admin order by created_at limit 1),true);
select public.sync_fpl_data('P2-CONCURRENCY-2032',
  '[{"id":-28201,"code":-28201,"name":"Concurrency Home","short_name":"CCH"},{"id":-28202,"code":-28202,"name":"Concurrency Away","short_name":"CCA"}]'::jsonb,
  '[{"id":-28301,"event":1,"kickoff_time":"2032-08-07T15:00:00Z","team_h":-28201,"team_a":-28202,"team_h_score":0,"team_a_score":2,"started":true,"finished":true,"finished_provisional":false,"provisional_start_time":false}]'::jsonb);
commit;
