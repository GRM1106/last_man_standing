-- Phase 2K: a failed pot automation must leave durable evidence while its game
-- mutation rolls back. Rolls back entirely; commits nothing.
--
-- The failure is forced by replacing one dependency of the automation body with a
-- raising stub inside this transaction. That exercises the real PL/pgSQL path rather
-- than mocking the outcome, and the replacement disappears with the rollback.
begin;

-- Self-contained: create a disposable administrator if the database has none, so this
-- file runs standalone as well as after the shared Phase 1 harness. Rolled back with
-- everything else.
do $$
begin
  if not exists(select 1 from public.profiles where is_admin) then
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000012700','authenticated','authenticated',
           'phase2k-persistence@example.test','local-test-only',now(),
           '{"provider":"email","providers":["email"]}','{"first_name":"Phase2K","last_name":"Persistence"}',now(),now());
    update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000012700';
  end if;
end $$;

create temporary table k as select id admin_id from public.profiles where is_admin limit 1;
do $$ begin if not exists(select 1 from k) then raise exception '2K persistence: no administrator available'; end if; end $$;
select set_config('request.jwt.claim.sub',(select admin_id::text from k),true);

-- Two disposable pots: one that must fail, one that must still succeed alongside it.
insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
 (-127101,'PHASE2KAP',-127101,-127101,'K Home','KH',now()),
 (-127102,'PHASE2KAP',-127102,-127102,'K Away','KA',now());
insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at) values
 (-127201,-127201,'PHASE2KAP',10,now()+interval '1 day',-127101,-127102,false,false,false,'scheduled',false,now(),now());

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
select '00000000-0000-0000-0000-000000012701','2K fail','PHASE2KAP',1000,1000,'active',admin_id,false,'in_progress',now() from k;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000012701',10,now()-interval '1 minute');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000012701',admin_id,'active','unpaid','available' from k;

insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
select '00000000-0000-0000-0000-000000012702','2K ok','PHASE2KAP',1000,1000,'active',admin_id,false,'in_progress',now() from k;
insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('00000000-0000-0000-0000-000000012702',10,now()+interval '2 days');
insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
select '00000000-0000-0000-0000-000000012702',admin_id,'active','unpaid','available' from k;

-- Baseline: health reports no failures before anything runs.
do $$ begin
  if ((select public.get_lms_operations_health())->'automation_summary'->>'failed')::integer <> 0 then
    raise exception '2K persistence: failed count should start at zero';
  end if;
end $$;

-- Force a deterministic failure inside the protected game region. assign_random_missing_picks
-- is called after the run row is inserted and inside the body that must roll back.
create or replace function public.assign_random_missing_picks(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  update public.pots set review_reason='PARTIAL GAME WRITE THAT MUST NOT SURVIVE' where id=selected_pot_id;
  raise exception 'synthetic automation failure for Phase 2K persistence verification';
end $$;

do $$
declare failing jsonb;succeeding jsonb;raised text;runs integer;failed_runs integer;leaked integer;partial integer;
begin
  begin
    failing:=public.run_lms_pot_automation_internal('00000000-0000-0000-0000-000000012701','admin',(select admin_id from k));
  exception when others then
    raised:=sqlstate;
  end;

  -- 1. The failure is reported to the caller rather than lost.
  if raised is not null then
    raise exception '2K persistence: automation re-raised (%) instead of returning a structured failure',raised;
  end if;
  if failing->>'status'<>'failed' then
    raise exception '2K persistence: caller was not told the pot failed, got %',coalesce(failing->>'status','<null>');
  end if;

  -- 2. Exactly one durable failed run survives, fully populated.
  select count(*) into runs from public.lms_automation_runs where pot_id='00000000-0000-0000-0000-000000012701';
  if runs<>1 then raise exception '2K persistence: expected exactly one durable run row, found %',runs; end if;
  select count(*) into failed_runs from public.lms_automation_runs
   where pot_id='00000000-0000-0000-0000-000000012701' and status='failed'
     and job_type='pot_automation' and source='admin' and error_class='invariant'
     and started_at is not null and finished_at is not null
     and round_id is not null and gameweek_number=10
     and safe_error='Automation stopped on an internal invariant'
     and result_summary ? 'sqlstate';
  if failed_runs<>1 then raise exception '2K persistence: durable failed run is missing required fields'; end if;

  -- 3. No raw exception text or SQL leaked into the stored evidence.
  select count(*) into leaked from public.lms_automation_runs
   where pot_id='00000000-0000-0000-0000-000000012701'
     and (coalesce(safe_error,'') ilike '%synthetic%' or result_summary::text ilike '%synthetic%'
          or coalesce(safe_error,'') ilike '%assign_random%' or result_summary::text ilike '%assign_random%');
  if leaked>0 then raise exception '2K persistence: raw exception detail leaked into the run record'; end if;
  if failing::text ilike '%synthetic%' then raise exception '2K persistence: raw exception detail leaked to the caller'; end if;

  -- 4. The failed automation's own game mutation rolled back.
  select count(*) into partial from public.pots
   where id='00000000-0000-0000-0000-000000012701' and review_reason='PARTIAL GAME WRITE THAT MUST NOT SURVIVE';
  if partial<>0 then raise exception '2K persistence: partial game state survived a failed automation'; end if;
  if (select count(*) from public.player_picks where pot_id='00000000-0000-0000-0000-000000012701')<>0 then
    raise exception '2K persistence: a failed automation left picks behind';
  end if;

  -- 5. Health now observes the failure.
  if ((select public.get_lms_operations_health())->'automation_summary'->>'failed')::integer <> 1 then
    raise exception '2K persistence: health did not observe the durable failed run';
  end if;

  -- 6. A healthy pot still records a non-failed run, and does not inflate the failed count.
  succeeding:=public.run_lms_pot_automation_internal('00000000-0000-0000-0000-000000012702','admin',(select admin_id from k));
  if succeeding->>'status'='failed' then raise exception '2K persistence: healthy pot reported as failed'; end if;
  if (select count(*) from public.lms_automation_runs where pot_id='00000000-0000-0000-0000-000000012702' and status<>'failed')<>1 then
    raise exception '2K persistence: healthy pot did not record its run';
  end if;
  if ((select public.get_lms_operations_health())->'automation_summary'->>'failed')::integer <> 1 then
    raise exception '2K persistence: a successful run changed the failed count';
  end if;

  -- 7. Repeating the failing pot appends a second attempt rather than overwriting.
  failing:=public.run_lms_pot_automation_internal('00000000-0000-0000-0000-000000012701','admin',(select admin_id from k));
  if failing->>'status'<>'failed' then raise exception '2K persistence: repeat failure not reported'; end if;
  if (select count(*) from public.lms_automation_runs where pot_id='00000000-0000-0000-0000-000000012701')<>2 then
    raise exception '2K persistence: attempt history did not append';
  end if;
  if (select count(distinct attempt) from public.lms_automation_runs where pot_id='00000000-0000-0000-0000-000000012701')<>2 then
    raise exception '2K persistence: attempt numbering did not advance';
  end if;
end $$;

-- 8. Multi-pot scan semantics: one failing pot must not stop the others, and the
-- summary must still report the failure.
do $$
declare summary jsonb;failed_items integer;
begin
  summary:=public.scan_lms_automation_internal('admin');
  select count(*) into failed_items from jsonb_array_elements(summary) item where item->>'status'='failed';
  if failed_items<1 then raise exception '2K persistence: scan summary lost the pot failure'; end if;
  if jsonb_array_length(summary)<2 then raise exception '2K persistence: scan stopped after the failing pot'; end if;
  if not exists(select 1 from jsonb_array_elements(summary) item
    where item->>'pot_id'='00000000-0000-0000-0000-000000012702' and coalesce(item->>'status','')<>'failed') then
    raise exception '2K persistence: healthy pot was not processed after the failing one';
  end if;
end $$;

-- 9. Authorization boundaries unchanged.
do $$ begin
  if has_function_privilege('authenticated','public.run_lms_pot_automation_internal(uuid,text,uuid)','execute')
    or has_function_privilege('anon','public.run_lms_pot_automation_internal(uuid,text,uuid)','execute') then
    raise exception '2K persistence: internal automation entry point is exposed';
  end if;
  if has_table_privilege('authenticated','public.lms_automation_runs','insert')
    or has_table_privilege('authenticated','public.lms_automation_runs','update') then
    raise exception '2K persistence: automation run history became writable';
  end if;
  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='run_lms_pot_automation_internal'
      and p.prosecdef and array_to_string(p.proconfig,',') like 'search_path=%') then
    raise exception '2K persistence: security hardening regressed';
  end if;
end $$;

rollback;
