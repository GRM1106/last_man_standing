-- Rollback-only integration checks on the final schema, including real RLS roles.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-0000-0000-000000026601','open-player@example.test','{"first_name":"Open","last_name":"Player","is_admin":true,"approved":false}'),
('00000000-0000-0000-0000-000000026602','open-other@example.test','{"first_name":"Other"}');
do $$ begin
  if not exists(select 1 from public.profiles where id='00000000-0000-0000-0000-000000026601' and approved and not is_admin and first_name='Open' and last_name='Player') then raise exception 'Open profile defaults or safe metadata failed'; end if;
  if to_regprocedure('public.set_player_approval(uuid,boolean)') is not null then raise exception 'Retired approval RPC remains'; end if;
  if not (select relrowsecurity from pg_class where oid='public.profiles'::regclass) then raise exception 'Profile RLS disabled'; end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026601',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$ begin
  if public.get_my_dashboard()->>'first_name'<>'Open' or public.get_my_dashboard()->'pots'<>'[]'::jsonb then raise exception 'New player cannot access empty dashboard'; end if;
  if public.is_current_user_admin() then raise exception 'Metadata escalated role'; end if;
  if (select count(*) from public.profiles)<>1 then raise exception 'Player can see other profiles'; end if;
  begin
    update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000026601';
    raise exception 'Player can change own role';
  exception when insufficient_privilege then null; end;
  begin
    perform public.create_pot('Unauthorised','LOCAL',0,0,array[1],array['00000000-0000-0000-0000-000000026601'::uuid]);
    raise exception 'Player can create pots';
  exception when raise_exception then if sqlerrm<>'Administrator access required' then raise; end if; end;
  begin
    perform public.set_buy_back_decision('00000000-0000-0000-0000-000000026603','00000000-0000-0000-0000-000000026601',true);
    raise exception 'Player can approve own buy-back';
  exception when raise_exception then if sqlerrm<>'Administrator access required' then raise; end if; end;
end $$;
reset role;
-- Legacy false metadata must remain inert: do not recreate a gate in older accounts.
update public.profiles set approved=false where id='00000000-0000-0000-0000-000000026601';
set local role authenticated;
do $$ begin
  if public.get_my_dashboard()->>'first_name'<>'Open' then raise exception 'Legacy metadata blocks access'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform public.get_my_dashboard(); raise exception 'Anonymous dashboard exposed';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
