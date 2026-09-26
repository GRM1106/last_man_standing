import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { runSchedulerPipeline } from '../server/scheduler-pipeline.js';
import { createSchedulerOperations } from '../server/scheduler-operations.js';

const admin = '00000000-0000-0000-0000-000000003001';
const players = ['00000000-0000-0000-0000-000000093001', '00000000-0000-0000-0000-000000093002'];
const system = '00000000-0000-0000-0000-000000000001';
const q = value => `'${(typeof value === 'object' ? JSON.stringify(value) : String(value)).replaceAll("'", "''")}'`;
const teams = [1, 2, 3, 4].map(id => ({ id, code: id, name: `Finality ${id}`, short_name: `F${id}` }));
const season = 'PROVIDER-FINALITY';

export async function verifyProviderFinality(db) {
  const rpc = (name, args, service = true) => JSON.parse(db.sql(`begin;
    set local role ${service ? 'service_role' : 'authenticated'};
    set local "request.jwt.claims"=${q(service ? { role: 'service_role' } : { role: 'authenticated', sub: admin })};
    select public.${name}(${Object.entries(args).map(([key, value]) => `${key} => ${q(value)}`).join(',')}); commit;`).trim());
  const pipeline = fixtures => runSchedulerPipeline({ source: 'scheduler', season,
    operations: createSchedulerOperations({ async rpc(name, args) {
      try { return { data: rpc(name, args), error: null }; } catch (error) { return { data: null, error }; }
    } }),
    fetchOptions: { retries: 0, fetchImpl: async url => ({ ok: true, json: async () => url.includes('bootstrap-static')
      ? { teams, events: [{ id: 37, finished: true, data_checked: true }, { id: 38, finished: true, data_checked: true }] } : fixtures }) }
  });
  const fixture = (id, event, second = false) => ({ id, event, kickoff_time: new Date(Date.now() + 86400_000).toISOString(),
    team_h: second ? 3 : 1, team_a: second ? 4 : 2, team_h_score: second ? 0 : 2, team_a_score: second ? 2 : 0,
    started: true, finished: true, finished_provisional: true, provisional_start_time: false });
  let cases = 0;
  for (const gw of [37, 38]) {
    const pot = randomUUID();
    const final = fixture(gw * 10, gw);
    const uncertain = fixture(gw * 10 + 1, gw, true);
    const directIngest = fixtures => rpc('sync_fpl_data', { selected_season: season, fpl_teams: teams, fpl_fixtures: fixtures }, false);
    directIngest([final, { ...uncertain, finished: false }]);
    db.sql(`insert into public.pots(id,name,season,entry_fee_pence,buy_back_fee_pence,status,created_by,test_mode,lifecycle_status,membership_locked_at)
      values('${pot}','Mixed provider evidence','${season}',1000,1000,'active','${admin}',false,'in_progress',now());
      insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${pot}',${gw},now()-interval '1 minute');
      ${gw < 38 ? `insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${pot}',38,now()+interval '2 days');` : ''}
      insert into public.pot_players(pot_id,player_id,player_status,payment_status)
        values('${pot}','${players[0]}','active','paid'),('${pot}','${players[1]}','active','paid');
      insert into public.player_picks(pot_id,player_id,gameweek_number,fixture_id,team_id,selection_source,outcome,
        selected_fixture_gameweek,selected_home_team_id,selected_away_team_id,selected_kickoff_at)
      select '${pot}',case when fpl_fixture_id=${final.id} then '${players[0]}'::uuid else '${players[1]}'::uuid end,
        ${gw},id,home_team_id,'manual','pending',${gw},home_team_id,away_team_id,kickoff_at
      from public.football_fixtures where season='${season}' and fpl_fixture_id in(${final.id},${uncertain.id});`);
    const snapshot = () => db.sql(`select jsonb_build_object(
      'pot',(select to_jsonb(p) from public.pots p where id='${pot}'),
      'players',(select jsonb_agg(to_jsonb(p) order by player_id) from public.pot_players p where pot_id='${pot}'),
      'picks',(select jsonb_agg(to_jsonb(p) order by id) from public.player_picks p where pot_id='${pot}'),
      'rounds',(select jsonb_agg(to_jsonb(p) order by id) from public.pot_rounds p where pot_id='${pot}'),
      'processes',(select jsonb_agg(to_jsonb(p)) from public.pot_gameweek_processes p where pot_id='${pot}'),
      'completion',(select to_jsonb(p) from public.pot_completions p where pot_id='${pot}'),
      'winners',(select jsonb_agg(to_jsonb(p)) from public.pot_winners p where pot_id='${pot}'))`).trim();
    // Lock timestamps/schedule metadata before comparing competition snapshots.
    await pipeline([final, { ...uncertain, finished: false }]);
    const before = snapshot();
    for (const field of ['finished', 'finished_provisional']) {
      for (const value of [undefined, null, false, 'true', 'false', 'yes', 1, 0, {}, []]) {
        const input = { ...uncertain, [field]: value };
        if (value === undefined) delete input[field];
        // Direct authorised RPC must fail closed even if JavaScript is bypassed.
        directIngest([final, input]);
        assert.equal(db.sql(`select processable from public.get_effective_fixture_result(
          (select id from public.football_fixtures where season='${season}' and fpl_fixture_id=${uncertain.id}))`).trim(), 'f');
        const preview = rpc('process_pot_gameweek', { selected_pot_id: pot, selected_gameweek: gw, apply_changes: false }, false);
        assert.equal(preview.ready, false, `${gw}/${field}/${JSON.stringify(value)}`);
        assert.equal(preview.losers, 0);
        assert.throws(() => rpc('process_pot_gameweek', { selected_pot_id: pot, selected_gameweek: gw, apply_changes: true }, false),
          error => /pick result.s. are not available yet/.test(error.stderr?.toString() || ''));
        if (value === undefined || value === null || value === false) {
          await pipeline([final, input]);
        } else {
          await assert.rejects(pipeline([final, input]), /Provider fixture shape is invalid/);
        }
        assert.equal(snapshot(), before, 'uncertain evidence must preserve picks, membership, round and completion history');
        cases++;
      }
    }
    // Replacing known final evidence with unknown must also revoke eligibility.
    directIngest([final, uncertain]);
    assert.equal(rpc('process_pot_gameweek', { selected_pot_id: pot, selected_gameweek: gw, apply_changes: false }, false).ready, true);
    const missing = { ...uncertain }; delete missing.finished_provisional;
    await pipeline([final, missing]);
    assert.equal(snapshot(), before);
    await pipeline([final, uncertain]);
    assert.equal(db.sql(`select count(*) from public.pot_gameweek_processes where pot_id='${pot}' and processed_by='${system}'`).trim(), '1');
    assert.equal(db.sql(`select outcome from public.player_picks where pot_id='${pot}' and player_id='${players[0]}'`).trim(), 'won');
    assert.equal(db.sql(`select outcome from public.player_picks where pot_id='${pot}' and player_id='${players[1]}'`).trim(), 'lost');
    if (gw === 38) assert.equal(db.sql(`select count(*) from public.pot_completions where pot_id='${pot}' and completed_by='${system}'`).trim(), '1');
    const after = snapshot();
    await pipeline([final, uncertain]);
    assert.equal(snapshot(), after, 'explicit-final retry must be idempotent');
    db.sql(`update public.pots set status='complete',lifecycle_status='complete' where id='${pot}'`);
  }
  console.log(`PASS provider finality: ${cases} uncertain-evidence cases via direct RPC and real scheduler; mixed normal/GW38 cohorts, final→unknown revocation, explicit-final retries, outcomes, attribution and idempotency.`);
}
