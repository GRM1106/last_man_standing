// Real corrections in separate transactions must invalidate open review previews.
export async function verifyReviewFreshness(db) {
  const admin=db.sql('select id from public.profiles where is_admin order by id limit 1').trim();
  const identity=`set local role authenticated;set local "request.jwt.claim.role"='authenticated';set local "request.jwt.claim.sub"='${admin}';`;
  const run=sql=>db.sql(`begin;${identity}${sql}commit;`).trim();
  db.sql(`insert into public.football_teams(id,season,fpl_team_id,code,name,short_name,updated_at) values(-30101,'REVIEW-FRESH',-30101,-30101,'Review Home','RFH',now()),(-30102,'REVIEW-FRESH',-30102,-30102,'Review Away','RFA',now());
    insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,started,finished,finished_provisional,provisional_start_time,status,provider_synced_at,updated_at)
    values(-30201,-30201,'REVIEW-FRESH',38,now()+interval '1 day',-30101,-30102,false,false,false,false,'scheduled',now(),now());`);
  const pot=run(`select public.create_pot('Review freshness','REVIEW-FRESH',1000,500,array[38],array['${admin}'::uuid]);`);
  run(`select public.set_pot_status('${pot}','open');select public.confirm_team_pick('${pot}',-30201,-30101);`);
  db.sql(`update public.pot_gameweeks set pick_deadline_at=now()-interval '1 hour' where pot_id='${pot}';update public.football_fixtures set home_score=2,away_score=0,started=true,finished=true,finished_provisional=true,status='finished' where id=-30201;`);
  run(`select public.process_pot_gameweek('${pot}',38,true);`);
  const history=()=>db.sql(`select jsonb_build_object('picks',(select jsonb_agg(to_jsonb(p)) from public.player_picks p where pot_id='${pot}'),'completion',(select to_jsonb(c) from public.pot_completions c where pot_id='${pot}'),'winners',(select jsonb_agg(to_jsonb(w)) from public.pot_winners w where pot_id='${pot}'));`).trim();
  const original=history();
  const correct=score=>`select public.create_fixture_result_override(-30201,${score},0,'finished','Controlled score correction retains winner',public.preview_fixture_result_override(-30201,${score},0,'finished','Controlled score correction retains winner')->>'effective_version');`;
  run(correct(3));
  const caseId=db.sql(`select id from public.lms_review_cases where pot_id='${pot}' and status='open'`).trim();
  const preview=()=>JSON.parse(run(`select public.preview_lms_review_resolution('${caseId}','confirm_existing',null);`));
  let checks=0;
  const assert=(ok,label)=>{if(!ok)throw new Error(label);checks++;};
  const token=preview().version_token;
  const state=()=>db.sql(`select jsonb_build_object('pot',(select to_jsonb(p) from public.pots p where id='${pot}'),'case',(select to_jsonb(c) from public.lms_review_cases c where id='${caseId}'),'events',(select jsonb_agg(to_jsonb(e)) from public.lms_review_resolution_events e where case_id='${caseId}'),'adjudications',(select jsonb_agg(to_jsonb(a)) from public.pot_completion_adjudications a where case_id='${caseId}'));`).trim()+history();
  const call=argument=>`perform public.resolve_lms_review_case('${caseId}','confirm_existing','The recorded winners and outcomes remain valid',${argument},null);`;
  const deny=(statement,message,prefix=identity,code='P0001')=>{
    const before=state();
    db.sql(`begin;${prefix}do $$ declare denied boolean:=false;begin begin ${statement} exception when sqlstate '${code}' then if ${message ? `sqlerrm='${message}'` : 'true'} then denied:=true;else raise;end if;end;if not denied then raise exception 'Invalid review resolution was accepted';end if;end $$;commit;`);
    assert(state()===before,'Rejected resolution changed review, audit or sporting history');
  };
  for(const argument of ['null',"''","'   '","'malformed'",`'${'A'.repeat(32)}'`])
    deny(call(argument),'A valid review preview token is required');
  deny(call(`'${'0'.repeat(32)}'`),'Review state changed; preview again.');
  // A required SQL/RPC argument has no default: omission must not resolve an overload.
  deny(`perform public.resolve_lms_review_case(selected_case_id=>'${caseId}'::uuid,selected_action=>'confirm_existing'::text,resolution_reason=>'The recorded winners and outcomes remain valid'::text);`,null,identity,'42883');
  const player=db.sql('select id from public.profiles where not is_admin order by id limit 1').trim();
  assert(Boolean(player),'Non-administrator fixture is required');
  for(const argument of ['null',`'${token}'`]) {
    deny(call(argument),'Administrator access required',`set local role authenticated;set local "request.jwt.claim.role"='authenticated';set local "request.jwt.claim.sub"='${player}';`);
    deny(call(argument),null,`set local role anon;set local "request.jwt.claim.role"='anon';set local "request.jwt.claim.sub"='';`,'42501');
  }
  assert(db.sql("select pronargdefaults from pg_proc where oid='public.resolve_lms_review_case(uuid,text,text,text,uuid[])'::regprocedure").trim()==='1','Required token acquired a default');
  const resolve=version=>`select public.resolve_lms_review_case('${caseId}','confirm_existing','The recorded winners and outcomes remain valid','${version}',null);`;
  async function waitFor(name,condition){for(let n=0;n<80;n++){if(db.sql(`select exists(select 1 from pg_stat_activity where application_name='${name}' and ${condition})`).trim()==='t')return;await new Promise(r=>setTimeout(r,50));}throw new Error(`Did not observe ${name}: ${condition}`);}
  async function rejectAfterRace(name,statement,prefix=identity){
    const staleToken=preview().version_token;
    const writer=db.sqlAsync(`set application_name='review_${name}_writer';begin;${prefix}${statement}select pg_sleep(4);commit;`);
    let reader;
    try{
      await waitFor(`review_${name}_writer`,"wait_event='PgSleep'");
      reader=db.sqlAsync(`set application_name='review_${name}_reader';begin;${identity}do $$ declare denied boolean:=false;begin begin perform public.resolve_lms_review_case('${caseId}','confirm_existing','The recorded winners and outcomes remain valid','${staleToken}',null);exception when raise_exception then if sqlerrm='Review state changed; preview again.' then denied:=true;else raise;end if;end;if not denied then raise exception 'Stale review was resolved';end if;end $$;commit;`);
      await waitFor(`review_${name}_reader`,"wait_event_type='Lock'");
    }finally{for(const result of await Promise.allSettled([writer,...(reader?[reader]:[])]))if(result.status==='rejected')throw result.reason;}
  }
  await rejectAfterRace('correction',correct(4));
  // Provider/internal case updates also lock pot before case, matching resolution.
  await rejectAfterRace('case_update',`select public.open_lms_review_case('${pot}','completed_pot_correction','Further evidence for the existing review',null,null,null,null,'{}','system');`,'');
  assert(preview().version_token!==token,'Correction did not invalidate token');
  assert(db.sql(`select count(*) from public.lms_review_resolution_events where case_id='${caseId}'`).trim()==='0','Stale action wrote audit');
  assert(db.sql(`select status from public.lms_review_cases where id='${caseId}'`).trim()==='open','Stale action closed review');
  assert(history()===original,'Correction rewrote historical outcomes');
  const fresh=preview().version_token;
  assert(JSON.parse(run(resolve(fresh))).resolved===true,'Fresh-token resolution failed');
  assert(JSON.parse(run(resolve(fresh))).already_resolved===true,'Valid retry was not idempotent');
  deny(call('null'),'A valid review preview token is required');
  assert(history()===original,'Resolution changed historical outcomes');
  assert(db.sql(`select count(*) from public.lms_review_resolution_events where case_id='${caseId}' and actor_id='${admin}' and action='confirm_existing'`).trim()==='1','Resolution retry duplicated or misattributed audit');
  assert(db.sql(`select status='complete' and lifecycle_status='complete' and review_status='reviewed' from public.pots where id='${pot}'`).trim()==='t','Completion did not resume');
  console.log(`PASS review freshness: ${checks} assertions and 2 observed correction/case-update resolution races; required/NULL/malformed/incorrect tokens, independent authorisation, fresh preview, retry and historical results preserved.`);
}
