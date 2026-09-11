-- Disposable PostgreSQL fixture for the Supabase authentication boundary.
-- Identity issuance/OAuth/gateway verification remains a hosted smoke-test concern.
create schema auth;
create table auth.users (
  instance_id uuid, id uuid primary key, aud text, role text, email text,
  encrypted_password text, email_confirmed_at timestamptz,
  raw_app_meta_data jsonb, raw_user_meta_data jsonb, created_at timestamptz, updated_at timestamptz
);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role')
$$;
grant usage on schema public,auth to anon,authenticated,service_role;
grant execute on function auth.uid(),auth.role() to anon,authenticated,service_role;
-- Legacy baseline privileges; the real 2K ACL migration must remove client mutations.
alter default privileges for role postgres in schema public grant all on tables to anon,authenticated,service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon,authenticated,service_role;
