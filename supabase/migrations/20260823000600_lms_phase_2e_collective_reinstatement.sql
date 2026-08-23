-- Phase 2E: atomic pre-GW38 collective reinstatement.
begin;
do $$ begin if to_regclass('public.fixture_selection_block_events') is null then raise exception 'Phase 2E requires Phase 2D'; end if;
 if to_regclass('public.round_collective_reinstatements') is not null then raise exception 'Phase 2E already installed'; end if; end $$;
alter table public.pot_round_players drop constraint pot_round_players_entry_reason_check;
alter table public.pot_round_players add constraint pot_round_players_entry_reason_check check(entry_reason in('normal','legacy_pick','collective_reinstatement'));
create table public.round_collective_reinstatements(
 id uuid primary key default gen_random_uuid(),pot_id uuid not null references public.pots(id),source_round_id uuid not null unique,
 destination_round_id uuid not null,cohort_count integer not null check(cohort_count>0),created_at timestamptz not null default now(),
 foreign key(source_round_id,pot_id) references public.pot_rounds(id,pot_id),foreign key(destination_round_id,pot_id) references public.pot_rounds(id,pot_id)
);
alter table public.round_collective_reinstatements enable row level security;
grant select on public.round_collective_reinstatements to authenticated;
create policy "Members can view collective reinstatements" on public.round_collective_reinstatements for select to authenticated using(
 exists(select 1 from public.pot_players m where m.pot_id=round_collective_reinstatements.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
revoke insert,update,delete on public.round_collective_reinstatements from public,anon,authenticated;

alter function public.process_pot_gameweek(uuid,integer,boolean) rename to process_pot_gameweek_phase2d_base;
revoke all on function public.process_pot_gameweek_phase2d_base(uuid,integer,boolean) from public,anon,authenticated;
create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; source_round public.pot_rounds%rowtype; destination_round public.pot_rounds%rowtype;
declare cohort_count integer; survivor_count integer; withdrawn_count integer; created_event uuid;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 result:=public.process_pot_gameweek_phase2d_base(selected_pot_id,selected_gameweek,apply_changes);
 if not apply_changes or not coalesce((result->>'processed')::boolean,false) then return result; end if;
 select * into source_round from public.pot_rounds where pot_id=selected_pot_id and gameweek_number=selected_gameweek for update;
 select count(*),count(*) filter(where p.outcome='won') into cohort_count,survivor_count
 from public.pot_round_players c join public.player_picks p on p.round_id=c.round_id and p.player_id=c.player_id where c.round_id=source_round.id;
 if selected_gameweek=38 or cohort_count=0 or survivor_count>0 then return result||jsonb_build_object('collective_reinstatement',false); end if;
 if exists(select 1 from public.round_collective_reinstatements where source_round_id=source_round.id) then
  return result||jsonb_build_object('collective_reinstatement',true,'already_applied',true); end if;
 select count(*) into withdrawn_count from public.pot_round_players c join public.pot_players m on m.pot_id=c.pot_id and m.player_id=c.player_id
 where c.round_id=source_round.id and m.player_status='withdrawn';
 select * into destination_round from public.pot_rounds where pot_id=selected_pot_id and gameweek_number=selected_gameweek+1 for update;
 if withdrawn_count>0 or not found then
  update public.pots set lifecycle_status='review',review_status='needs_review',review_reason=case when withdrawn_count>0
   then 'Collective reinstatement cohort contains a withdrawn player' else 'Next Premier League gameweek is unavailable for collective reinstatement' end,
   review_status_changed_at=now() where id=selected_pot_id;
  return result||jsonb_build_object('collective_reinstatement',false,'review_required',true); end if;
 if destination_round.cohort_finalized_at is not null then raise exception 'Destination LMS round cohort is already finalized'; end if;
 insert into public.round_collective_reinstatements(pot_id,source_round_id,destination_round_id,cohort_count)
 values(selected_pot_id,source_round.id,destination_round.id,cohort_count) returning id into created_event;
 update public.pot_players m set player_status='active' from public.pot_round_players c
 where c.round_id=source_round.id and m.pot_id=c.pot_id and m.player_id=c.player_id and m.player_status='eliminated';
 insert into public.pot_round_players(round_id,pot_id,player_id,entry_reason,entered_player_status)
 select destination_round.id,c.pot_id,c.player_id,'collective_reinstatement','active' from public.pot_round_players c where c.round_id=source_round.id
 on conflict(round_id,player_id) do nothing;
 update public.pots set lifecycle_status='in_progress' where id=selected_pot_id and lifecycle_status<>'complete';
 return result||jsonb_build_object('collective_reinstatement',true,'reinstated',cohort_count,
  'destination_gameweek',destination_round.gameweek_number,'event_id',created_event);
end $$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public,anon;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

alter function public.reset_test_gameweek(uuid,integer) rename to reset_test_gameweek_phase2d_base;
revoke all on function public.reset_test_gameweek_phase2d_base(uuid,integer) from public,anon,authenticated;
create or replace function public.reset_test_gameweek(selected_pot_id uuid,selected_gameweek integer)
returns void language plpgsql security definer set search_path='' as $$
declare event_record public.round_collective_reinstatements%rowtype;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select event.* into event_record from public.round_collective_reinstatements event join public.pot_rounds r on r.id=event.source_round_id
 where event.pot_id=selected_pot_id and r.gameweek_number=selected_gameweek;
 perform public.reset_test_gameweek_phase2d_base(selected_pot_id,selected_gameweek);
 if event_record.id is not null then
  delete from public.pot_round_players where round_id=event_record.destination_round_id and entry_reason='collective_reinstatement';
  delete from public.round_collective_reinstatements where id=event_record.id;
 end if;
end $$;
revoke all on function public.reset_test_gameweek(uuid,integer) from public,anon;
grant execute on function public.reset_test_gameweek(uuid,integer) to authenticated;
commit;
