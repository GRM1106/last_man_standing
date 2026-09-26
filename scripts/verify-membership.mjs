// Observe lock contention between actual PostgreSQL sessions, then verify committed state.
export async function verifyMembershipRaces(db) {
  const admin='00000000-0000-0000-0000-000000029001', player='00000000-0000-0000-0000-000000029002';
  const pot='00000000-0000-0000-0000-000000029011';
  const identity=id=>`set local role authenticated; set local "request.jwt.claim.role"='authenticated'; set local "request.jwt.claim.sub"='${id}';`;
  db.sql(`insert into auth.users(id,email) values('${admin}','race-admin@example.test'),('${player}','race-player@example.test');
    update public.profiles set is_admin=true where id='${admin}';
    insert into public.pots(id,name,season,status,lifecycle_status,created_by,entry_fee_pence,buy_back_fee_pence,is_discoverable)
    values('${pot}','Membership race','MEMBERSHIP-RACE','open','open','${admin}',1000,500,true);
    insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${pot}',1,now()+interval '1 day');`);
  async function waitFor(name,condition){for(let n=0;n<80;n++){if(db.sql(`select exists(select 1 from pg_stat_activity where application_name='${name}' and ${condition})`).trim()==='t')return;await new Promise(r=>setTimeout(r,50));}throw new Error(`Did not observe ${name}: ${condition}`);}
  async function race(name,first,second){
    const writer=db.sqlAsync(`set application_name='membership_${name}_writer';begin;${first} select pg_sleep(4);commit;`);
    let reader;
    try{await waitFor(`membership_${name}_writer`,"wait_event='PgSleep'");reader=db.sqlAsync(`set application_name='membership_${name}_reader';begin;${second}commit;`);await waitFor(`membership_${name}_reader`,"wait_event_type='Lock'");}
    finally{for(const result of await Promise.allSettled([writer,...(reader?[reader]:[])]))if(result.status==='rejected')throw result.reason;}
  }
  function assert(sql,label){if(db.sql(`select (${sql})`).trim()!=='t')throw new Error(label);}
  const request=`${identity(player)}select public.request_pot_membership('${pot}');`;
  await race('duplicate_request',request,request);
  assert(`(select count(*)=1 and min(version)=1 from public.pot_join_requests where pot_id='${pot}') and (select count(*)=1 from public.pot_membership_events where pot_id='${pot}' and action='requested')`,'Duplicate requests wrote multiple states/events');
  const accept=`${identity(admin)}select public.decide_pot_membership('${pot}','${player}',1,true);`;
  await race('double_accept',accept,accept);
  assert(`(select count(*)=1 from public.pot_players where pot_id='${pot}' and player_id='${player}') and (select status='accepted' and version=2 from public.pot_join_requests where pot_id='${pot}' and player_id='${player}') and (select count(*)=1 from public.pot_membership_events where pot_id='${pot}' and action='accepted')`,'Double acceptance duplicated membership/audit');
  // A separate request remains pending when discovery closes ahead of acceptance.
  db.sql(`begin;${identity(admin)}select public.request_pot_membership('${pot}');commit;`);
  await race('close_before_accept',`${identity(admin)}select public.set_pot_discoverable('${pot}',false);`,`${identity(admin)}do $$ declare denied boolean:=false;begin begin perform public.decide_pot_membership('${pot}','${admin}',1,true);exception when raise_exception then if sqlerrm='This pot is no longer available for joining' then denied:=true;else raise;end if;end;if not denied then raise exception 'Accepted unavailable pot';end if;end $$;`);
  assert(`not exists(select 1 from public.pot_players where pot_id='${pot}' and player_id='${admin}') and (select status='pending' and version=1 from public.pot_join_requests where pot_id='${pot}' and player_id='${admin}')`,'Unavailable race partially mutated membership');
  await race('deadline_before_assignment',`select pg_advisory_xact_lock(hashtext('${pot}'),-2); update public.pot_gameweeks set pick_deadline_at=clock_timestamp()+interval '2 seconds' where pot_id='${pot}';`,`${identity(admin)}do $$ declare denied boolean:=false;begin begin perform public.add_player_to_pot('${pot}','${admin}');exception when raise_exception then if sqlerrm='Membership is locked for this pot' then denied:=true;else raise;end if;end;if not denied then raise exception 'Assigned after deadline during lock wait';end if;if now()>=(select pick_deadline_at from public.pot_gameweeks where pot_id='${pot}' limit 1) then raise exception 'Race did not begin before the deadline';end if;end $$;`);
  assert(`not exists(select 1 from public.pot_players where pot_id='${pot}' and player_id='${admin}')`,'Deadline race created late membership');
  console.log('PASS pot membership: 4 observed two-session races (duplicate request, double acceptance, availability closure, assignment deadline).');
}
