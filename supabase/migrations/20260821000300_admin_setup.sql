-- Run once in the Supabase SQL Editor after setup.sql.
grant select on table public.profiles to authenticated;

create or replace function public.is_current_user_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = (select auth.uid())), false);
$$;
revoke all on function public.is_current_user_admin() from public;
grant execute on function public.is_current_user_admin() to authenticated;

drop policy if exists "Admins can view all profiles" on public.profiles;
create policy "Admins can view all profiles" on public.profiles for select to authenticated
using ((select public.is_current_user_admin()));

create or replace function public.set_player_approval(player_id uuid, new_approved boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  update public.profiles set approved = new_approved where id = player_id;
  if not found then raise exception 'Player not found'; end if;
end;
$$;
revoke all on function public.set_player_approval(uuid, boolean) from public;
grant execute on function public.set_player_approval(uuid, boolean) to authenticated;
