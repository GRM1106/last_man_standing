-- Phase 2K: ensure the application profile trigger exists on platform-owned auth.users.
-- The logical schema dump restores the public function but excludes this cross-schema trigger.
begin;

do $$
declare trigger_row record;
begin
  if to_regclass('auth.users') is null then
    raise exception 'Phase 2K profile trigger requires auth.users';
  end if;
  if to_regprocedure('public.create_profile_for_new_user()') is null then
    raise exception 'Phase 2K profile trigger requires public.create_profile_for_new_user()';
  end if;

  select t.tgfoid, t.tgenabled, pg_get_triggerdef(t.oid) as definition
  into trigger_row
  from pg_trigger t
  where t.tgrelid='auth.users'::regclass
    and t.tgname='create_profile_after_signup'
    and not t.tgisinternal;

  if found then
    if trigger_row.tgfoid<>'public.create_profile_for_new_user()'::regprocedure
      or trigger_row.tgenabled<>'O'
      or trigger_row.definition not like 'CREATE TRIGGER create_profile_after_signup AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.create_profile_for_new_user()%' then
      raise exception 'Phase 2K refuses an unexpected create_profile_after_signup trigger';
    end if;
  else
    create trigger create_profile_after_signup
    after insert on auth.users for each row
    execute function public.create_profile_for_new_user();
  end if;
end $$;

do $$
begin
  if not exists(
    select 1 from pg_trigger t
    where t.tgrelid='auth.users'::regclass
      and t.tgname='create_profile_after_signup'
      and not t.tgisinternal
      and t.tgenabled='O'
      and t.tgfoid='public.create_profile_for_new_user()'::regprocedure
  ) then
    raise exception 'Phase 2K did not establish the profile signup trigger';
  end if;
end $$;

commit;
