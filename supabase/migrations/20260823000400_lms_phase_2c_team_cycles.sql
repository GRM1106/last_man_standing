-- Phase 2C: per-player, per-pot team-use cycle foundation.
begin;
do $$ begin
 if to_regclass('public.pot_rounds') is null then raise exception 'Phase 2C requires Phase 2B'; end if;
 if to_regclass('public.pot_player_team_cycles') is not null then raise exception 'Phase 2C is already installed'; end if;
 if exists(select 1 from public.player_picks group by pot_id,player_id,team_id having count(*)>1) then
   raise exception 'Phase 2C cannot backfill existing repeated team use into Cycle 1'; end if;
end $$;

create table public.pot_player_team_cycles(
 id uuid primary key default gen_random_uuid(), pot_id uuid not null, player_id uuid not null,
 cycle_number integer not null check(cycle_number>0), started_at timestamptz not null default now(), closed_at timestamptz,
 foreign key(pot_id,player_id) references public.pot_players(pot_id,player_id) on delete cascade,
 unique(pot_id,player_id,cycle_number), unique(id,pot_id,player_id)
);
create unique index pot_player_team_cycles_one_active on public.pot_player_team_cycles(pot_id,player_id) where closed_at is null;
insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number,started_at)
select pot_id,player_id,1,joined_at from public.pot_players;

create or replace function public.create_initial_team_cycle() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.pot_player_team_cycles(pot_id,player_id,cycle_number,started_at) values(new.pot_id,new.player_id,1,new.joined_at);
 return new;
end $$;
create trigger pot_players_create_initial_team_cycle after insert on public.pot_players for each row execute function public.create_initial_team_cycle();
revoke all on function public.create_initial_team_cycle() from public,anon,authenticated;

create or replace function public.current_team_cycle_id(selected_pot_id uuid,selected_player_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select id from public.pot_player_team_cycles where pot_id=selected_pot_id and player_id=selected_player_id and closed_at is null;
$$;
revoke all on function public.current_team_cycle_id(uuid,uuid) from public,anon,authenticated;

alter table public.player_picks add column team_cycle_id uuid;
update public.player_picks p set team_cycle_id=c.id from public.pot_player_team_cycles c
where c.pot_id=p.pot_id and c.player_id=p.player_id and c.cycle_number=1;
alter table public.player_picks alter column team_cycle_id set not null;
alter table public.player_picks add constraint player_picks_team_cycle_owner_fk foreign key(team_cycle_id,pot_id,player_id)
 references public.pot_player_team_cycles(id,pot_id,player_id);
alter table public.player_picks add constraint player_picks_team_cycle_team_unique unique(team_cycle_id,team_id);
alter table public.player_picks drop constraint player_picks_pot_id_player_id_team_id_key;

create or replace function public.link_pick_to_team_cycle() returns trigger language plpgsql security definer set search_path='' as $$
declare active_cycle uuid;
begin
 active_cycle:=public.current_team_cycle_id(new.pot_id,new.player_id);
 if active_cycle is null then raise exception 'Player has no active team-use cycle'; end if;
 if new.team_cycle_id is not null and new.team_cycle_id<>active_cycle then raise exception 'Pick team-use cycle is not current for this player and pot'; end if;
 new.team_cycle_id:=active_cycle; return new;
end $$;
create trigger player_picks_link_team_cycle before insert on public.player_picks for each row execute function public.link_pick_to_team_cycle();
revoke all on function public.link_pick_to_team_cycle() from public,anon,authenticated;

alter table public.pot_player_team_cycles enable row level security;
revoke all on public.pot_player_team_cycles from public,anon,authenticated;
grant select on public.pot_player_team_cycles to authenticated;
create policy "Players can view their team cycles" on public.pot_player_team_cycles for select to authenticated
using(player_id=(select auth.uid()) or (select public.is_current_user_admin()));

do $$ declare definition text; original text; begin
 definition:=pg_get_functiondef('public.confirm_team_pick(uuid,bigint,bigint)'::regprocedure); original:=definition;
 definition:=replace(definition,'and player_id = ( SELECT auth.uid() AS uid ) AND team_id = selected_team_id','and player_id = ( SELECT auth.uid() AS uid ) AND team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) AND team_id = selected_team_id');
 definition:=replace(definition,'and player_id=(select auth.uid()) and team_id=selected_team_id','and player_id=(select auth.uid()) and team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) and team_id=selected_team_id');
 if definition=original or position('player_id=(select auth.uid()) and team_id=selected_team_id' in definition)>0 then raise exception 'Unexpected confirm_team_pick baseline'; end if;
 execute definition;

 definition:=pg_get_functiondef('public.assign_random_missing_picks(uuid,integer,boolean)'::regprocedure); original:=definition;
 definition:=replace(definition,'used.player_id = membership.player_id AND used.team_id = option_team.team_id','used.player_id = membership.player_id AND used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,membership.player_id) AND used.team_id = option_team.team_id');
 definition:=replace(definition,'used.player_id=membership.player_id and used.team_id=option_team.team_id','used.player_id=membership.player_id and used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,membership.player_id) and used.team_id=option_team.team_id');
 definition:=replace(definition,'used.player_id = membership.player_id AND used.team_id = option.team_id','used.player_id = membership.player_id AND used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,membership.player_id) AND used.team_id = option.team_id');
 definition:=replace(definition,'used.player_id=membership.player_id and used.team_id=option.team_id','used.player_id=membership.player_id and used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,membership.player_id) and used.team_id=option.team_id');
 if definition=original then raise exception 'Unexpected random-pick baseline'; end if; execute definition;

 definition:=pg_get_functiondef('public.get_pot_selection(uuid)'::regprocedure); original:=definition;
 definition:=replace(definition,'used.player_id = ( SELECT auth.uid() AS uid ) AND used.team_id =','used.player_id = ( SELECT auth.uid() AS uid ) AND used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) AND used.team_id =');
 definition:=replace(definition,'used.player_id=(select auth.uid()) and used.team_id=','used.player_id=(select auth.uid()) and used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) and used.team_id=');
 if definition=original then raise exception 'Unexpected selection baseline'; end if; execute definition;

 definition:=pg_get_functiondef('public.get_my_team_availability(uuid)'::regprocedure); original:=definition;
 definition:=replace(definition,'used.player_id = ( SELECT auth.uid() AS uid ) AND used.team_id =','used.player_id = ( SELECT auth.uid() AS uid ) AND used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) AND used.team_id =');
 definition:=replace(definition,'used.player_id=(select auth.uid()) and used.team_id=','used.player_id=(select auth.uid()) and used.team_cycle_id=public.current_team_cycle_id(selected_pot_id,(select auth.uid())) and used.team_id=');
 if definition=original then raise exception 'Unexpected availability baseline'; end if; execute definition;
end $$;

revoke all on function public.current_team_cycle_id(uuid,uuid) from public,anon,authenticated;
commit;
