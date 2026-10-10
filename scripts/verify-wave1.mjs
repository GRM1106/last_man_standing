import assert from 'node:assert/strict';

// Called only with the ownership-verified DisposableDatabase from test-db.mjs.
export function verifyWave1(db) {
  const admin='00000000-0000-0000-0000-000000049001', member='00000000-0000-0000-0000-000000049002';
  const other='00000000-0000-0000-0000-000000049003', unrelated='00000000-0000-0000-0000-000000049004';
  const pot='00000000-0000-0000-0000-000000049011', completed='00000000-0000-0000-0000-000000049012';
  const identity=id=>`set local role authenticated;set local "request.jwt.claim.role"='authenticated';set local "request.jwt.claim.sub"='${id}';`;
  const run=(id,sql)=>db.sql(`begin;${identity(id)}${sql}commit;`).trim();
  let checks=0;
  const check=(ok,label)=>{assert.ok(ok,label);checks++;};
  db.sql(`insert into auth.users(id,email) values('${admin}','wave1-admin@example.test'),('${member}','wave1-member@example.test'),('${other}','wave1-other@example.test'),('${unrelated}','wave1-unrelated@example.test');
    update public.profiles set is_admin=true where id='${admin}';
    insert into public.football_teams(id,season,fpl_team_id,code,name,short_name) values(-949001,'WAVE1',-949001,949001,'Home','HOM'),(-949002,'WAVE1',-949002,949002,'Away','AWY');
    insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at) values(-949001,-949001,'WAVE1',1,now()+interval '2 days',-949001,-949002,'scheduled',now());
    insert into public.pots(id,name,season,status,lifecycle_status,created_by,entry_fee_pence,buy_back_fee_pence) values('${pot}','Wave1 deadline','WAVE1','open','open','${admin}',1000,500);
    insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${pot}',1,now()+interval '1 day');
    insert into public.pot_players(pot_id,player_id) values('${pot}','${member}'),('${pot}','${other}');`);
  run(member,`select public.confirm_team_pick('${pot}',-949001,-949001);`);
  const visibility=(label,deadline,kickoff,expected,{zone='UTC',status='scheduled',viewer=other,selectClosed=false}={})=>{
    const sql=`begin;set local timezone='${zone}';
      update public.pot_gameweeks set pick_deadline_at=${deadline} where pot_id='${pot}';
      update public.football_fixtures set kickoff_at=${kickoff},status='${status}' where id=-949001;
      ${identity(viewer)}select jsonb_build_object('standings',public.get_pot_standings('${pot}'),'deadline',public.get_gameweek_deadline('${pot}',1));commit;`;
    const result=JSON.parse(db.sql(sql));
    check(result.standings.players.find(p=>p.id===member).picks.length===expected,label);
    check(result.standings.players.every(p=>p.email===null&&p.payment_status===null&&p.buy_back_status===null)||viewer===admin,`${label}: member privacy`);
    if(selectClosed)check(result.deadline.deadline_passed===true&&result.deadline.permanently_closed===true,`${label}: selection stays closed`);
  };
  visibility('before deadline despite early provider kickoff',"now()+interval '1 microsecond'","now()-interval '1 day'",0);
  visibility('exact deadline despite future kickoff','now()',"now()+interval '2 days'",1,{selectClosed:true});
  visibility('after deadline',"now()-interval '1 microsecond'","now()+interval '2 days'",1,{selectClosed:true});
  visibility('before reschedule',"now()-interval '1 hour'","now()-interval '1 hour'",1);
  visibility('forward reschedule remains revealed',"now()-interval '1 hour'","now()+interval '2 days'",1,{selectClosed:true});
  visibility('postponed fixture remains revealed',"now()-interval '1 hour'","now()+interval '2 days'",1,{status:'postponed',selectClosed:true});
  visibility('unknown kickoff still uses deadline',"now()-interval '1 hour'",'null',1,{selectClosed:true});
  for(const zone of ['UTC','Europe/London','Pacific/Auckland']) {
    visibility(`${zone}: before`,"now()+interval '1 microsecond'","now()-interval '1 day'",0,{zone});
    visibility(`${zone}: at`,'now()',"now()+interval '2 days'",1,{zone,selectClosed:true});
    visibility(`${zone}: after`,"now()-interval '1 microsecond'","now()+interval '2 days'",1,{zone,selectClosed:true});
  }
  // Shift explicit-offset DST instants onto the transaction's frozen now().
  // Comparisons never depend on when CI runs or on a JavaScript fake clock.
  for(const [label,deadline,observed,expected] of [
    ['spring before','2026-03-29T02:00:00+01','2026-03-29T00:59:59+00',0],
    ['spring at','2026-03-29T02:00:00+01','2026-03-29T01:00:00+00',1],
    ['spring after','2026-03-29T02:00:00+01','2026-03-29T02:00:01+01',1],
    ['autumn repeated hour before','2026-10-25T01:30:00+00','2026-10-25T01:30:00+01',0],
    ['autumn at','2026-10-25T01:30:00+00','2026-10-25T01:30:00+00',1],
    ['autumn after','2026-10-25T01:30:00+00','2026-10-25T01:30:01+00',1],
  ]) visibility(label,`now()+('${deadline}'::timestamptz-'${observed}'::timestamptz)`,"now()+interval '2 days'",expected,{zone:'Europe/London'});
  for (const [label, observed, expected] of [
    ['UTC midnight minus one second', '2026-10-10T23:59:59Z', 0],
    ['UTC midnight exact', '2026-10-11T00:00:00Z', 1],
    ['UTC midnight plus one second', '2026-10-11T00:00:01Z', 1],
  ]) visibility(label, `now()+('2026-10-11T00:00:00Z'::timestamptz-'${observed}'::timestamptz)`,
    "now()+interval '2 days'", expected, { zone: 'UTC', selectClosed: expected === 1 });
  visibility('missing deadline hides unprocessed member picks','null',"now()-interval '1 day'",0);
  visibility('admin may see unprocessed picks','null',"now()+interval '2 days'",1,{viewer:admin});
  db.sql(`insert into public.pot_gameweek_processes(pot_id,gameweek_number,test_run,summary,processed_by) values('${pot}',1,false,'{}','${admin}');`);
  visibility('processed round remains visible without deadline','null','null',1);
  assert.throws(()=>run(unrelated,`select public.get_pot_standings('${pot}');`),e=>String(e.stderr).includes('not assigned'));checks++;
  assert.throws(()=>db.sql(`begin;set local role anon;select public.get_pot_standings('${pot}');rollback;`),e=>String(e.stderr).includes('permission denied'));checks++;

  db.sql(`insert into public.pots(id,name,season,status,lifecycle_status,created_by,entry_fee_pence,buy_back_fee_pence) values('${completed}','Wave1 completion','WAVE1-DONE','complete','complete','${admin}',1000,500);
    insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${completed}',38,now()-interval '1 day');
    insert into public.pot_players(pot_id,player_id,player_status,payment_status) values('${completed}','${member}','winner','paid'),('${completed}','${other}','eliminated','paid');
    insert into public.pot_completions(pot_id,round_id,gameweek_number,resolution_rule,entry_contribution_pence,buyback_contribution_pence,total_prize_pence,winner_count,completed_by) select '${completed}',id,38,'gw38_survivors',2000,0,2000,1,'${admin}' from public.pot_rounds where pot_id='${completed}';
    insert into public.pot_winners(pot_id,player_id,round_id,winner_reason,prize_share_pence,share_order) select '${completed}','${member}',id,'gw38_survivor',2000,1 from public.pot_rounds where pot_id='${completed}';`);
  const original=run(member,`select public.get_pot_completion('${completed}');`);
  check(run(member,`select public.get_my_pot_review_outcome('${completed}') is null;`)==='t','no revision initially');
  for(const [revision,winner] of [[1,other],[2,member]]) {
    // The internal case opener is operator-only setup; preview/resolution are
    // genuinely authorised admin calls, and result reads use member privileges.
    const caseId=db.sql(`begin;set local "request.jwt.claim.sub"='${admin}';select public.open_lms_review_case('${completed}','completed_pot_correction','Synthetic Wave1 revision evidence',null,null,null,null,'{}','admin');commit;`).trim();
    const preview=JSON.parse(run(admin,`select public.preview_lms_review_resolution('${caseId}','revise_winners',array['${winner}'::uuid]);`));
    run(admin,`select public.resolve_lms_review_case('${caseId}','revise_winners','Synthetic adjudication verification only','${preview.version_token}',array['${winner}'::uuid]);`);
    const result=JSON.parse(run(member,`select public.get_my_pot_review_outcome('${completed}');`));
    check(result.revision===revision&&result.winners.length===1&&result.winners[0].is_me===(winner===member),'latest revised winner');
    check(Object.keys(result).sort().join(',')==='decided_at,revision,total_prize_pence,winners','safe outcome top-level allowlist');
    check(Object.keys(result.winners[0]).sort().join(',')==='is_me,name,prize_share_pence','safe winner allowlist');
    check(run(member,`select public.get_pot_completion('${completed}');`)===original,'original winner/prize history preserved');
    check(run(member,`select count(*) from public.lms_review_cases where pot_id='${completed}';`)==='0','private review evidence denied by RLS');
  }
  check(run(unrelated,`select public.get_my_pot_review_outcome('${completed}') is null;`)==='t','unrelated player sees no outcome');
  assert.throws(()=>db.sql(`begin;set local role anon;select public.get_my_pot_review_outcome('${completed}');rollback;`),e=>String(e.stderr).includes('permission denied'));checks++;
  console.log(`PASS Wave1: ${checks} real-role deadline/DST/privacy/adjudication assertions; repeated corrections preserve original results.`);
}
