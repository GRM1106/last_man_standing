-- Phase 2K: remove legacy default-derived table privileges from API roles.
-- This migration establishes the complete intended client-role ACL explicitly so its result
-- does not depend on the target's starting default privileges.
begin;

do $$
declare relation_name text;
begin
  if not exists(select 1 from pg_roles where rolname='anon')
    or not exists(select 1 from pg_roles where rolname='authenticated') then
    raise exception 'Phase 2K ACL hardening requires the anon and authenticated roles';
  end if;

  foreach relation_name in array array[
    'football_fixtures','football_team_form','football_teams','player_picks',
    'pot_fixture_test_results','pot_gameweek_processes','pot_gameweeks','pot_players',
    'pots','profiles'
  ] loop
    if to_regclass(format('public.%I',relation_name)) is null then
      raise exception 'Phase 2K ACL hardening requires public.%',relation_name;
    end if;
  end loop;
end $$;

revoke all privileges on table
  public.football_fixtures,
  public.football_team_form,
  public.football_teams,
  public.player_picks,
  public.pot_fixture_test_results,
  public.pot_gameweek_processes,
  public.pot_gameweeks,
  public.pot_players,
  public.pots,
  public.profiles
from anon,authenticated;

grant select on table
  public.football_fixtures,
  public.football_team_form,
  public.football_teams,
  public.player_picks,
  public.pot_gameweeks,
  public.pot_players,
  public.pots,
  public.profiles
to authenticated;

-- Prevent the same legacy grants from returning on the next application table.
-- Phase 2K application migrations run as postgres; supabase_admin-owned defaults are
-- platform-managed and deliberately outside this migration's ownership boundary.
alter default privileges for role postgres in schema public
  revoke all privileges on tables from anon,authenticated;

do $$
declare unexpected text;
begin
  select string_agg(format('%s:%s:%s',c.relname,role.rolname,acl.privilege_type),', ' order by c.relname,role.rolname,acl.privilege_type)
  into unexpected
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl,'{}'::aclitem[])) acl
  join pg_roles role on role.oid=acl.grantee
  where n.nspname='public'
    and c.relname=any(array[
      'football_fixtures','football_team_form','football_teams','player_picks',
      'pot_fixture_test_results','pot_gameweek_processes','pot_gameweeks','pot_players',
      'pots','profiles'
    ])
    and role.rolname in('anon','authenticated')
    and acl.privilege_type<>'SELECT';
  if unexpected is not null then
    raise exception 'Phase 2K ACL hardening left unexpected API-role privileges: %',unexpected;
  end if;

  if exists(
    select 1
    from unnest(array[
      'football_fixtures','football_team_form','football_teams','player_picks',
      'pot_gameweeks','pot_players','pots','profiles'
    ]) relation_name
    where not has_table_privilege('authenticated',format('public.%I',relation_name),'SELECT')
  ) then
    raise exception 'Phase 2K ACL hardening did not preserve every intended authenticated SELECT grant';
  end if;

  if has_table_privilege('authenticated','public.pot_fixture_test_results','SELECT')
    or has_table_privilege('authenticated','public.pot_gameweek_processes','SELECT')
    or exists(
      select 1
      from unnest(array[
        'football_fixtures','football_team_form','football_teams','player_picks',
        'pot_fixture_test_results','pot_gameweek_processes','pot_gameweeks','pot_players',
        'pots','profiles'
      ]) relation_name
      where has_table_privilege('anon',format('public.%I',relation_name),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    ) then
    raise exception 'Phase 2K ACL hardening found unintended API access after revocation';
  end if;

  if exists(
    select 1
    from pg_default_acl defaults
    cross join lateral aclexplode(defaults.defaclacl) acl
    join pg_roles owner_role on owner_role.oid=defaults.defaclrole
    join pg_roles grantee_role on grantee_role.oid=acl.grantee
    join pg_namespace namespace on namespace.oid=defaults.defaclnamespace
    where owner_role.rolname='postgres'
      and namespace.nspname='public'
      and defaults.defaclobjtype='r'
      and grantee_role.rolname in('anon','authenticated')
  ) then
    raise exception 'Phase 2K ACL hardening left unsafe postgres table defaults';
  end if;
end $$;

commit;
