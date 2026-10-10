-- Fail closed on unknown result readiness in the shared, fully migrated processor.
-- Forward-only: no historical picks, processes, actors or completion rows are changed.
begin;

do $$
declare definition text; change record; occurrences integer;
begin
  if to_regprocedure('public.assert_lms_schedule_integrity(uuid)') is null then
    raise exception 'Nullable finality correction requires the complete historical schedule integrity baseline';
  end if;
  definition:=pg_get_functiondef('public.process_pot_gameweek_p2_base(uuid,integer,boolean)'::regprocedure);

  -- Preserve every wrapper, lock, attribution trigger and existing exceptional decision.
  -- Guard each replacement independently: an unfamiliar baseline must abort installation.
  for change in select * from (values
    ('(effective.processable or pick.exceptional_resolution_type=''auto_win'')',
     '(effective.processable is true or (pick.exceptional_resolution_type=''auto_win'') is true)',1),
    ('when not effective.processable then ''pending''',
     'when effective.processable is not true then ''pending''',1),
    ('where not locked_result.processable',
     'where locked_result.processable is not true',2)
  ) as changes(old_fragment,new_fragment,expected_count)
  loop
    occurrences:=(length(definition)-length(replace(definition,change.old_fragment,'')))/length(change.old_fragment);
    if occurrences<>change.expected_count then
      raise exception 'Unexpected processing baseline for nullable finality correction: %',change.old_fragment;
    end if;
    definition:=replace(definition,change.old_fragment,change.new_fragment);
  end loop;
  execute definition;
end $$;

-- CREATE OR REPLACE retains the existing function identity and ACL. Check the boundary.
do $$
begin
  if has_function_privilege('anon','public.process_pot_gameweek_p2_base(uuid,integer,boolean)','execute')
    or has_function_privilege('authenticated','public.process_pot_gameweek_p2_base(uuid,integer,boolean)','execute') then
    raise exception 'The shared result processor must remain internal';
  end if;
  if not exists(select 1 from pg_proc
    where oid='public.process_pot_gameweek_p2_base(uuid,integer,boolean)'::regprocedure
      and prosecdef and array_to_string(proconfig,',') like 'search_path=%') then
    raise exception 'The shared result processor must retain SECURITY DEFINER and an empty search_path';
  end if;
end $$;

commit;
