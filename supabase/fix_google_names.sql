-- Run once in the Supabase SQL Editor.
-- Updates the signup trigger for Google metadata and repairs existing profiles.
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

update public.profiles as profile
set
  display_name = coalesce(profile.display_name,user_account.raw_user_meta_data ->> 'full_name',user_account.raw_user_meta_data ->> 'name',profile.email),
  first_name = coalesce(profile.first_name,user_account.raw_user_meta_data ->> 'first_name',user_account.raw_user_meta_data ->> 'given_name'),
  last_name = coalesce(profile.last_name,user_account.raw_user_meta_data ->> 'last_name',user_account.raw_user_meta_data ->> 'family_name')
from auth.users as user_account
where profile.id = user_account.id
  and (profile.first_name is null or profile.last_name is null);
