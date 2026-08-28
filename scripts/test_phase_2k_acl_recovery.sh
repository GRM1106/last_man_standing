#!/usr/bin/env bash
# ============================================================================
# Phase 2K ACL recovery — reproducible synthetic test harness
#
# Builds a disposable PostgreSQL 17.6 database, populates it with every object
# class and ACL state the recovery supports, captures it with the committed
# capture query, generates a recovery artifact, deliberately diverges the
# database, applies the artifact, and asserts that the result matches the
# capture exactly. Then proves rollback, fixed-point convergence, role-graph
# refusal, and the generator's refusal paths.
#
#   ./scripts/test_phase_2k_acl_recovery.sh            # run everything
#   KEEP=1 ./scripts/test_phase_2k_acl_recovery.sh     # leave the container up
#
# Exits non-zero on the first failed assertion. Touches nothing outside its own
# uniquely named container/volume and a scratch directory under TMPDIR.
#
# It never contacts staging or production and never touches the local Supabase
# stack: the container name is fixed to `pg17-p2k-selftest`, which no other
# component uses.
# ============================================================================
set -euo pipefail

IMAGE=public.ecr.aws/supabase/postgres:17.6.1.165
CTR=pg17-p2k-selftest
VOL=pg17-p2k-selftest-data
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE="$REPO/supabase/discovery/phase_2k_acl_capture.sql"
GEN="$REPO/scripts/generate_phase_2k_acl_recovery.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p2k-selftest.XXXXXX")"
PASS=0; FAIL=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
psqlq(){ docker exec -i "$CTR" psql -q -U supabase_admin -d postgres "$@"; }
psqlv(){ docker exec -i "$CTR" psql -qtA -U supabase_admin -d postgres -c "$1"; }
capture() { docker exec -i "$CTR" psql -v ON_ERROR_STOP=1 -q --csv -U supabase_admin \
              -d postgres < "$CAPTURE" > "$1" 2>"$1.err"; }
gen() { python3 "$GEN" --source "$1" --source-sha256 "$(shasum -a 256 "$1" | awk '{print $1}')" \
          --out "$2" --manifest "$3" --label "p2k selftest"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    docker volume rm "$VOL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

say "starting $CTR"
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker volume rm "$VOL" >/dev/null 2>&1 || true
docker run -d --name "$CTR" -v "$VOL":/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" "$IMAGE" >/dev/null
for _ in $(seq 1 90); do docker exec "$CTR" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
# pg_isready returns as soon as the postmaster accepts connections, but the
# Supabase image's entrypoint keeps running SQL after that -- including ALTER
# ROLE on anon/authenticated/service_role. Capturing during that window records
# role attributes that change underneath the run, which then reads as a
# role-graph divergence that never happened. Wait for pg_roles to stop moving.
ROLESNAP=""; STABLE=0
for _ in $(seq 1 120); do
  CUR=$(docker exec "$CTR" psql -qtA -U postgres -d postgres -c \
    "select string_agg(rolname||rolsuper::text||rolinherit::text||rolcreaterole::text||rolcreatedb::text||rolcanlogin::text||rolreplication::text||rolbypassrls::text, ',' order by rolname) from pg_roles" 2>/dev/null || true)
  if [ -n "$CUR" ] && [ "$CUR" = "$ROLESNAP" ]; then STABLE=$((STABLE+1)); else STABLE=0; fi
  ROLESNAP="$CUR"
  [ "$STABLE" -ge 3 ] && break
  sleep 1
done
if [ "$STABLE" -ge 3 ]; then ok "role catalogue settled after initialisation"; else bad "role catalogue never settled"; fi
assert_eq "PostgreSQL is 17.x" "$(psqlv "select substring(current_setting('server_version') from '^17')")" "17"

# --------------------------------------------------------------------------
say "building the fixture: every supported class and ACL state"
# --------------------------------------------------------------------------
psqlq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
begin;
do $$ declare r text; begin
  foreach r in array array['own_r','ra','rb','rc','third','sg','colg','grp','memb','defo_a','defo_b','platform_temp']
  loop if not exists (select 1 from pg_roles where rolname=r) then execute format('create role %I',r); end if; end loop;
end $$;
grant create, usage on schema public to own_r, defo_a, defo_b;
grant usage on schema public to ra, rb, rc, third, sg, colg, grp, memb;
grant grp to memb with admin option, inherit true, set true;   -- role graph edge
grant own_r to platform_temp with inherit false, set true;     -- downward-only platform-style member

create foreign data wrapper p2k_fdw;
create server p2k_srv foreign data wrapper p2k_fdw;
grant usage on foreign server p2k_srv to own_r;

set local role own_r;
-- every relation kind that has a row type, plus a sequence
create table             public.x_tbl (id int, c1 text, c2 int);
create table             public.x_part(id int) partition by range(id);
create view              public.x_view as select 1::int as id;
create materialized view public.x_mv   as select 1::int as id;
create foreign table     public.x_ftbl(id int) server p2k_srv;
create sequence          public.x_seq;
-- types: enum, domain, DOMAIN OVER ARRAY, composite, range
create type   public.x_enum   as enum('a','b');
create domain public.x_domain as int;
create domain public.x_darr   as int[];
create type   public.x_comp   as (a int, b text);
create type   public.x_range  as range(subtype=int8);
-- routines
create function  public.x_fn(a int) returns int language sql immutable as 'select a';
create procedure public.x_proc() language sql as 'select 1';
-- objects that will hold an EMPTY acl
create table    public.x_empty_tbl(a int);
create function public.x_empty_fn() returns int language sql as 'select 1';
create type     public.x_empty_ty as enum('z');
-- objects left with a NULL acl: x_part, x_ftbl, x_comp, x_range

-- third-party chain on a relation, and a grantor cycle participant
grant select on public.x_tbl to third with grant option;
grant delete on public.x_tbl to sg with grant option;
grant select on public.x_tbl to sg with grant option;
-- column ACLs incl. a SYSTEM column, and a column grant under a table-level option
grant select (c1) on public.x_tbl to ra;
grant update (c2) on public.x_tbl to rb with grant option;
grant select (ctid) on public.x_tbl to rc;
grant select on public.x_tbl to colg with grant option;
-- sequence, routines, types
grant usage, select on public.x_seq to rc;
grant execute on function  public.x_fn(int) to rb;
grant execute on procedure public.x_proc() to ra;
revoke execute on function public.x_fn(int) from public;   -- STRICT SUBSET of the default
grant usage on type public.x_enum   to ra;
grant usage on type public.x_domain to rb with grant option;
grant usage on type public.x_darr   to grp;                -- domain over an array
grant usage on type public.x_tbl    to sg with grant option;  -- ROW TYPE
grant usage on type public.x_view   to ra;
-- EMPTY acls
grant select  on public.x_empty_tbl to own_r; revoke all on public.x_empty_tbl from own_r, public;
grant execute on function public.x_empty_fn() to own_r; revoke all on function public.x_empty_fn() from own_r, public;
grant usage   on type public.x_empty_ty to own_r; revoke all on type public.x_empty_ty from own_r, public;
reset role;
-- third-party grantors
set local role third; grant select on public.x_tbl to rb;      reset role;
set local role sg;    grant usage on type public.x_tbl to rc;  reset role;   -- on a ROW TYPE
set local role sg;    grant select on public.x_tbl to sg;      reset role;   -- SELF-GRANT
set local role colg;  grant select (c1) on public.x_tbl to third; reset role; -- column under table option
-- default privileges: scoped, global, strict-subset and empty
set local role defo_a;
alter default privileges for role defo_a in schema public grant select on tables to ra;
alter default privileges for role defo_a in schema public grant usage on sequences to rb with grant option;
alter default privileges for role defo_a grant usage on types to rc;
reset role;
set local role defo_b;
alter default privileges for role defo_b in schema public grant insert on tables to rc with grant option;
alter default privileges for role defo_b revoke execute on functions from public;
alter default privileges for role defo_b revoke usage on types from public, defo_b;
reset role;
commit;
SQL
ok "fixture built"

say "capturing the source"
capture "$WORK/src.csv"
SRC_ROWS=$(( $(grep -c . "$WORK/src.csv") - 1 ))
assert_eq "capture stderr empty" "$(wc -c <"$WORK/src.csv.err" | tr -d ' ')" "0"
capture "$WORK/src2.csv"
if cmp -s "$WORK/src.csv" "$WORK/src2.csv"; then ok "capture is deterministic ($SRC_ROWS rows)"; else bad "capture not deterministic"; fi
if [ "$(awk -F, '$1 ~ /^I\./ && $3=="public.x_darr"' "$WORK/src.csv" | wc -l | tr -d ' ')" -ge 1 ]; then
  ok "domain over an array is captured"; else bad "domain over an array is NOT captured"; fi
assert_eq "true array types are not captured" \
  "$(awk -F, '$1 ~ /^I\./ && $3 ~ /public\._/' "$WORK/src.csv" | wc -l | tr -d ' ')" "0"
assert_eq "multirange type is not captured" \
  "$(awk -F, '$1 ~ /^I\./ && $2=="multirange"' "$WORK/src.csv" | wc -l | tr -d ' ')" "0"
assert_eq "system-column ACL is captured" \
  "$(awk -F, '$1 ~ /^C\./ && $3=="public.x_tbl.ctid"' "$WORK/src.csv" | wc -l | tr -d ' ')" "1"
assert_eq "row type and relation are distinguished" \
  "$(awk -F, '$3=="public.x_tbl" && $1 ~ /^E\./' "$WORK/src.csv" | wc -l | tr -d ' ')" "2"
assert_eq "three empty-ACL objects captured" \
  "$(awk -F, '$1 ~ /^E\./ && $9 ~ /acl empty/' "$WORK/src.csv" | wc -l | tr -d ' ')" "3"
assert_eq "role membership edge captured via the recursive closure" \
  "$(awk -F, '$1 ~ /^H\./ && $2=="membership" && $3=="memb -> grp"' "$WORK/src.csv" | wc -l | tr -d ' ')" "1"
assert_eq "downward-only role remains in the forensic capture" \
  "$(awk -F, '$1 ~ /^H\./ && $2=="role" && $3=="platform_temp" && $7=="attributes"' "$WORK/src.csv" | wc -l | tr -d ' ')" "1"

say "generating the artifact"
gen "$WORK/src.csv" "$WORK/art.sql" "$WORK/man.txt" >/dev/null
gen "$WORK/src.csv" "$WORK/art2.sql" "$WORK/man2.txt" >/dev/null
if cmp -s "$WORK/art.sql" "$WORK/art2.sql"; then ok "generator is deterministic"; else bad "generator not deterministic"; fi
if ! grep -q "platform_temp" "$WORK/art.sql" && grep -q "platform_temp" "$WORK/man.txt"; then
  ok "downward-only platform role is excluded from execution and recorded in manifest"
else
  bad "downward-only platform role projection is incorrect"
fi

# --------------------------------------------------------------------------
say "generator refusal paths"
# --------------------------------------------------------------------------
refuse() {  # name, python mutation
  python3 - "$WORK/src.csv" "$WORK/bad.csv" <<PY
import csv,sys
rows=[list(r) for r in csv.reader(open(sys.argv[1],newline=''))]
$2
csv.writer(open(sys.argv[2],'w',newline='')).writerows(rows)
PY
  if python3 "$GEN" --source "$WORK/bad.csv" --source-sha256 "$(shasum -a 256 "$WORK/bad.csv" | awk '{print $1}')" \
       --out "$WORK/no.sql" --manifest "$WORK/no.txt" >/dev/null 2>&1
  then bad "refusal: $1 (generator accepted it)"; else ok "refusal: $1"; fi
  rm -f "$WORK/no.sql" "$WORK/no.txt"
}
if python3 "$GEN" --source "$WORK/src.csv" --source-sha256 "$(printf '0%.0s' $(seq 64))" \
     --out "$WORK/no.sql" --manifest "$WORK/no.txt" >/dev/null 2>&1
then bad "refusal: wrong source hash"; else ok "refusal: wrong source hash"; fi
refuse "duplicate row"            'rows.append(rows[1])'
refuse "unknown section"          'rows.append(["Z. BOGUS","schema","public","postgres","-","-","-","-","x"])'
refuse "short row"                'rows.append(rows[1][:8])'
refuse "unsupported object_kind"  'rows.append(["B. RELATION PRIVILEGES","gizmo","public.q","own_r","ra","own_r","SELECT","false","explicit"])'
refuse "UNCLASSIFIED schema"      'rows.append(["J. SCHEMA SCOPE","schema","zz","postgres","-","-","-","-","UNCLASSIFIED: recovery must FAIL CLOSED"])'
refuse "injected privilege_type"  '[r.__setitem__(6,"SELECT; COPY (select 1) TO PROGRAM (chr(105)||chr(100)); --") for r in rows[1:] if r[0]=="B. RELATION PRIVILEGES"][:1]'
refuse "injected routine args"    '[r.__setitem__(2,"public.f(a int); drop table t; --)") for r in rows[1:] if r[0]=="D. ROUTINE PRIVILEGES"][:1]'
refuse "ambiguous dotted identity" 'rows.append(["B. RELATION PRIVILEGES","table","a.b.c","own_r","ra","own_r","SELECT","false","explicit"])'
refuse "edge with no ownership row" 'rows.append(["B. RELATION PRIVILEGES","table","public.orphan","own_r","ra","own_r","SELECT","false","explicit"])'
refuse "malformed membership"     'rows.append(["H. ROLE SECURITY CONTEXT","membership","no-arrow","-","memb","supabase_admin","membership","false","inherit_option=true set_option=true"])'
if python3 "$GEN" --source "$WORK/src.csv" --source-sha256 "$(shasum -a 256 "$WORK/src.csv" | awk '{print $1}')" \
     --out "$WORK/no.sql" --manifest "$WORK/no.txt" --label "$(printf 'a\nselect 1;')" >/dev/null 2>&1
then bad "refusal: newline in --label"; else ok "refusal: newline in --label"; fi
rm -f "$WORK/no.sql" "$WORK/no.txt"

# --------------------------------------------------------------------------
say "diverging the target in both directions, in every class"
# --------------------------------------------------------------------------
psqlq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
begin;
do $$ begin if not exists (select 1 from pg_roles where rolname='excess') then create role excess; end if; end $$;
grant usage on schema public to excess;
set local role pg_database_owner; grant create on schema public to excess; reset role;
set local role own_r;
-- excess
grant select, insert on public.x_tbl to excess with grant option;
grant update (c1) on public.x_tbl to excess;
grant select (xmin) on public.x_tbl to excess;
grant usage, select on public.x_seq to excess;
grant execute on function public.x_fn(int) to excess;
grant usage on type public.x_enum to excess;
grant usage on type public.x_tbl  to excess;
grant usage on type public.x_part to excess;
grant usage on type public.x_darr to excess;
grant usage on type public.x_empty_ty to excess;
-- deficit
revoke select (c1) on public.x_tbl from ra;
revoke select (ctid) on public.x_tbl from rc;
revoke usage on type public.x_domain from rb;
revoke usage on type public.x_view from ra;
revoke execute on procedure public.x_proc() from ra;
revoke select on public.x_seq from rc;
-- force NULL ACLs where the source has EMPTY, and where the source has a strict subset
drop table public.x_empty_tbl; create table public.x_empty_tbl(a int);
drop function public.x_empty_fn(); create function public.x_empty_fn() returns int language sql as 'select 1';
drop type public.x_empty_ty; create type public.x_empty_ty as enum('z');
drop function public.x_fn(int); create function public.x_fn(a int) returns int language sql immutable as 'select a';
reset role;
set local role third; revoke select on public.x_tbl from rb; reset role;
set local role sg;    revoke usage on type public.x_tbl from rc; reset role;
set local role pg_database_owner; revoke usage on schema public from rb; reset role;
set local role defo_a; alter default privileges for role defo_a in schema public grant delete on tables to excess; reset role;
set local role defo_b; alter default privileges for role defo_b grant usage on types to excess; reset role;
commit;
SQL
DIV=$(psqlv "select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a where c.relnamespace='public'::regnamespace")
ok "target diverged (relation ACL edges now $DIV)"

# --------------------------------------------------------------------------
say "rollback: injected mid-run failure leaves the target unchanged"
# --------------------------------------------------------------------------
capture "$WORK/pre_fail.csv"
awk '{print} /replay defaults complete/{print "  raise exception '"'"'INJECTED FAILURE'"'"';"}' "$WORK/art.sql" > "$WORK/art_fail.sql"
psqlq < "$WORK/art_fail.sql" >/dev/null 2>&1 || true
capture "$WORK/post_fail.csv"
if cmp -s "$WORK/pre_fail.csv" "$WORK/post_fail.csv"; then ok "rollback left the target byte-identical"; else bad "rollback changed state"; fi

# --------------------------------------------------------------------------
say "role-graph parity: a deliberate mismatch must be refused before any mutation"
# --------------------------------------------------------------------------
# NOTE: never pipe psqlq into grep here. Under `set -o pipefail` psql exits
# non-zero when the artifact aborts, so the pipeline is non-zero even when grep
# matched, and every refusal test would read as a pass-through.
expect_refusal() {   # $1 = description, $2 = message fragment
  psqlq < "$WORK/art.sql" > "$WORK/refusal.log" 2>&1 || true
  if grep -q "$2" "$WORK/refusal.log"; then ok "$1"; else bad "$1 (got: $(grep -m1 -E 'ERROR|NOTICE' "$WORK/refusal.log" || echo none))"; fi
}
psqlq -c "revoke grp from memb;" >/dev/null 2>&1
expect_refusal "membership mismatch refused" "PREFLIGHT: captured membership"
capture "$WORK/post_role.csv"
# Section H legitimately differs here: the test itself removed the membership.
# Compare the privilege sections, which a refusal must not have touched.
privonly() { grep -v '^H\.' "$1"; }
if diff <(privonly "$WORK/pre_fail.csv") <(privonly "$WORK/post_role.csv") >/dev/null; then
  ok "membership refusal mutated no privilege"; else bad "membership refusal mutated a privilege"; fi
psqlq -c "grant grp to memb with admin option, inherit true, set true;" >/dev/null 2>&1
psqlq -c "revoke admin option for grp from memb;" >/dev/null 2>&1
expect_refusal "admin_option mismatch refused" "PREFLIGHT: captured membership"
psqlq -c "grant grp to memb with admin option;" >/dev/null 2>&1
psqlq -c "grant grp to rc;" >/dev/null 2>&1
expect_refusal "extra membership refused" "that the capture does not record"
psqlq -c "revoke grp from rc;" >/dev/null 2>&1
psqlq -c "alter role rc createdb;" >/dev/null 2>&1
expect_refusal "role attribute mismatch refused" "different attributes"
psqlq -c "alter role rc nocreatedb;" >/dev/null 2>&1
capture "$WORK/post_role2.csv"
if cmp -s "$WORK/pre_fail.csv" "$WORK/post_role2.csv"; then ok "all role refusals mutated nothing (role state restored)"; else bad "a role refusal mutated state"; fi

# --------------------------------------------------------------------------
say "apply"
# --------------------------------------------------------------------------
psqlq < "$WORK/art.sql" > "$WORK/apply.log" 2>&1 || true
sed 's/^/    /' "$WORK/apply.log" | grep -E 'NOTICE|ERROR' || true
if grep -q 'verify ok' "$WORK/apply.log"; then ok "verification passed inside the transaction"; else bad "verification did not pass"; fi
if grep -q 'materialised .* empty ACL' "$WORK/apply.log"; then ok "empty ACLs materialised"; else bad "empty ACLs not materialised"; fi

say "parity"
capture "$WORK/after.csv"
python3 "$REPO/scripts/p2k_parity_check.py" "$WORK/src.csv" "$WORK/after.csv" > "$WORK/parity.txt" 2>&1 || true
assert_eq "no captured privilege fact missing after recovery"   "$(awk '/^MISSING/{print $2}' "$WORK/parity.txt")" "0"
assert_eq "no unapproved privilege fact present after recovery" "$(awk '/^EXTRA/{print $2}'   "$WORK/parity.txt")" "0"
grep '^  DIFF' "$WORK/parity.txt" | sed 's/^/      /' || true
printf '  INFO  approved provenance residual rows: %s (NULL-captured objects only)\n' "$(awk '/^RESIDUAL/{print $2}' "$WORK/parity.txt")"
assert_eq "empty relation ACL restored"  "$(psqlv "select coalesce(relacl::text,'NULL') from pg_class where oid='public.x_empty_tbl'::regclass")" "{}"
assert_eq "empty routine ACL restored"   "$(psqlv "select coalesce(proacl::text,'NULL') from pg_proc where proname='x_empty_fn'")" "{}"
assert_eq "empty type ACL restored"      "$(psqlv "select coalesce(typacl::text,'NULL') from pg_type where oid='public.x_empty_ty'::regtype")" "{}"
RESTORED_FN=$(psqlv "select proacl::text from pg_proc where proname='x_fn'")
if printf '%s' "$RESTORED_FN" | grep -qE '[{,]=X/'; then
  bad "strict-subset routine ACL still grants PUBLIC EXECUTE ($RESTORED_FN)"
else ok "strict-subset routine ACL restored without PUBLIC ($RESTORED_FN)"; fi
assert_eq "role excess holds nothing on relations" \
  "$(psqlv "select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a where c.relnamespace='public'::regnamespace and pg_get_userbyid(a.grantee)='excess'")" "0"

say "fixed-point convergence"
psqlq < "$WORK/art.sql" >/dev/null 2>&1 || true
psqlq < "$WORK/art.sql" >/dev/null 2>&1 || true
capture "$WORK/after3.csv"
if cmp -s "$WORK/after.csv" "$WORK/after3.csv"; then ok "state after run 3 identical to run 1"; else bad "fixed point violated"; fi

printf '\n\033[1m== summary ==\033[0m\n  %s passed, %s failed\n  scratch: %s\n' "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
