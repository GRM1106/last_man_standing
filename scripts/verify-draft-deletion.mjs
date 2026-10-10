// Two real sessions prove deletion rechecks state after concurrent mutations.
export async function verifyDraftDeletionRaces(db) {
  const admin = db.sql('select id from public.profiles where is_admin order by id limit 1').trim();
  const identity = `set local role authenticated; set local "request.jwt.claim.role"='authenticated'; set local "request.jwt.claim.sub"='${admin}';`;
  async function waitFor(name, condition) {
    for (let n = 0; n < 60; n++) {
      if (db.sql(`select exists(select 1 from pg_stat_activity where application_name='${name}' and ${condition})`).trim() === 't') return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`Did not observe ${name}: ${condition}`);
  }
  for (const scenario of ['status', 'finalisation']) {
    const pot = db.sql(`begin; ${identity} select public.create_pot('Deletion race ${scenario}','DRAFT-DELETE-RACE',0,0,array[1],array['${admin}'::uuid]); commit;`).trim();
    const writerName = `draft_writer_${scenario}`;
    const deletionName = `draft_delete_${scenario}`;
    const mutation = scenario === 'status'
      ? `update public.pots set status='open',lifecycle_status='open' where id='${pot}';`
      : `select pg_advisory_xact_lock(hashtext('${pot}'),-2); update public.pot_rounds set cohort_finalized_at=now() where pot_id='${pot}';`;
    // The finalisation branch models the schedule lock and round write used by
    // processing, without manufacturing an entire football result pipeline here.
    const writer = db.sqlAsync(`set application_name='${writerName}'; begin; ${mutation} select pg_sleep(4); commit;`);
    let deletion;
    try {
      await waitFor(writerName, "wait_event='PgSleep'");
      const expected = scenario === 'status' ? 'Only draft pots can be deleted' : 'A draft with competition or review history cannot be deleted';
      deletion = db.sqlAsync(`set application_name='${deletionName}'; begin; ${identity}
        do $$ declare denied boolean:=false; begin
          begin perform public.delete_draft_pot('${pot}','Deletion race ${scenario}');
          exception when raise_exception then if sqlerrm='${expected}' then denied:=true; else raise; end if; end;
          if not denied then raise exception 'Concurrent protected pot was deleted'; end if;
        end $$; commit;`);
      await waitFor(deletionName, "wait_event_type='Lock'");
    } finally {
      const results = await Promise.allSettled([writer, ...(deletion ? [deletion] : [])]);
      for (const result of results) if (result.status === 'rejected') throw result.reason;
    }
    const guard = scenario === 'status' ? "status='open' and lifecycle_status='open'" : `exists(select 1 from public.pot_rounds where pot_id='${pot}' and cohort_finalized_at is not null)`;
    if (db.sql(`select exists(select 1 from public.pots where id='${pot}' and ${guard})`).trim() !== 't') throw new Error('Concurrent protected state did not survive');
  }
  console.log('PASS draft deletion: 2 observed two-session races preserve concurrently opened/finalised pots.');
}
