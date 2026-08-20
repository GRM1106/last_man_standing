-- Run once in the Supabase SQL Editor. New players are locked by default.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  first_name text,
  last_name text,
  mobile_number text,
  approved boolean not null default false,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Players can view their own profile"
on public.profiles for select to authenticated
using ((select auth.uid()) = id);

create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id,email,display_name,first_name,last_name,mobile_number)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',new.raw_user_meta_data ->> 'name',new.email),
    coalesce(new.raw_user_meta_data ->> 'first_name',new.raw_user_meta_data ->> 'given_name'),
    coalesce(new.raw_user_meta_data ->> 'last_name',new.raw_user_meta_data ->> 'family_name'),
    new.raw_user_meta_data ->> 'phone'
  );
  return new;
end;
$$;

create trigger create_profile_after_signup
after insert on auth.users for each row
execute procedure public.create_profile_for_new_user();
