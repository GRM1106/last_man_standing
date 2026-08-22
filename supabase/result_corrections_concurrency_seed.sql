-- Disposable-only P2 two-session concurrency seed. Never run remotely.
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
values(-28201,'P2-CONCURRENCY-2032',-28201,-28201,'Concurrency Home','CCH',now()),
      (-28202,'P2-CONCURRENCY-2032',-28202,-28202,'Concurrency Away','CCA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
  home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
values(-28301,-28301,'P2-CONCURRENCY-2032',1,'2032-08-07T15:00:00Z',-28201,-28202,1,0,true,true,false,'finished',false,now(),now()),
      (-28302,-28302,'P2-CONCURRENCY-2032',2,'2032-08-14T15:00:00Z',-28201,-28202,null,null,false,false,false,'scheduled',false,now(),now()),
      (-28303,-28303,'P2-CONCURRENCY-2032',3,'2032-08-21T15:00:00Z',-28201,-28202,null,null,false,false,false,'scheduled',false,now(),now()),
      (-28304,-28304,'P2-CONCURRENCY-2032',4,'2032-08-28T15:00:00Z',-28201,-28202,null,null,false,false,false,'scheduled',false,now(),now()),
      (-28305,-28305,'P2-CONCURRENCY-2032',5,'2032-09-04T15:00:00Z',-28201,-28202,1,0,true,true,false,'finished',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by)
select '00000000-0000-0000-0000-000000002301','P2 concurrency pot','P2-CONCURRENCY-2032',0,0,'draft',id
from public.profiles where is_admin order by created_at limit 1;
insert into public.pot_gameweeks values('00000000-0000-0000-0000-000000002301',1);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000002301',id,'active','paid','available'
from public.profiles where is_admin order by created_at limit 1;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome)
select -28401,'00000000-0000-0000-0000-000000002301',id,1,-28301,-28201,'manual','pending'
from public.profiles where is_admin order by created_at limit 1;
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by)
select '00000000-0000-0000-0000-000000002302','P2 correction race pot','P2-CONCURRENCY-2032',0,0,'draft',id
from public.profiles where is_admin order by created_at limit 1;
insert into public.pot_gameweeks values('00000000-0000-0000-0000-000000002302',5);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000002302',id,'active','paid','available'
from public.profiles where is_admin order by created_at limit 1;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome)
select -28402,'00000000-0000-0000-0000-000000002302',id,5,-28305,-28201,'manual','pending'
from public.profiles where is_admin order by created_at limit 1;
