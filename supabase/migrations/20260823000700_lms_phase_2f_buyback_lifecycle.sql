-- Phase 2F: one immutable buy-back entitlement, consumed by a timely request.
begin;
do $$ begin
 if to_regclass('public.round_collective_reinstatements') is null then raise exception 'Phase 2F requires Phase 2E'; end if;
 if to_regclass('public.pot_player_buyback_events') is not null then raise exception 'Phase 2F already installed'; end if;
end $$;

alter table public.pot_round_players drop constraint pot_round_players_entry_reason_check;
alter table public.pot_round_players add constraint pot_round_players_entry_reason_check
 check(entry_reason in('normal','legacy_pick','collective_reinstatement','buy_back'));

alter table public.pot_players drop constraint pot_players_buy_back_status_check;
alter table public.pot_players add column buy_back_source_round_id uuid references public.pot_rounds(id);
alter table public.pot_players add column buy_back_destination_round_id uuid references public.pot_rounds(id);
alter table public.pot_players add column buy_back_request_deadline timestamptz;
alter table public.pot_players add column buy_back_payment_status text not null default 'not_due'
 check(buy_back_payment_status in('not_due','pending','received','revoked'));
alter table public.pot_players add column buy_back_confirmed_at timestamptz;
alter table public.pot_players add column buy_back_confirmed_by uuid references public.profiles(id);
alter table public.pot_players add column buy_back_revoked_at timestamptz;
alter table public.pot_players add column buy_back_revoked_by uuid references public.profiles(id);
alter table public.pot_players add column buy_back_revoke_reason text;

update public.pot_players set
 buy_back_status=case buy_back_status when 'claimed' then 'requested' when 'used' then 'confirmed' when 'expired' then 'available' else buy_back_status end,
 buy_back_payment_status=case buy_back_status when 'claimed' then 'pending' when 'used' then 'received' else 'not_due' end,
 buy_back_used_at=case when buy_back_status='claimed' then coalesce(buy_back_claimed_at,joined_at) else buy_back_used_at end,
 buy_back_claimed_at=case when buy_back_status in('claimed','used') then coalesce(buy_back_claimed_at,buy_back_used_at,joined_at) else buy_back_claimed_at end,
 buy_back_confirmed_at=case when buy_back_status='used' then coalesce(buy_back_used_at,buy_back_claimed_at,joined_at) end;
alter table public.pot_players add constraint pot_players_buy_back_status_check
 check(buy_back_status in('available','requested','confirmed','revoked'));
alter table public.pot_players add constraint pot_players_buy_back_lifecycle_check check(
 (buy_back_status='available' and buy_back_used_at is null and buy_back_payment_status='not_due') or
 (buy_back_status='requested' and buy_back_claimed_at is not null and buy_back_used_at is not null and buy_back_payment_status='pending') or
 (buy_back_status='confirmed' and buy_back_claimed_at is not null and buy_back_used_at is not null and buy_back_payment_status='received' and buy_back_confirmed_at is not null) or
 (buy_back_status='revoked' and buy_back_claimed_at is not null and buy_back_used_at is not null and buy_back_payment_status='revoked' and buy_back_revoked_at is not null and nullif(trim(buy_back_revoke_reason),'') is not null));

create table public.pot_player_buyback_events(
 id uuid primary key default gen_random_uuid(), pot_id uuid not null, player_id uuid not null,
 event_type text not null check(event_type in('legacy_requested','legacy_confirmed','requested','confirmed','revoked')),
 source_round_id uuid references public.pot_rounds(id), destination_round_id uuid references public.pot_rounds(id),
 request_deadline timestamptz, actor_id uuid references public.profiles(id), reason text,
 occurred_at timestamptz not null default now(), metadata jsonb not null default '{}'::jsonb,
 foreign key(pot_id,player_id) references public.pot_players(pot_id,player_id)
);
create unique index pot_player_buyback_one_consumption on public.pot_player_buyback_events(pot_id,player_id)
 where event_type in('legacy_requested','legacy_confirmed','requested');
alter table public.pot_player_buyback_events enable row level security;
revoke all on public.pot_player_buyback_events from public,anon,authenticated;
grant select on public.pot_player_buyback_events to authenticated;
create policy "Players see own buy-back events" on public.pot_player_buyback_events for select to authenticated
 using(player_id=(select auth.uid()) or (select public.is_current_user_admin()));

insert into public.pot_player_buyback_events(pot_id,player_id,event_type,actor_id,occurred_at,metadata)
select pot_id,player_id,case buy_back_status when 'requested' then 'legacy_requested' else 'legacy_confirmed' end,
 case when buy_back_status='requested' then player_id end,coalesce(buy_back_claimed_at,buy_back_used_at,joined_at),
 jsonb_build_object('backfill',true,'timestamp_provenance',case when buy_back_claimed_at is not null then 'buy_back_claimed_at' when buy_back_used_at is not null then 'buy_back_used_at' else 'joined_at_fallback' end)
from public.pot_players where buy_back_status in('requested','confirmed');

create or replace function public.prevent_buyback_event_mutation() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from public.pots where id=old.pot_id and status='draft' and test_mode) then return old; end if;
 raise exception 'Buy-back event history is append-only';
end $$;
create trigger pot_player_buyback_events_append_only before update or delete on public.pot_player_buyback_events
 for each row execute function public.prevent_buyback_event_mutation();
revoke all on function public.prevent_buyback_event_mutation() from public,anon,authenticated;

create or replace function public.claim_buy_back(selected_pot_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare membership public.pot_players%rowtype; source_round public.pot_rounds%rowtype; destination_round public.pot_rounds%rowtype; deadline timestamptz; requested_at timestamptz:=clock_timestamp();
begin
 select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()) for update;
 if not found then raise exception 'You are not assigned to this pot'; end if;
 if membership.player_status<>'eliminated' then raise exception 'Buy-back is only available after elimination'; end if;
 if membership.buy_back_status<>'available' or membership.buy_back_used_at is not null then raise exception 'Your one-time buy-back has already been used'; end if;
 select r.* into source_round from public.pot_rounds r join public.pot_round_players c on c.round_id=r.id and c.player_id=membership.player_id
 join public.player_picks p on p.round_id=r.id and p.player_id=c.player_id and p.outcome='lost'
 where r.pot_id=selected_pot_id order by r.sequence_number desc limit 1;
 if not found then raise exception 'No elimination result was found'; end if;
 select * into destination_round from public.pot_rounds where pot_id=selected_pot_id and sequence_number>source_round.sequence_number order by sequence_number limit 1;
 if not found then raise exception 'No next LMS round is available; the entitlement remains unused'; end if;
 select pick_deadline_at into deadline from public.pot_gameweeks where pot_id=selected_pot_id and gameweek_number=destination_round.gameweek_number for update;
 if deadline is null then raise exception 'The next round deadline is not available yet'; end if;
 if requested_at>=deadline then raise exception 'The buy-back window closed at %',deadline; end if;
 if destination_round.cohort_finalized_at is not null then raise exception 'The next LMS round cohort is already finalized'; end if;
 insert into public.pot_player_buyback_events(pot_id,player_id,event_type,source_round_id,destination_round_id,request_deadline,actor_id,occurred_at)
 values(selected_pot_id,membership.player_id,'requested',source_round.id,destination_round.id,deadline,membership.player_id,requested_at);
 update public.pot_players set player_status='active',buy_back_status='requested',buy_back_claimed_at=requested_at,buy_back_used_at=requested_at,
  buy_back_source_round_id=source_round.id,buy_back_destination_round_id=destination_round.id,buy_back_request_deadline=deadline,buy_back_payment_status='pending'
 where pot_id=selected_pot_id and player_id=membership.player_id;
 insert into public.pot_round_players(round_id,pot_id,player_id,entry_reason,entered_player_status)
 values(destination_round.id,selected_pot_id,membership.player_id,'buy_back','active') on conflict(round_id,player_id) do nothing;
end $$;
revoke all on function public.claim_buy_back(uuid) from public,anon;
grant execute on function public.claim_buy_back(uuid) to authenticated;

create or replace function public.confirm_buy_back(selected_pot_id uuid,selected_player_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare membership public.pot_players%rowtype;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=selected_player_id for update;
 if not found then raise exception 'Pot player not found'; end if;
 if membership.buy_back_status='confirmed' then return; end if;
 if membership.buy_back_status<>'requested' then raise exception 'This player has no pending buy-back request'; end if;
 update public.pot_players set buy_back_status='confirmed',buy_back_payment_status='received',buy_back_confirmed_at=now(),buy_back_confirmed_by=(select auth.uid())
 where pot_id=selected_pot_id and player_id=selected_player_id;
 insert into public.pot_player_buyback_events(pot_id,player_id,event_type,source_round_id,destination_round_id,request_deadline,actor_id)
 values(selected_pot_id,selected_player_id,'confirmed',membership.buy_back_source_round_id,membership.buy_back_destination_round_id,membership.buy_back_request_deadline,(select auth.uid()));
end $$;
revoke all on function public.confirm_buy_back(uuid,uuid) from public,anon;
grant execute on function public.confirm_buy_back(uuid,uuid) to authenticated;

create or replace function public.revoke_buy_back(selected_pot_id uuid,selected_player_id uuid,revoke_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare membership public.pot_players%rowtype; destination public.pot_rounds%rowtype; downstream boolean; event_id uuid;
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if nullif(trim(revoke_reason),'') is null or char_length(trim(revoke_reason))<5 then raise exception 'A meaningful revocation reason is required'; end if;
 select * into membership from public.pot_players where pot_id=selected_pot_id and player_id=selected_player_id for update;
 if not found then raise exception 'Pot player not found'; end if;
 if membership.buy_back_status='revoked' then return jsonb_build_object('revoked',true,'already_applied',true); end if;
 if membership.buy_back_status not in('requested','confirmed') then raise exception 'This player has no consumed buy-back to revoke'; end if;
 select * into destination from public.pot_rounds where id=membership.buy_back_destination_round_id for update;
 downstream:=destination.cohort_finalized_at is not null or exists(select 1 from public.player_picks where round_id=destination.id and player_id=selected_player_id);
 update public.pot_players set buy_back_status='revoked',buy_back_payment_status='revoked',buy_back_revoked_at=now(),buy_back_revoked_by=(select auth.uid()),buy_back_revoke_reason=trim(revoke_reason),
  player_status=case when downstream then player_status else 'eliminated' end where pot_id=selected_pot_id and player_id=selected_player_id;
 if not downstream then delete from public.pot_round_players where round_id=destination.id and player_id=selected_player_id and entry_reason='buy_back';
 else update public.pots set lifecycle_status='review',review_status='needs_review',review_reason='A buy-back was revoked after downstream participation; adjudication is required',review_status_changed_at=now() where id=selected_pot_id; end if;
 insert into public.pot_player_buyback_events(pot_id,player_id,event_type,source_round_id,destination_round_id,request_deadline,actor_id,reason,metadata)
 values(selected_pot_id,selected_player_id,'revoked',membership.buy_back_source_round_id,membership.buy_back_destination_round_id,membership.buy_back_request_deadline,(select auth.uid()),trim(revoke_reason),jsonb_build_object('downstream_review',downstream)) returning id into event_id;
 return jsonb_build_object('revoked',true,'review_required',downstream,'event_id',event_id);
end $$;
revoke all on function public.revoke_buy_back(uuid,uuid,text) from public,anon;
grant execute on function public.revoke_buy_back(uuid,uuid,text) to authenticated;

create or replace function public.set_buy_back_decision(selected_pot_id uuid,selected_player_id uuid,approved boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not approved then raise exception 'Use revoke_buy_back with an explicit reason'; end if;
 perform public.confirm_buy_back(selected_pot_id,selected_player_id);
end $$;
revoke all on function public.set_buy_back_decision(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_buy_back_decision(uuid,uuid,boolean) to authenticated;

alter function public.reset_draft_test_pot(uuid) rename to reset_draft_test_pot_phase2e_base;
revoke all on function public.reset_draft_test_pot_phase2e_base(uuid) from public,anon,authenticated;
create or replace function public.reset_draft_test_pot(selected_pot_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then raise exception 'Only a draft pot in test mode can be reset'; end if;
 delete from public.pot_player_buyback_events where pot_id=selected_pot_id;
 delete from public.pot_round_players where pot_id=selected_pot_id and entry_reason='buy_back' and not exists(select 1 from public.player_picks p where p.round_id=pot_round_players.round_id and p.player_id=pot_round_players.player_id);
 update public.pot_players set buy_back_status='available',buy_back_claimed_at=null,buy_back_used_at=null,buy_back_source_round_id=null,buy_back_destination_round_id=null,
 buy_back_request_deadline=null,buy_back_payment_status='not_due',buy_back_confirmed_at=null,buy_back_confirmed_by=null,buy_back_revoked_at=null,buy_back_revoked_by=null,buy_back_revoke_reason=null where pot_id=selected_pot_id;
 perform public.reset_draft_test_pot_phase2e_base(selected_pot_id);
 delete from public.pot_round_players where pot_id=selected_pot_id and entry_reason='buy_back';
end $$;
revoke all on function public.reset_draft_test_pot(uuid) from public,anon;
grant execute on function public.reset_draft_test_pot(uuid) to authenticated;

create or replace function public.get_my_dashboard() returns jsonb language sql stable security definer set search_path='' as $$
 with player as(select id,email,first_name,approved from public.profiles where id=(select auth.uid()))
 select jsonb_build_object('approved',coalesce(player.approved,false),'email',player.email,'first_name',player.first_name,
  'pots',coalesce((select jsonb_agg(jsonb_build_object('id',pot.id,'name',pot.name,'season',pot.season,'status',pot.status,
   'lifecycle_status',pot.lifecycle_status,'membership_locked_at',pot.membership_locked_at,'entry_fee_pence',pot.entry_fee_pence,
   'buy_back_fee_pence',pot.buy_back_fee_pence,'player_status',membership.player_status,'payment_status',membership.payment_status,
   'buy_back_status',case when membership.buy_back_status='available' and membership.player_status='eliminated' and next_round.deadline is not null and now()>=next_round.deadline then 'window_closed' else membership.buy_back_status end,
   'buy_back_entitlement_available',membership.buy_back_status='available','buy_back_payment_status',membership.buy_back_payment_status,
   'buy_back_requested_at',membership.buy_back_claimed_at,'buy_back_deadline',case when membership.buy_back_status='available' then next_round.deadline else membership.buy_back_request_deadline end,
   'gameweeks',coalesce((select jsonb_agg(g.gameweek_number order by g.gameweek_number) from public.pot_gameweeks g where g.pot_id=pot.id),'[]'::jsonb)) order by pot.created_at desc)
  from public.pot_players membership join public.pots pot on pot.id=membership.pot_id
  left join lateral(select g.pick_deadline_at deadline from public.pot_rounds r join public.pot_gameweeks g on g.pot_id=r.pot_id and g.gameweek_number=r.gameweek_number
   where r.pot_id=pot.id and r.sequence_number>(select coalesce(max(lost.sequence_number),0) from public.pot_rounds lost join public.player_picks p on p.round_id=lost.id where p.player_id=membership.player_id and p.outcome='lost')
   order by r.sequence_number limit 1) next_round on true where membership.player_id=player.id),'[]'::jsonb)) from player;
$$;
revoke all on function public.get_my_dashboard() from public,anon;
grant execute on function public.get_my_dashboard() to authenticated;

commit;
