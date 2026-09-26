-- Retire the launch-only registration approval flag. Pot membership, payment,
-- buy-back decisions, role checks and RLS remain independent and unchanged.
begin;
alter table public.profiles alter column approved set default true;
update public.profiles set approved = true where not approved;
comment on column public.profiles.approved is
  'Deprecated launch-gate metadata retained for compatibility; not an authorisation control. Registration is open.';
drop function public.set_player_approval(uuid, boolean);
commit;
