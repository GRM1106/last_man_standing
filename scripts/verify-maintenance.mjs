// Real PostgreSQL roles, transaction barriers and whole-table guard coverage.
export async function verifyMaintenance(db) {
  const admin='00000000-0000-0000-0000-000000039001', player='00000000-0000-0000-0000-000000039002';
  const pot='00000000-0000-0000-0000-000000039011', other='00000000-0000-0000-0000-000000039012';
  const identity=(role='authenticated',id=player)=>`set local role ${role};set local "request.jwt.claim.role"='${role}';set local "request.jwt.claim.sub"='${id}';`;
  let assertions=0;
  const assert=(q,label)=>{if(db.sql(`select (${q})`).trim()!=='t')throw new Error(`Maintenance: ${label}`);assertions++;};
  const off=()=>db.sql("select lms_maintenance.set_enabled(false,'Local verification reopen');");
  const on=()=>db.sql("select lms_maintenance.set_enabled(true,'Local verification freeze');");
  const denied=(q,who=identity())=>{
    const result=db.sql(`begin;${who}do $test$ declare blocked boolean:=false;begin begin ${q} exception when raise_exception then if position('LMS_MAINTENANCE:' in sqlerrm)=1 then blocked:=true;else raise;end if;end;if not blocked then raise exception 'Maintenance bypass';end if;end $test$;rollback;`);
    assertions++;return result;
  };
  off();
  db.sql(`insert into auth.users(id,email) values('${admin}','maintenance-admin@example.test'),('${player}','maintenance-player@example.test');
    update public.profiles set is_admin=true where id='${admin}';
    insert into public.football_teams(id,season,fpl_team_id,code,name,short_name) values(-939001,'MAINTENANCE',-939001,939001,'Home','HOM'),(-939002,'MAINTENANCE',-939002,939002,'Away','AWY');
    insert into public.football_fixtures(id,fpl_fixture_id,season,gameweek_number,kickoff_at,home_team_id,away_team_id,status,provider_synced_at) values(-939001,-939001,'MAINTENANCE',1,now()+interval '2 days',-939001,-939002,'scheduled',now());
    insert into public.pots(id,name,season,status,lifecycle_status,created_by,entry_fee_pence,buy_back_fee_pence,is_discoverable) values('${pot}','Maintenance member','MAINTENANCE','open','open','${admin}',1000,500,true),('${other}','Maintenance discovery','MAINTENANCE','open','open','${admin}',1000,500,true);
    insert into public.pot_gameweeks(pot_id,gameweek_number,pick_deadline_at) values('${pot}',1,now()+interval '1 day'),('${other}',1,now()+interval '1 day');
    insert into public.pot_players(pot_id,player_id) values('${pot}','${player}');`);
  const pick=`perform public.confirm_team_pick('${pot}',-939001,-939001);`;
  const payment=`perform public.set_pot_player_payment('${pot}','${player}','paid');`;
  const request=`perform public.request_pot_membership('${other}');`;
  // Legitimate calls succeed OFF, with rollback preserving the same preconditions.
  for(const [q,who] of [[pick,identity()],[payment,identity('authenticated',admin)],[request,identity()]]){
    db.sql(`begin;${who}do $$ begin ${q} end $$;rollback;`);assertions++;
  }
  const fingerprint=()=>db.sql(`select md5(string_agg(row_to_json(t)::text,',' order by row_to_json(t)::text)) from (select 'picks' s,to_jsonb(x) v from public.player_picks x union all select 'members',to_jsonb(x) from public.pot_players x union all select 'pots',to_jsonb(x) from public.pots x union all select 'requests',to_jsonb(x) from public.pot_join_requests x) t;`);
  const before=fingerprint();on();
  assert("public.get_lms_maintenance()='{"+'"enabled":true'+"}'::jsonb",'state ON');
  denied(pick);denied(request);denied(`perform public.claim_pot_payment('${pot}');`);denied(payment,identity('authenticated',admin));
  denied(`perform public.set_pot_discoverable('${other}',false);`,identity('authenticated',admin));
  denied("perform public.claim_lms_provider_run('scheduler');",identity('service_role',''));
  // Test the guard independently of RLS and table grants, for every relation and
  // all statement kinds. Temporary grants/DDL live only in this rollback block.
  const tables=JSON.parse(db.sql("select jsonb_agg(tablename order by tablename) from pg_tables where schemaname='public';"));
  for(const table of tables){
    const col=db.sql(`select attname from pg_attribute where attrelid='public.${table}'::regclass and attnum>0 and not attisdropped and attgenerated='' order by attnum limit 1;`).trim();
    for(const statement of [`insert into public.${table} default values;`,`update public.${table} set ${col}=${col} where false;`,`delete from public.${table} where false;`]){
      denied(statement,`grant all on public.${table} to authenticated;${identity()}`);
    }
  }
  db.sql('create table public.maintenance_probe(id int); grant all on public.maintenance_probe to anon,authenticated,service_role;');
  for(const role of ['anon','authenticated','service_role'])denied('truncate public.maintenance_probe;',identity(role,''));
  denied('insert into public.maintenance_probe values(1);',identity('anon',''));
  // Nested SECURITY DEFINER changes current_user, but not the actual connection
  // or SET ROLE/request identity inspected by the guard.
  db.sql("create function public.maintenance_probe_definer() returns void language sql security definer as 'insert into public.maintenance_probe values(1)'; grant execute on function public.maintenance_probe_definer() to authenticated;");
  denied('perform public.maintenance_probe_definer();');
  // Emulate the Auth database role; grant is isolated to this rollback transaction.
  db.sql('grant usage on schema auth to supabase_auth_admin;grant insert on auth.users to supabase_auth_admin;');
  let signupBlocked=false;
  try { db.docker(['exec','-i',db.id,'psql','-h','127.0.0.1','-XqAt','-U','supabase_auth_admin','-d',db.database,'-v','ON_ERROR_STOP=1'],{input:"insert into auth.users(id,email) values('00000000-0000-0000-0000-000000039099','rejected@example.test');"}); }
  catch(e){signupBlocked=String(e.stderr||e).includes('LMS_MAINTENANCE:');if(!signupBlocked)throw e;}
  if(!signupBlocked)throw new Error('Auth role signup freeze unproven');assertions++;
  assert("not exists(select 1 from auth.users where email='rejected@example.test')",'no partial signup');
  db.sql('alter table public.maintenance_probe add column note text; insert into public.maintenance_probe values(1,\'operator backfill\');');
  assert('(select count(*)=1 from public.maintenance_probe)','operator schema/backfill remains available');
  denied('insert into public.maintenance_probe values(2,null);');
  if(before!==fingerprint())throw new Error('Freeze changed competition state');assertions++;
  // Missing state must deny, including the public status reader.
  db.sql(`begin;delete from lms_maintenance.state;${identity()}do $$ begin
    if public.get_lms_maintenance()->>'enabled'<>'true' then raise exception 'Unknown status allowed';end if;
    begin insert into public.maintenance_probe values(2,null);raise exception 'Missing state bypass';exception when raise_exception then if position('LMS_MAINTENANCE:' in sqlerrm)<>1 then raise;end if;end;
    end $$;rollback;`);assertions++;
  off();db.sql(`begin;${identity()}do $$ begin ${pick} end $$;rollback;`);assertions++;
  async function waitFor(name,condition){for(let n=0;n<100;n++){if(db.sql(`select exists(select 1 from pg_stat_activity where application_name='${name}' and ${condition})`).trim()==='t')return;await new Promise(r=>setTimeout(r,30));}throw new Error(`Maintenance race unobserved: ${name}`);}
  // An admitted write keeps its shared lock until commit. Activation must wait.
  const writer=db.sqlAsync(`set application_name='maintenance_writer';begin;${identity()}do $$ begin ${pick} end $$;select pg_sleep(3);commit;`);
  await waitFor('maintenance_writer',"wait_event='PgSleep'");
  const activation=db.sqlAsync("set application_name='maintenance_enable';select lms_maintenance.set_enabled(true,'Drain test');");
  await waitFor('maintenance_enable',"wait_event_type='Lock'");await Promise.all([writer,activation]);assertions++;
  denied(payment,identity('authenticated',admin));
  // A transaction whose snapshot predates activation must abort, not read OFF.
  off();
  const stale=db.sqlAsync(`set application_name='maintenance_snapshot';begin isolation level repeatable read;${identity()}select public.get_lms_maintenance();select pg_sleep(3);insert into public.maintenance_probe values(3,null);commit;`).then(()=>({allowed:true}),e=>({allowed:false,error:String(e.stderr||e)}));
  await waitFor('maintenance_snapshot',"wait_event='PgSleep'");on();const old=await stale;
  if(old.allowed||!old.error.includes('could not serialize'))throw new Error('Old snapshot bypass/incorrect error');assertions++;
  // A pending stale admin action is denied after the cutover as well.
  denied(payment,identity('authenticated',admin));
  off();db.sql(`begin;${identity('authenticated',admin)}do $$ begin ${payment} end $$;rollback;`);assertions++;
  db.sql('drop function public.maintenance_probe_definer();drop table public.maintenance_probe;');
  console.log(`PASS maintenance: ${assertions} assertions, ${tables.length} tables x INSERT/UPDATE/DELETE, TRUNCATE, signup, service role, SECURITY DEFINER, operator DDL/backfill, 2 observed transaction races, reopen.`);
}
