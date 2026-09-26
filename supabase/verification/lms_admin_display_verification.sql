-- Actual authenticated RPC results; rollback leaves no test data.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-0000-0000-000000026701','display-admin@example.test','{"first_name":"Display","last_name":"Admin"}'),
('00000000-0000-0000-0000-000000026702','display-member@example.test','{"first_name":"Display","last_name":"Member"}');
update public.profiles set first_name=null,last_name=null,display_name=email where id='00000000-0000-0000-0000-000000026702';
update public.profiles set is_admin=true where id='00000000-0000-0000-0000-000000026701';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026701',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$ declare pot uuid; result jsonb; begin
 pot:=public.create_pot('Display test','DISPLAY-LOCAL',0,0,array[1],array['00000000-0000-0000-0000-000000026702'::uuid]);
 result:=public.get_admin_pick_overview(pot,1);
 if jsonb_array_length(result->'players') is distinct from 1 then raise exception 'Member missing or duplicated'; end if;
 if result#>>'{players,0,name}' is distinct from 'Player' then raise exception 'Incorrect member name'; end if;
 if result#>>'{players,0,email}' is distinct from 'display-member@example.test' then raise exception 'Administrator contact field missing'; end if;
 if result#>>'{players,0,payment_status}' is distinct from 'unpaid' then raise exception 'Incorrect payment status'; end if;
 if result#>'{players,0,pick}' is distinct from 'null'::jsonb then raise exception 'Missing pick misrepresented'; end if;
 perform public.remove_player_from_pot(pot,'00000000-0000-0000-0000-000000026702');
 result:=public.get_admin_pick_overview(pot,1);
 if result->'players' is distinct from '[]'::jsonb then raise exception 'Empty membership produces phantom player'; end if;
 if result->>'pot_name' is distinct from 'Display test' then raise exception 'Empty pot metadata missing'; end if;
 perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000026702',true);
 begin perform public.get_admin_pick_overview(pot,1); raise exception 'Non-admin overview exposed';
 exception when raise_exception then if sqlerrm is distinct from 'Administrator access required' then raise; end if; end;
end $$;
reset role;
set local role anon;
do $$ begin
 begin perform public.get_admin_pick_overview('00000000-0000-0000-0000-000000026703',1); raise exception 'Anonymous overview exposed';
 exception when insufficient_privilege then null; end;
end $$;
rollback;
select 'PASS admin display: 9 RPC data and permission assertions.';
