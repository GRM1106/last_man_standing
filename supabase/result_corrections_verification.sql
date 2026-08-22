-- Phase P2 controlled-result verification (rollback-only)
-- Run only in a disposable Supabase database after the P1 disposable path and
-- result_corrections.sql. Never run in production.

begin;

create temporary table p2_verification_context(admin_id uuid not null) on commit drop;
insert into p2_verification_context select id from public.profiles where is_admin order by created_at limit 1;
do $$ begin
  if not exists(select 1 from p2_verification_context) then raise exception 'Phase P2 verification requires one disposable administrator profile'; end if;
end; $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from p2_verification_context),true);

insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at)
values(-27201,'P2-VERIFY-2031',-27201,-27201,'P2 Home','P2H',now()),
      (-27202,'P2-VERIFY-2031',-27202,-27202,'P2 Away','P2A',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
  home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
values(-27301,-27301,'P2-VERIFY-2031',1,'2031-08-09T15:00:00Z',-27201,-27202,1,0,true,true,false,'finished',false,now(),now()),
      (-27302,-27302,'P2-VERIFY-2031',2,'2031-08-16T15:00:00Z',-27201,-27202,0,0,true,true,false,'finished',false,now(),now());
insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by)
select '00000000-0000-0000-0000-000000002201','P2 verification pot','P2-VERIFY-2031',0,0,'draft',admin_id from p2_verification_context;
insert into public.pot_gameweeks values('00000000-0000-0000-0000-000000002201',1);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000002201',admin_id,'active','paid','available' from p2_verification_context;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome)
select -27401,'00000000-0000-0000-0000-000000002201',admin_id,1,-27301,-27201,'manual','pending' from p2_verification_context;

-- A provider result marked finished but still provisional must not be usable.
update public.football_fixtures set finished_provisional=true where id=-27301;
do $$ declare preview jsonb; begin
  preview:=public.process_pot_gameweek('00000000-0000-0000-0000-000000002201',1,false);
  if (preview->>'ready')::boolean or (preview->>'losers')::integer<>0 then raise exception 'Provisional provider result was considered final'; end if;
  begin
    perform public.process_pot_gameweek('00000000-0000-0000-0000-000000002201',1,true);
    raise exception 'Provisional provider result was processed';
  exception when raise_exception then
    if sqlerrm not like '%pick result(s) are not available yet.%' then raise; end if;
  end;
  if exists(select 1 from public.player_picks where id=-27401 and resolved_at is not null) then raise exception 'Provisional result wrote a snapshot'; end if;
end; $$;
update public.football_fixtures set finished_provisional=false,provider_synced_at=now() where id=-27301;

do $$
declare preview jsonb; before_override_count integer; before_audit_count integer;
begin
  select count(*) into before_override_count from public.fixture_result_overrides where fixture_id=-27301;
  select count(*) into before_audit_count from public.admin_audit_events where target_identifier in ('-27301','00000000-0000-0000-0000-000000002201');
  preview:=public.preview_fixture_result_override(-27301,0,2,'finished','Verified correction evidence');
  if preview#>>'{raw,home_score}'<>'1' or preview#>>'{effective_before,home_score}'<>'1'
    or preview#>>'{proposed,away_score}'<>'2' or (preview->>'review_count')::integer<>0 then
    raise exception 'Impact preview returned incorrect raw, effective or impact values: %',preview;
  end if;
  if (select count(*) from public.fixture_result_overrides where fixture_id=-27301)<>before_override_count
    or (select count(*) from public.admin_audit_events where target_identifier in ('-27301','00000000-0000-0000-0000-000000002201'))<>before_audit_count then
    raise exception 'Impact preview mutated provenance or audit rows';
  end if;
end;
$$;

create temporary table p2_stale_preview(version text not null) on commit drop;
insert into p2_stale_preview values(public.fixture_effective_version(-27301));
select public.create_fixture_result_override(-27301,0,2,'finished','Verified correction evidence',(select version from p2_stale_preview));
do $$ begin
  begin
    perform public.create_fixture_result_override(-27301,2,0,'finished','Stale preview attempt',(select version from p2_stale_preview));
    raise exception 'Stale preview was accepted';
  exception when raise_exception then if sqlerrm<>'Result changed; preview again' then raise; end if; end;
end; $$;
do $$
declare effective record;
begin
  select * into effective from public.get_effective_fixture_result(-27301);
  if effective.raw_home_score<>1 or effective.raw_away_score<>0 or effective.raw_status<>'finished'
    or effective.effective_home_score<>0 or effective.effective_away_score<>2 or effective.effective_status<>'finished'
    or effective.result_source<>'admin_override' or effective.override_id is null then
    raise exception 'Raw/effective result separation failed';
  end if;
  if (select count(*) from public.fixture_result_overrides where fixture_id=-27301)<>1 then raise exception 'First override was not recorded exactly once'; end if;
  if not exists(select 1 from public.admin_audit_events where action='fixture_result_overridden' and target_identifier='-27301'
    and reason='Verified correction evidence' and before_state->>'home_score'='1' and after_state->>'away_score'='2') then
    raise exception 'Fixture override audit event is incomplete';
  end if;
end;
$$;

select public.sync_fpl_data(
  'P2-VERIFY-2031',
  '[{"id":-27201,"code":-27201,"name":"P2 Home provider refresh","short_name":"P2H"},{"id":-27202,"code":-27202,"name":"P2 Away provider refresh","short_name":"P2A"}]'::jsonb,
  '[{"id":-27301,"event":1,"kickoff_time":"2031-08-09T15:00:00Z","team_h":-27201,"team_a":-27202,"team_h_score":3,"team_a_score":0,"started":true,"finished":true,"finished_provisional":false,"provisional_start_time":false}]'::jsonb
);
do $$
declare effective record;
begin
  select * into effective from public.get_effective_fixture_result(-27301);
  if effective.raw_home_score<>3 or effective.raw_away_score<>0 then raise exception 'Provider synchronization did not update raw facts'; end if;
  if effective.effective_home_score<>0 or effective.effective_away_score<>2 or effective.result_source<>'admin_override' then
    raise exception 'Provider synchronization overwrote the authoritative override';
  end if;
  if (select count(*) from public.fixture_result_overrides where fixture_id=-27301)<>1 then raise exception 'Provider synchronization changed override history'; end if;
end;
$$;

select public.process_pot_gameweek('00000000-0000-0000-0000-000000002201',1,true);
do $$ begin
  if not exists(select 1 from public.player_picks where id=-27401 and outcome='lost'
    and resolved_home_team_id=-27201 and resolved_away_team_id=-27202 and resolved_home_score=0 and resolved_away_score=2
    and result_source='admin_override' and resolved_fixture_season='P2-VERIFY-2031' and resolved_fixture_status='finished' and resolved_at is not null) then
    raise exception 'Processing did not atomically snapshot the authoritative result';
  end if;
  if not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000002201'
    and player_id=(select admin_id from p2_verification_context) and player_status='eliminated' and buy_back_status='available') then
    raise exception 'Initial authoritative processing result was not applied as expected';
  end if;
end; $$;

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by)
select '00000000-0000-0000-0000-000000002202','P2 completed verification pot','P2-VERIFY-2031',0,0,'complete',admin_id from p2_verification_context;
insert into public.pot_gameweeks values('00000000-0000-0000-0000-000000002202',1);
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status,buy_back_used_at)
select '00000000-0000-0000-0000-000000002202',admin_id,'winner','paid','used',now() from p2_verification_context;
insert into public.player_picks(id,pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome)
select -27402,'00000000-0000-0000-0000-000000002202',admin_id,1,-27301,-27202,'manual','pending' from p2_verification_context;
create temporary table p2_process_summary(summary jsonb not null) on commit drop;
insert into p2_process_summary select summary from public.pot_gameweek_processes
  where pot_id='00000000-0000-0000-0000-000000002201' and gameweek_number=1;

select public.create_fixture_result_override(-27301,2,1,'finished','Later provider correction',public.fixture_effective_version(-27301));
do $$
declare effective record; first_id uuid; second_id uuid;
begin
  select * into effective from public.get_effective_fixture_result(-27301);
  if effective.effective_home_score<>2 or effective.effective_away_score<>1 then raise exception 'Superseding correction is not effective'; end if;
  select id into first_id from public.fixture_result_overrides where fixture_id=-27301 and supersedes_id is null;
  select id into second_id from public.fixture_result_overrides where fixture_id=-27301 and supersedes_id=first_id;
  if first_id is null or second_id is null or effective.override_id<>second_id then raise exception 'Override supersession linkage is incorrect'; end if;
  if not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000002201' and review_status='needs_review'
    and review_reason='Fixture correction requires review: Later provider correction') then raise exception 'Processed pot was not flagged for review'; end if;
  if not exists(select 1 from public.admin_audit_events where action='pot_flagged_for_result_review'
    and target_identifier='00000000-0000-0000-0000-000000002201' and reason='Later provider correction') then
    raise exception 'Processed-pot review flag was not audited';
  end if;
  if not exists(select 1 from public.player_picks where id=-27401 and outcome='lost' and resolved_home_score=0 and resolved_away_score=2)
    or not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000002201' and player_status='eliminated') then
    raise exception 'Processed correction rewrote an immutable outcome or player state';
  end if;
  if not exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000002202' and status='complete' and review_status='needs_review')
    or not exists(select 1 from public.pot_players where pot_id='00000000-0000-0000-0000-000000002202'
      and player_status='winner' and buy_back_status='used') then raise exception 'Completed pot was rewritten or not flagged'; end if;
  if (select summary from public.pot_gameweek_processes where pot_id='00000000-0000-0000-0000-000000002201' and gameweek_number=1)
    is distinct from (select summary from p2_process_summary) then raise exception 'Historical process summary changed'; end if;
end;
$$;

do $$ begin
  begin
    perform public.create_fixture_result_override(-27301,2,1,'finished','No-op attempt',public.fixture_effective_version(-27301));
    raise exception 'No-op override was accepted';
  exception when raise_exception then if sqlerrm<>'The proposed correction does not change the effective result' then raise; end if; end;
  begin
    perform public.preview_fixture_result_override(-27301,null,null,'finished','Invalid score attempt');
    raise exception 'Finished override without scores was accepted';
  exception when raise_exception then if sqlerrm<>'Finished fixtures require both scores' then raise; end if; end;
  begin
    perform public.preview_fixture_result_override(-27301,-1,1,'finished','Negative score attempt');
    raise exception 'Negative score override was accepted';
  exception when raise_exception then if sqlerrm<>'Scores cannot be negative' then raise; end if; end;
  begin
    perform public.preview_fixture_result_override(-27301,1,null,'finished','Partial score attempt');
    raise exception 'Partial score override was accepted';
  exception when raise_exception then if sqlerrm<>'Both scores must be supplied together' then raise; end if; end;
  begin
    perform public.preview_fixture_result_override(-27301,null,null,'scheduled','Invalid source/status attempt');
    raise exception 'Administrator scheduled transition was accepted';
  exception when raise_exception then if sqlerrm<>'Administrators cannot set that fixture status' then raise; end if; end;
end; $$;

do $$ declare first_id uuid; second_id uuid; other_id uuid; begin
  select id into first_id from public.fixture_result_overrides where fixture_id=-27301 and supersedes_id is null;
  select id into second_id from public.fixture_result_overrides where fixture_id=-27301 and supersedes_id=first_id;
  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source)
    select -27301,admin_id,'second root','finished','finished','admin_correction' from p2_verification_context;
    raise exception 'Second override root was accepted';
  exception when unique_violation then null; end;
  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source,supersedes_id)
    select -27301,admin_id,'forked successor','finished','finished','admin_correction',first_id from p2_verification_context;
    raise exception 'Forked override successor was accepted';
  exception when unique_violation then null; end;
  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source,supersedes_id)
    select -27301,admin_id,'malformed successor','finished','finished','admin_correction',gen_random_uuid() from p2_verification_context;
    raise exception 'Malformed override chain was accepted';
  exception when foreign_key_violation then null; end;
  insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source)
    select -27302,admin_id,'other fixture root','finished','finished','admin_correction' from p2_verification_context returning id into other_id;
  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source,supersedes_id)
    select -27302,admin_id,'cross fixture successor','finished','finished','admin_correction',second_id from p2_verification_context;
    raise exception 'Cross-fixture supersession was accepted';
  exception when foreign_key_violation then null; end;
end; $$;

do $$ begin
  begin
    update public.fixture_result_overrides set reason='tampered' where fixture_id=-27301;
    raise exception 'Append-only override update was accepted';
  exception when raise_exception then if sqlerrm<>'fixture_result_overrides is append-only' then raise; end if; end;
  begin
    delete from public.admin_audit_events where target_identifier='-27301';
    raise exception 'Append-only audit deletion was accepted';
  exception when raise_exception then if sqlerrm<>'admin_audit_events is append-only' then raise; end if; end;
end; $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$ begin
  begin
    perform public.preview_fixture_result_override(-27301,1,1,'finished','Forged preview');
    raise exception 'Non-admin impact preview was accepted';
  exception when raise_exception then if sqlerrm<>'Administrator access required' then raise; end if; end;
  begin
    perform public.create_fixture_result_override(-27301,1,1,'finished','Forged correction','forged-version');
    raise exception 'Non-admin correction was accepted';
  exception when raise_exception then if sqlerrm<>'Administrator access required' then raise; end if; end;
  begin
    insert into public.fixture_result_overrides(fixture_id,administrator_id,reason,previous_status,new_status,source)
    values(-27301,'00000000-0000-0000-0000-000000000001','forged','finished','finished','admin_correction');
    raise exception 'Authenticated direct override insert was accepted';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;

set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  begin
    perform public.create_fixture_result_override(-27301,1,1,'finished','Anonymous correction','forged-version');
    raise exception 'Anonymous correction execution was accepted';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.admin_audit_events(administrator_id,action,target_type,target_identifier)
    values('00000000-0000-0000-0000-000000000001','forged-anon','fixture','-27301');
    raise exception 'Anonymous direct audit insert was accepted';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;

rollback;

do $$ begin
  if exists(select 1 from public.football_teams where season='P2-VERIFY-2031')
    or exists(select 1 from public.football_fixtures where season='P2-VERIFY-2031')
    or exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000002201')
    or exists(select 1 from public.pots where id='00000000-0000-0000-0000-000000002202')
    or exists(select 1 from public.player_picks where id in (-27401,-27402))
    or exists(select 1 from public.fixture_result_overrides where fixture_id=-27301)
    or exists(select 1 from public.admin_audit_events where target_identifier in ('-27301','00000000-0000-0000-0000-000000002201')) then
    raise exception 'Phase P2 rollback left synthetic verification rows behind';
  end if;
end; $$;
