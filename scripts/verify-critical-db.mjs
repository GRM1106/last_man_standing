import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runSchedulerPipeline } from '../server/scheduler-pipeline.js';
import { createSchedulerOperations } from '../server/scheduler-operations.js';

const admin = '00000000-0000-0000-0000-000000003001';
const member = '00000000-0000-0000-0000-000000093001';
const other = '00000000-0000-0000-0000-000000093002';
const system = '00000000-0000-0000-0000-000000000001';
const history = '00000000-0000-0000-0000-000000093100';
const brokenSchedule = '00000000-0000-0000-0000-000000093110';
const brokenMember = '00000000-0000-0000-0000-000000093011';
const q = value => value == null ? 'null' : typeof value === 'boolean' ? String(value) : `'${(typeof value === 'object' ? JSON.stringify(value) : String(value)).replaceAll("'", "''")}'`;
const expectSqlError = (operation, pattern) => assert.throws(operation, error => pattern.test(error.stderr?.toString() || ''));
const claims = (role, sub) => `set local role ${role}; set local "request.jwt.claims"=${q({ role, ...(sub ? { sub } : {}) })};`;
const asRole = (db, role, sub, sql) => db.sql(`begin; ${claims(role, sub)} ${sql}; commit;`).trim();
const waitForSql = async (db, description, statement, timeoutMs = 5_000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (db.sql(statement).trim() === 't') return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${description}`);
};
const rpc = (db, name, args = {}, role = 'authenticated', sub = admin) => {
  assert.match(name, /^[a-z_]+$/);
  const params = Object.entries(args).map(([key, value]) => { assert.match(key, /^[a-z_]+$/); return `${key} => ${q(value)}`; }).join(',');
  return JSON.parse(asRole(db, role, sub, `select public.${name}(${params})` ) || 'null');
};
const snapshot = db => db.sql(`select jsonb_build_object(
  'rounds',(select jsonb_agg(to_jsonb(r) order by sequence_number) from public.pot_rounds r where pot_id='${history}'),
  'process',(select to_jsonb(p) from public.pot_gameweek_processes p where pot_id='${history}'),
  'completion',(select to_jsonb(c) from public.pot_completions c where pot_id='${history}'))`).trim();
let historyBefore;

export function seedHistoricalData(db) {
  db.sql(`insert into auth.users(id,email,raw_user_meta_data) values
  ('${admin}','phase1-admin@example.test','{"first_name":"Phase","last_name":"Admin"}'),
  ('${brokenMember}','broken-schedule-member@example.test','{"first_name":"Broken","last_name":"Schedule"}');
  update public.profiles set approved=true,is_admin=true where id='${admin}';
  update public.profiles set approved=true where id='${brokenMember}';
  insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,created_by,status,lifecycle_status)
  values('${history}','Historical mapping fixture','CRITICAL-HISTORY',1000,1000,'${admin}','complete','complete');
  -- Deliberately model an old, insertion-ordered mapping before the corrective migration.
  insert into public.pot_gameweeks(pot_id,gameweek_number) values('${history}',38),('${history}',37);
  insert into public.pot_players(pot_id,player_id,player_status,payment_status) values('${history}','${admin}','active','paid');
  insert into public.pot_round_players(round_id,pot_id,player_id,entered_player_status) select id,'${history}','${admin}','active' from public.pot_rounds where pot_id='${history}' and gameweek_number=38;
  insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by)
  values('${history}',38,false,'{"historical":true}','${admin}');
  insert into public.pot_completions(pot_id,round_id,gameweek_number,resolution_rule,entry_contribution_pence,buyback_contribution_pence,total_prize_pence,winner_count,completed_by)
  select '${history}',id,38,'gw38_survivors',1000,0,1000,1,'${admin}' from public.pot_rounds where pot_id='${history}' and gameweek_number=38;

  -- Populated pre-remediation failure: insertion order makes GW2→1, GW1→2,
  -- GW3→3. The lost GW1 pick previously entitled this member to the sequence-3
  -- GW3 cohort even though GW2 remained unprocessed.
  insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values
  (-931101,'CRIT-BROKEN',-931101,-931101,'Broken Home','BRH',now()),
  (-931102,'CRIT-BROKEN',-931102,-931102,'Broken Away','BRA',now());
  insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,
    home_score,away_score,started,finished,provisional_start_time,status,finished_provisional,provider_synced_at,updated_at)
  values(-931201,-931201,'CRIT-BROKEN',1,now()-interval '2 days',-931101,-931102,
    0,1,true,true,false,'finished',false,now(),now());
  insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,created_by,status,lifecycle_status,membership_locked_at)
  values('${brokenSchedule}','Populated invalid schedule','CRIT-BROKEN',1000,1000,'${admin}','active','in_progress',now());
  insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
  values('${brokenSchedule}',2,now()-interval '1 day');
  insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
  values('${brokenSchedule}',1,now()-interval '1 day');
  insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at)
  values('${brokenSchedule}',3,now()+interval '1 day');
  insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status)
  values('${brokenSchedule}','${brokenMember}','eliminated','paid','available');
  insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
    selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at,selection_eligible,
    resolved_home_team_id,resolved_away_team_id,resolved_home_score,resolved_away_score,result_source,resolved_at,
    resolved_fixture_season,resolved_fixture_status)
  values('${brokenSchedule}','${brokenMember}',1,-931201,-931101,'manual','lost',1,-931101,-931102,
    now()-interval '2 days',true,-931101,-931102,0,1,'api',now()-interval '1 day',
    'CRIT-BROKEN','finished');`);
  assert.equal(db.sql(`select string_agg(gameweek_number||'→'||sequence_number,', ' order by sequence_number)
    from public.pot_rounds where pot_id='${brokenSchedule}'`).trim(), '2→1, 1→2, 3→3');
  historyBefore = snapshot(db);
}
export function verifyHistoricalData(db) {
  assert.equal(snapshot(db), historyBefore, 'forward migrations must preserve historical rows and human attribution exactly');
  assert.equal(db.sql(`select count(*) from public.lms_audit_actors where id='${admin}' and profile_id='${admin}' and actor_type='human'`).trim(), '1');
  const diagnostic = db.sql(readFileSync(new URL('../supabase/diagnostics/critical_round_order.sql', import.meta.url), 'utf8'));
  assert.ok(diagnostic.includes(history), 'read-only diagnostic must find the deliberately incorrect historical pot');
  console.log('PASS unchanged historical round IDs/mappings/process/completion; diagnostic detects affected pot.');
}

function verifyHistoricalScheduleGate(db) {
  const rows = (table, predicate = `pot_id='${brokenSchedule}'`) =>
    `(select coalesce(jsonb_agg(to_jsonb(row_data) order by to_jsonb(row_data)::text),'[]')
      from (select * from public.${table} where ${predicate}) row_data)`;
  // Snapshot every pot-scoped relation reachable from processing, automation and
  // buy-back code, including downstream review/adjudication records.
  const state = () => db.sql(`select jsonb_build_object(
    'pot',${rows('pots', `id='${brokenSchedule}'`)},
    'gameweeks',${rows('pot_gameweeks')},
    'rounds',${rows('pot_rounds')},
    'round_players',${rows('pot_round_players')},
    'memberships',${rows('pot_players')},
    'picks',${rows('player_picks')},
    'test_results',${rows('pot_fixture_test_results')},
    'processes',${rows('pot_gameweek_processes')},
    'completions',${rows('pot_completions')},
    'winners',${rows('pot_winners')},
    'reinstatements',${rows('round_collective_reinstatements')},
    'buyback_events',${rows('pot_player_buyback_events')},
    'automation_runs',${rows('lms_automation_runs')},
    'review_cases',${rows('lms_review_cases')},
    'adjudications',${rows('pot_completion_adjudications')},
    'adjudicated_winners',${rows('pot_adjudicated_winners', `adjudication_id in (
      select id from public.pot_completion_adjudications where pot_id='${brokenSchedule}')`)},
    'review_events',${rows('lms_review_resolution_events', `case_id in (
      select id from public.lms_review_cases where pot_id='${brokenSchedule}')`)}
  )`).trim();
  const before = state();
  expectSqlError(() => asRole(db, 'authenticated', admin,
    `select public.process_pot_gameweek('${brokenSchedule}',1,true)`), /schedule integrity requires reviewed repair/i);
  assert.equal(state(), before, 'blocked manual processing must not mutate competition state');
  expectSqlError(() => rpc(db, 'run_lms_pot_automation', { selected_pot_id: brokenSchedule }),
    /schedule integrity requires reviewed repair/i);
  assert.equal(state(), before, 'blocked automation must not mutate competition state or run history');
  expectSqlError(() => asRole(db, 'authenticated', brokenMember,
    `select public.claim_buy_back('${brokenSchedule}')`), /schedule integrity requires reviewed repair/i);
  assert.equal(state(), before, 'blocked buy-back must not consume entitlement or add the member to GW3');
  expectSqlError(() => asRole(db, 'authenticated', admin,
    `select public.confirm_buy_back('${brokenSchedule}','${brokenMember}')`), /schedule integrity requires reviewed repair/i);
  expectSqlError(() => asRole(db, 'authenticated', admin,
    `select public.revoke_buy_back('${brokenSchedule}','${brokenMember}','Reviewed invalid schedule')`),
  /schedule integrity requires reviewed repair/i);
  expectSqlError(() => asRole(db, 'authenticated', admin,
    `select public.set_buy_back_decision('${brokenSchedule}','${brokenMember}',true)`),
  /schedule integrity requires reviewed repair/i);
  expectSqlError(() => asRole(db, 'authenticated', admin,
    `select public.set_buy_back_decision('${brokenSchedule}','${brokenMember}',false)`),
  /schedule integrity requires reviewed repair/i);
  assert.equal(state(), before, 'every blocked buy-back mutation must preserve entitlement and event history');
  assert.equal(db.sql(`select string_agg(gameweek_number||'→'||sequence_number,', ' order by sequence_number)
    from public.pot_rounds where pot_id='${brokenSchedule}'`).trim(), '2→1, 1→2, 3→3',
  'the gate must not rewrite legacy round history');
  console.log('PASS populated upgrade blocks processing, automation and GW1→GW3 buy-back without rewriting legacy round history.');
}

function verifyOrder(db) {
  const create = weeks => asRole(db, 'authenticated', admin, `select public.create_pot('Order test','CRITICAL-ORDER',1000,1000,array[${weeks.join(',')}],array['${admin}'::uuid])`);
  const ordered = pot => assert.equal(db.sql(`select count(*) from (select sequence_number,row_number() over(order by gameweek_number) expected from public.pot_rounds where pot_id='${pot}') r where sequence_number<>expected`).trim(), '0');
  const all = create([...Array.from({ length: 38 }, (_, n) => 38 - n), 7, 38, 1]);
  ordered(all);
  assert.equal(db.sql(`select count(*) from public.pot_rounds where pot_id='${all}'`).trim(), '38');
  const append = create([35]);
  asRole(db, 'authenticated', admin, `select public.fill_remaining_pot_gameweeks('${append}')`);
  ordered(append);
  const gap = create([36, 38]);
  expectSqlError(() => asRole(db, 'authenticated', admin, `select public.fill_remaining_pot_gameweeks('${gap}')`), /Cannot insert an earlier round/);
  assert.equal(db.sql(`select count(*) from public.pot_gameweeks where pot_id='${gap}'`).trim(), '2', 'failed backfill must roll back');
  const bulk = '00000000-0000-0000-0000-000000093101';
  db.sql(`insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,created_by) values('${bulk}','Unordered bulk','CRITICAL-ORDER',1000,1000,'${admin}');
    insert into public.pot_gameweeks(pot_id,gameweek_number) values('${bulk}',9),('${bulk}',4),('${bulk}',7);`);
  ordered(bulk);
  const missing = create([30]);
  db.sql(`delete from public.pot_rounds where pot_id='${missing}'`);
  expectSqlError(() => db.sql(`insert into public.pot_gameweeks(pot_id,gameweek_number) values('${missing}',31)`), /Existing round ordering requires a reviewed repair/);
  assert.equal(db.sql(`select count(*) from public.pot_gameweeks where pot_id='${missing}'`).trim(), '1');
  assert.equal(snapshot(db), historyBefore);
  console.log('PASS chronological create_pot (38 weeks, reversed/duplicate input), unordered bulk, append, fail-closed earlier backfill.');
  // These fixture-only pots should not participate in the scheduler tests.
  db.sql("update public.pots set status='complete',lifecycle_status='complete' where season='CRITICAL-ORDER'");
}

async function verifyScheduler(db) {
  const teams = [{ id: 93101, code: 93101, name: 'Test Home', short_name: 'TH' }, { id: 93102, code: 93102, name: 'Test Away', short_name: 'TA' }];
  const future = new Date(Date.now() + 86400_000).toISOString();
  const fixture = (id, event, finished = false) => ({ id, event, kickoff_time: future, team_h: 93101, team_a: 93102,
    team_h_score: finished ? 2 : null, team_a_score: finished ? 0 : null, started: finished,
    finished, finished_provisional: false, provisional_start_time: false });
  const season = 'CRITICAL-SCHEDULER';
  const pipeline = (fixtures, actor = null) => runSchedulerPipeline({ source: actor ? 'admin' : 'scheduler', season,
    operations: createSchedulerOperations({ async rpc(name, args) {
      try { return { data: rpc(db, name, args, 'service_role', null), error: null }; }
      catch (error) { return { data: null, error }; }
    } }, actor), fetchOptions: { retries: 0, fetchImpl: async url => ({ ok: true, json: async () => url.includes('bootstrap-static') ? { teams } : fixtures }) },
  });
  db.sql(`insert into auth.users(id,email,raw_user_meta_data) values('${member}','member@example.test','{"first_name":"Member","last_name":"Player"}'),('${other}','other@example.test','{}');
    update public.profiles set approved=true where id in('${member}','${other}');
    update public.lms_operations_config set provider_automation_enabled=true,competition_automation_enabled=true where singleton;`);
  assert.equal(asRole(db, 'service_role', null, 'select auth.uid() is null'), 't');
  // Actual provider ingestion first creates scheduled fixtures; no live network is used.
  await pipeline([fixture(93201, 37), fixture(93202, 38)]);
  const makePot = (id, week) => db.sql(`insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
    values('${id}','Service-role path','${season}',1000,1000,'active','${admin}',false,'in_progress',now());
    insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${id}',${week},now()-interval '1 minute');
    insert into public.pot_players(pot_id,player_id,player_status,payment_status,buy_back_status) values('${id}','${member}','active','paid','available');`);
  const normal = '00000000-0000-0000-0000-000000093201';
  const final = '00000000-0000-0000-0000-000000093202';
  makePot(normal, 37); makePot(final, 38);
  await pipeline([fixture(93201, 37), fixture(93202, 38)]);
  assert.equal(db.sql(`select count(*) from public.player_picks where pot_id in('${normal}','${final}') and selection_source='random'`).trim(), '2', 'scheduler must assign missing picks');
  // Whichever random team was selected, both pots have one entrant; completion rules
  // legitimately handle the losing entrant too. Finality is provided through ingestion.
  const completed = await pipeline([fixture(93201, 37, true), fixture(93202, 38, true)]);
  assert.equal(completed.status, 'succeeded');
  assert.equal(db.sql(`select count(*) from public.pot_gameweek_processes where pot_id in('${normal}','${final}') and processed_by='${system}'`).trim(), '2', 'service-role must really commit round processing');
  assert.equal(db.sql(`select count(*) from public.pot_completions where pot_id='${final}' and completed_by='${system}'`).trim(), '1', 'service-role must really commit GW38 completion');
  assert.equal(db.sql(`select count(*) from public.lms_automation_runs where pot_id in('${normal}','${final}') and actor_id is distinct from '${system}'::uuid`).trim(), '0');
  assert.equal(db.sql(`select count(*) from public.lms_provider_runs where actor_id is distinct from '${system}'::uuid`).trim(), '0');
  const count = db.sql(`select count(*) from public.pot_completions where pot_id='${final}'`).trim();
  await pipeline([fixture(93201, 37, true), fixture(93202, 38, true)]);
  assert.equal(db.sql(`select count(*) from public.pot_completions where pot_id='${final}'`).trim(), count, 'scheduler retry must not duplicate completion');

  const edgeAdminPot = '00000000-0000-0000-0000-000000093203';
  const directAdminPot = '00000000-0000-0000-0000-000000093204';
  // New fixtures avoid changing already-final provider facts.
  await pipeline([fixture(93203, 38), fixture(93201, 37, true), fixture(93202, 38, true)]);
  makePot(edgeAdminPot, 38); makePot(directAdminPot, 38);
  // Use real random-assignment/round processing with a verified admin claim. Claim
  // and completion run on separate connections, proving attribution survives pooling.
  await pipeline([fixture(93203, 38), fixture(93201, 37, true), fixture(93202, 38, true)], admin);
  await pipeline([fixture(93203, 38, true), fixture(93201, 37, true), fixture(93202, 38, true)], admin);
  assert.equal(db.sql(`select count(*) from public.pot_completions where pot_id in('${edgeAdminPot}','${directAdminPot}') and completed_by='${admin}'`).trim(), '2');
  assert.equal(db.sql(`select count(*) from public.pot_gameweek_processes where pot_id in('${edgeAdminPot}','${directAdminPot}') and processed_by='${admin}'`).trim(), '2');
  assert.equal(db.sql(`select count(*) from public.lms_automation_runs where pot_id in('${edgeAdminPot}','${directAdminPot}') and actor_id is distinct from '${admin}'::uuid`).trim(), '0');
  assert.equal(db.sql(`select count(*) from public.lms_provider_runs where source='admin' and actor_id is distinct from '${admin}'::uuid`).trim(), '0');
  // Authenticated admin RPC action, independent of the Edge Function.
  const direct = '00000000-0000-0000-0000-000000093205';
  makePot(direct, 38);
  db.sql(`insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
    select '${direct}','${member}',38,f.id,f.home_team_id,'manual','pending',38,f.home_team_id,f.away_team_id,f.kickoff_at from public.football_fixtures f where season='${season}' and fpl_fixture_id=93203;`);
  const manual = rpc(db, 'run_lms_pot_automation', { selected_pot_id: direct });
  assert.equal(manual.status, 'succeeded', JSON.stringify(manual));
  assert.equal(db.sql(`select completed_by from public.pot_completions where pot_id='${direct}'`).trim(), admin);
  assert.equal(db.sql(`select processed_by from public.pot_gameweek_processes where pot_id='${direct}'`).trim(), admin);
  assert.equal(db.sql(`select actor_id from public.lms_automation_runs where pot_id='${direct}'`).trim(), admin);
  expectSqlError(() => rpc(db, 'claim_lms_provider_run_for_admin', { run_source: 'admin', administrator_id: admin }, 'authenticated', member), /permission denied/);
  expectSqlError(() => rpc(db, 'claim_lms_provider_run_for_admin', { run_source: 'admin', administrator_id: member }, 'service_role', null), /Verified administrator required/);
  expectSqlError(() => rpc(db, 'complete_lms_provider_run_before_actors', { run_id: '00000000-0000-0000-0000-000000000002', selected_season: season, fpl_teams: teams, fpl_fixtures: [] }, 'service_role', null), /permission denied/);
  assert.equal(db.sql("select count(*) from information_schema.columns where table_schema='public' and ((table_name='pot_completions' and column_name='completed_by') or (table_name='pot_gameweek_processes' and column_name='processed_by')) and is_nullable='NO'").trim(), '2');
  assert.equal(db.sql(`select count(*) from auth.users where id='${system}'`).trim(), '0');
  console.log('PASS actual scheduler → service-role claim → ingestion/scan → random assignment → normal round/GW38 completion; idempotency, durable system/admin attribution, authenticated admin path and impersonation denial.');

  // Reproduce the former cycle with real entry points. Manual processing holds the
  // schedule lock while a disposable-only release flag pauses it before fixture
  // locking. PostgreSQL must then report provider completion waiting for that exact
  // lock before the flag is released; elapsed time alone is not accepted as overlap.
  const lockOrderPot = '00000000-0000-0000-0000-000000093206';
  await pipeline([fixture(93204, 36)]);
  makePot(lockOrderPot, 36);
  db.sql(`insert into public.player_picks(
      pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
      selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at
    )
    select '${lockOrderPot}','${member}',36,f.id,f.home_team_id,'manual','pending',
      36,f.home_team_id,f.away_team_id,f.kickoff_at
    from public.football_fixtures f
    where f.season='${season}' and f.fpl_fixture_id=93204;`);
  const providerClaim = rpc(db, 'claim_lms_provider_run', { run_source: 'local_simulation' }, 'service_role', null);
  assert.equal(providerClaim.acquired, true, JSON.stringify(providerClaim));
  db.sql(`create table public.lms_test_lock_release(released boolean not null);
    insert into public.lms_test_lock_release values(false);
    grant select on public.lms_test_lock_release to authenticated;`);
  const scheduleLock = `(select (hashtext('${lockOrderPot}')::bigint & 4294967295))`;
  const scheduleLockPart = `(-2::bigint & 4294967295)`;
  const lockState = (applicationName, granted) => `select exists(
    select 1 from pg_catalog.pg_locks lock
    join pg_catalog.pg_stat_activity activity on activity.pid=lock.pid
    where activity.application_name='${applicationName}' and lock.locktype='advisory'
      and lock.classid::bigint=${scheduleLock} and lock.objid::bigint=${scheduleLockPart}
      and lock.objsubid=2 and lock.mode='ExclusiveLock' and lock.granted=${granted})`;
  const manualLockPath = `begin;
    ${claims('authenticated', admin)}
    set local application_name='lms_lock_order_manual';
    set local statement_timeout='8s';
    select pg_advisory_xact_lock(hashtext('${lockOrderPot}'),-2);
    do $wait$ begin
      while not (select released from public.lms_test_lock_release) loop
        if clock_timestamp() > statement_timestamp()+interval '7 seconds' then
          raise exception 'Timed out waiting for lock-order test release';
        end if;
        perform pg_sleep(0.02);
      end loop;
    end $wait$;
    select public.process_pot_gameweek('${lockOrderPot}',36,false);
    commit;`;
  const providerLockPath = `begin;
    ${claims('service_role', null)}
    set local application_name='lms_lock_order_provider';
    set local statement_timeout='8s';
    select public.complete_lms_provider_run(
      '${providerClaim.run_id}','${season}',
      ${q(teams)}::jsonb,${q([fixture(93204, 36, true)])}::jsonb
    );
    commit;`;
  const settle = promise => promise.then(
    value => ({ status: 'fulfilled', value }),
    reason => ({ status: 'rejected', reason }),
  );
  const manualLockResult = settle(db.sqlAsync(manualLockPath));
  await waitForSql(db, 'manual processing to own the schedule lock',
    lockState('lms_lock_order_manual', true));
  const providerLockResult = settle(db.sqlAsync(providerLockPath));
  await waitForSql(db, 'provider completion to wait for the manual schedule lock',
    lockState('lms_lock_order_provider', false));
  db.sql('update public.lms_test_lock_release set released=true');
  const lockOrderResults = await Promise.all([manualLockResult, providerLockResult]);
  for (const result of lockOrderResults) {
    assert.equal(result.status, 'fulfilled', result.reason?.stderr?.toString() || result.reason?.message);
  }
  assert.equal(db.sql(`select status from public.lms_provider_runs where id='${providerClaim.run_id}'`).trim(), 'succeeded');
  assert.equal(db.sql(`select count(*) from public.pot_gameweek_processes where pot_id='${lockOrderPot}'`).trim(), '1');
  assert.equal(db.sql(`select count(*) from public.player_picks where pot_id='${lockOrderPot}' and outcome='pending'`).trim(), '0');
  assert.equal(db.sql(`select count(*) from public.lms_automation_runs where pot_id='${lockOrderPot}' and status='running'`).trim(), '0');
  db.sql('drop table public.lms_test_lock_release');
  console.log('PASS PostgreSQL observed manual schedule-lock ownership and provider waiting; both real sessions completed once without deadlock or partial mutation.');
  return direct;
}

function verifyPrivacy(db, pot) {
  // Case creation is an internal fixture operation; all resolution/access checks below
  // execute as the actual authenticated role, not the database owner.
  const caseId = asRole(db, 'postgres', admin, `select public.open_lms_review_case('${pot}','completed_pot_correction','PRIVATE internal case summary',null,null,null,'${member}','{"secret":"PRIVATE evidence"}','admin')`);
  const preview = rpc(db, 'preview_lms_review_resolution', { selected_case_id: caseId, selected_action: 'revise_winners', selected_player_ids: `{${member}}` });
  rpc(db, 'resolve_lms_review_case', { selected_case_id: caseId, selected_action: 'revise_winners', resolution_reason: 'PRIVATE decision justification', expected_version_token: preview.version_token, selected_player_ids: `{${member}}` });
  asRole(db, 'postgres', admin, `select public.open_lms_review_case('${pot}','late_buyback_revocation','PRIVATE second open summary',null,null,null,'${member}','{"secret":"PRIVATE open evidence"}','admin')`);
  const tables = ['lms_review_cases', 'lms_review_resolution_events', 'pot_completion_adjudications', 'pot_adjudicated_winners'];
  for (const table of tables) {
    for (const user of [member, other]) assert.equal(asRole(db, 'authenticated', user, `select count(*) from public.${table}`), '0', `${user} must not read ${table}`);
    assert.ok(Number(asRole(db, 'authenticated', admin, `select count(*) from public.${table}`)) > 0, `admin must read ${table}`);
  }
  assert.equal(asRole(db, 'authenticated', member, `select count(*) from public.pots where id='${pot}'`), '0', 'copied private review_reason must not leak through pots');
  const state = rpc(db, 'get_my_pot_review_state', { selected_pot_id: pot }, 'authenticated', member);
  assert.deepEqual(Object.keys(state).sort(), ['cases', 'dismissed_count', 'open_count', 'resolved_count', 'under_review']);
  assert.deepEqual(state, { cases: [], dismissed_count: 0, open_count: 1, resolved_count: 1, under_review: true });
  const outcome = rpc(db, 'get_my_pot_review_outcome', { selected_pot_id: pot }, 'authenticated', member);
  assert.deepEqual(Object.keys(outcome).sort(), ['decided_at', 'revision', 'total_prize_pence', 'winners']);
  assert.deepEqual(outcome.winners, [{ name: 'Member Player', is_me: true, prize_share_pence: 1000 }]);
  assert.equal(outcome.revision, 1); assert.equal(outcome.total_prize_pence, 1000);
  for (const name of ['get_my_pot_review_state', 'get_my_pot_review_outcome']) {
    assert.equal(rpc(db, name, { selected_pot_id: pot }, 'authenticated', other), null);
    expectSqlError(() => rpc(db, name, { selected_pot_id: pot }, 'anon', null), /permission denied/);
  }
  const dashboard = rpc(db, 'get_my_dashboard', {}, 'authenticated', member);
  assert.ok(dashboard.pots.some(p => p.id === pot), 'legitimate dashboard visibility must survive direct-table restriction');
  assert.ok(!JSON.stringify({ state, outcome, dashboard }).includes('PRIVATE'));
  assert.ok(JSON.stringify(rpc(db, 'get_my_pot_review_state', { selected_pot_id: pot })).includes('PRIVATE evidence'));
  console.log('PASS real authenticated-role member/unrelated/admin RLS, alternate pots leak closure, exact member status/outcome field allowlists, anonymous denial, preserved dashboard visibility.');
}

export async function verifyCriticalFindings(db) {
  verifyHistoricalScheduleGate(db);
  verifyOrder(db);
  const pot = await verifyScheduler(db);
  verifyPrivacy(db, pot);
}
