-- Phase 2B: stable LMS round identity and immutable finalized cohorts.
begin;
do $$ begin
  if to_regprocedure('public.lock_pot_membership_if_due(uuid)') is null then raise exception 'Phase 2B requires Phase 2A'; end if;
  if to_regclass('public.pot_rounds') is not null or to_regclass('public.pot_round_players') is not null then raise exception 'Phase 2B is already installed'; end if;
  if exists(select 1 from public.player_picks p where not exists(select 1 from public.pot_gameweeks g where g.pot_id=p.pot_id and g.gameweek_number=p.gameweek_number))
    or exists(select 1 from public.pot_gameweek_processes x where not exists(select 1 from public.pot_gameweeks g where g.pot_id=x.pot_id and g.gameweek_number=x.gameweek_number)) then
    raise exception 'Phase 2B cannot map historical picks/processes outside the pot schedule';
  end if;
end $$;

create table public.pot_rounds(
  id uuid primary key default gen_random_uuid(), pot_id uuid not null references public.pots(id) on delete cascade,
  sequence_number integer not null check(sequence_number>0), gameweek_number integer not null check(gameweek_number between 1 and 38),
  cohort_finalized_at timestamptz, created_at timestamptz not null default now(),
  unique(pot_id,sequence_number), unique(pot_id,gameweek_number), unique(id,pot_id),
  foreign key(pot_id,gameweek_number) references public.pot_gameweeks(pot_id,gameweek_number)
);
create table public.pot_round_players(
  round_id uuid not null, pot_id uuid not null, player_id uuid not null,
  entry_reason text not null default 'normal' check(entry_reason in('normal','legacy_pick')),
  entered_player_status text not null check(entered_player_status in('active','eliminated','winner','withdrawn')),
  entered_at timestamptz not null default now(), primary key(round_id,player_id),
  foreign key(round_id,pot_id) references public.pot_rounds(id,pot_id) on delete cascade,
  foreign key(pot_id,player_id) references public.pot_players(pot_id,player_id),
  unique(round_id,pot_id,player_id)
);

insert into public.pot_rounds(pot_id,sequence_number,gameweek_number,created_at)
select g.pot_id,row_number() over(partition by g.pot_id order by g.gameweek_number),g.gameweek_number,g.created_at from public.pot_gameweeks g;
insert into public.pot_round_players(round_id,pot_id,player_id,entry_reason,entered_player_status,entered_at)
select distinct r.id,p.pot_id,p.player_id,'legacy_pick',m.player_status,p.confirmed_at
from public.player_picks p join public.pot_rounds r on r.pot_id=p.pot_id and r.gameweek_number=p.gameweek_number
join public.pot_players m on m.pot_id=p.pot_id and m.player_id=p.player_id;
update public.pot_rounds r set cohort_finalized_at=x.processed_at from(
  select pot_id,gameweek_number,min(processed_at) processed_at from public.pot_gameweek_processes group by pot_id,gameweek_number) x
where x.pot_id=r.pot_id and x.gameweek_number=r.gameweek_number;

create or replace function public.create_lms_round_for_gameweek() returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.pot_id::text),-2);
  insert into public.pot_rounds(pot_id,sequence_number,gameweek_number,created_at)
  values(new.pot_id,(select count(*)+1 from public.pot_rounds where pot_id=new.pot_id),new.gameweek_number,new.created_at);
  return new;
end $$;
create trigger pot_gameweeks_create_lms_round after insert on public.pot_gameweeks for each row execute function public.create_lms_round_for_gameweek();
revoke all on function public.create_lms_round_for_gameweek() from public,anon,authenticated;

alter table public.player_picks add column round_id uuid;
update public.player_picks p set round_id=r.id from public.pot_rounds r where r.pot_id=p.pot_id and r.gameweek_number=p.gameweek_number;
alter table public.player_picks alter column round_id set not null;
alter table public.player_picks add constraint player_picks_round_cohort_fk foreign key(round_id,pot_id,player_id)
  references public.pot_round_players(round_id,pot_id,player_id);
alter table public.player_picks add constraint player_picks_round_player_unique unique(round_id,player_id);

alter table public.pot_gameweek_processes add column round_id uuid;
update public.pot_gameweek_processes x set round_id=r.id from public.pot_rounds r where r.pot_id=x.pot_id and r.gameweek_number=x.gameweek_number;
alter table public.pot_gameweek_processes alter column round_id set not null;
alter table public.pot_gameweek_processes add constraint pot_gameweek_processes_round_fk foreign key(round_id,pot_id)
  references public.pot_rounds(id,pot_id);
alter table public.pot_gameweek_processes add constraint pot_gameweek_processes_round_unique unique(round_id);

create or replace function public.reject_finalized_cohort_mutation() returns trigger language plpgsql set search_path='' as $$
begin
  if exists(select 1 from public.pot_rounds where id=coalesce(old.round_id,new.round_id) and cohort_finalized_at is not null) then
    raise exception 'A finalized LMS round cohort is immutable';
  end if; return coalesce(new,old);
end $$;
create trigger pot_round_players_finalized_immutable before update or delete on public.pot_round_players
for each row execute function public.reject_finalized_cohort_mutation();
revoke all on function public.reject_finalized_cohort_mutation() from public,anon,authenticated;

create or replace function public.link_pick_to_lms_round() returns trigger language plpgsql security definer set search_path='' as $$
declare selected_round public.pot_rounds%rowtype; declare status_snapshot text;
begin
  select * into selected_round from public.pot_rounds where pot_id=new.pot_id and gameweek_number=new.gameweek_number;
  if not found then raise exception 'No LMS round maps to this pot gameweek'; end if;
  if new.round_id is not null and new.round_id<>selected_round.id then raise exception 'Pick round does not match its pot gameweek'; end if;
  select player_status into status_snapshot from public.pot_players where pot_id=new.pot_id and player_id=new.player_id;
  if not found then raise exception 'Player is not a pot entrant'; end if;
  if selected_round.cohort_finalized_at is not null and not exists(select 1 from public.pot_round_players where round_id=selected_round.id and player_id=new.player_id) then
    raise exception 'Player did not enter this finalized LMS round';
  end if;
  insert into public.pot_round_players(round_id,pot_id,player_id,entry_reason,entered_player_status)
  values(selected_round.id,new.pot_id,new.player_id,'normal',status_snapshot) on conflict(round_id,player_id) do nothing;
  new.round_id:=selected_round.id; return new;
end $$;
create trigger player_picks_link_lms_round before insert on public.player_picks for each row execute function public.link_pick_to_lms_round();
revoke all on function public.link_pick_to_lms_round() from public,anon,authenticated;

create or replace function public.link_process_to_lms_round() returns trigger language plpgsql security definer set search_path='' as $$
declare selected_round public.pot_rounds%rowtype;
begin
  select * into selected_round from public.pot_rounds where pot_id=new.pot_id and gameweek_number=new.gameweek_number for update;
  if not found then raise exception 'No LMS round maps to this pot gameweek'; end if;
  if new.round_id is not null and new.round_id<>selected_round.id then raise exception 'Process round does not match its pot gameweek'; end if;
  if not exists(select 1 from public.pot_round_players where round_id=selected_round.id) then raise exception 'LMS round cohort is empty'; end if;
  update public.pot_rounds set cohort_finalized_at=coalesce(cohort_finalized_at,now()) where id=selected_round.id;
  new.round_id:=selected_round.id; return new;
end $$;
create trigger pot_gameweek_processes_link_lms_round before insert on public.pot_gameweek_processes for each row execute function public.link_process_to_lms_round();
revoke all on function public.link_process_to_lms_round() from public,anon,authenticated;

alter table public.pot_rounds enable row level security; alter table public.pot_round_players enable row level security;
grant select on public.pot_rounds,public.pot_round_players to authenticated;
create policy "Members can view pot rounds" on public.pot_rounds for select to authenticated using(
  exists(select 1 from public.pot_players m where m.pot_id=pot_rounds.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
create policy "Members can view their round entries" on public.pot_round_players for select to authenticated using(
  player_id=(select auth.uid()) or (select public.is_current_user_admin()));
revoke insert,update,delete on public.pot_rounds,public.pot_round_players from public,anon,authenticated;

create or replace function public.get_pot_rounds(selected_pot_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) or (select public.is_current_user_admin())
then coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'sequence_number',r.sequence_number,'gameweek_number',r.gameweek_number,
 'cohort_finalized_at',r.cohort_finalized_at,'cohort_size',(select count(*) from public.pot_round_players c where c.round_id=r.id),
 'processed',exists(select 1 from public.pot_gameweek_processes x where x.round_id=r.id)) order by r.sequence_number) from public.pot_rounds r where r.pot_id=selected_pot_id),'[]'::jsonb)
else null end; $$;
revoke all on function public.get_pot_rounds(uuid) from public,anon; grant execute on function public.get_pot_rounds(uuid) to authenticated;
commit;
