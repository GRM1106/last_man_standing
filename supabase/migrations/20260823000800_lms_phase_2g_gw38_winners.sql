-- Phase 2G: terminal GW38 winner sets and immutable integer-pence prize shares.
begin;
do $$ begin
 if to_regclass('public.pot_player_buyback_events') is null then raise exception 'Phase 2G requires Phase 2F'; end if;
 if to_regclass('public.pot_completions') is not null then raise exception 'Phase 2G already installed'; end if;
end $$;

create table public.pot_completions(
 pot_id uuid primary key references public.pots(id), round_id uuid not null references public.pot_rounds(id),
 gameweek_number integer not null check(gameweek_number=38), resolution_rule text not null check(resolution_rule in('gw38_survivors','gw38_all_lost_split','gw38_buyback_eligible_split')),
 entry_contribution_pence integer not null check(entry_contribution_pence>=0), buyback_contribution_pence integer not null check(buyback_contribution_pence>=0),
 total_prize_pence integer not null check(total_prize_pence=entry_contribution_pence+buyback_contribution_pence), winner_count integer not null check(winner_count>0),
 completed_by uuid not null references public.profiles(id), completed_at timestamptz not null default now()
);
create table public.pot_winners(
 pot_id uuid not null references public.pot_completions(pot_id), player_id uuid not null, round_id uuid not null references public.pot_rounds(id),
 winner_reason text not null check(winner_reason in('gw38_survivor','gw38_all_lost_split','gw38_buyback_eligible_split')),
 prize_share_pence integer not null check(prize_share_pence>=0), share_order integer not null check(share_order>0), created_at timestamptz not null default now(),
 primary key(pot_id,player_id), unique(pot_id,share_order), foreign key(pot_id,player_id) references public.pot_players(pot_id,player_id)
);
alter table public.pot_completions enable row level security; alter table public.pot_winners enable row level security;
grant select on public.pot_completions,public.pot_winners to authenticated;
create policy "Members see pot completion" on public.pot_completions for select to authenticated using(exists(select 1 from public.pot_players m where m.pot_id=pot_completions.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
create policy "Members see pot winners" on public.pot_winners for select to authenticated using(exists(select 1 from public.pot_players m where m.pot_id=pot_winners.pot_id and m.player_id=(select auth.uid())) or (select public.is_current_user_admin()));
revoke insert,update,delete on public.pot_completions,public.pot_winners from public,anon,authenticated;

create or replace function public.prevent_completion_mutation() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from public.pots where id=coalesce(old.pot_id,new.pot_id) and status='draft' and test_mode) then return coalesce(new,old); end if;
 raise exception 'Completed winner and prize history is immutable';
end $$;
create trigger pot_completions_immutable before update or delete on public.pot_completions for each row execute function public.prevent_completion_mutation();
create trigger pot_winners_immutable before update or delete on public.pot_winners for each row execute function public.prevent_completion_mutation();
revoke all on function public.prevent_completion_mutation() from public,anon,authenticated;

create or replace function public.finalize_gw38_pot(selected_pot_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare selected_pot public.pots%rowtype; final_round public.pot_rounds%rowtype; cohort_count integer; survivor_count integer; available_count integer;
declare winners integer; entry_value integer; buyback_value integer; total_value integer; base_share integer; remainder integer; rule text; completion_time timestamptz:=clock_timestamp();
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 perform pg_advisory_xact_lock(hashtext(selected_pot_id::text),38);
 if exists(select 1 from public.pot_completions where pot_id=selected_pot_id) then
  return (select jsonb_build_object('completed',true,'already_finalized',true,'winner_count',winner_count,'total_prize_pence',total_prize_pence,'resolution_rule',resolution_rule) from public.pot_completions where pot_id=selected_pot_id);
 end if;
 select * into selected_pot from public.pots where id=selected_pot_id for update;
 if not found then raise exception 'Pot not found'; end if;
 if selected_pot.review_status='needs_review' or selected_pot.lifecycle_status='review' then return jsonb_build_object('completed',false,'review_required',true,'reason',coalesce(selected_pot.review_reason,'Unresolved governed review')); end if;
 select * into final_round from public.pot_rounds where pot_id=selected_pot_id and gameweek_number=38 for update;
 if not found then raise exception 'GW38 is not part of this pot'; end if;
 if not exists(select 1 from public.pot_gameweek_processes where round_id=final_round.id) then raise exception 'GW38 has not been processed'; end if;
 select count(*),count(*) filter(where p.outcome='won'),count(*) filter(where m.buy_back_status='available') into cohort_count,survivor_count,available_count
 from public.pot_round_players c join public.player_picks p on p.round_id=c.round_id and p.player_id=c.player_id join public.pot_players m on m.pot_id=c.pot_id and m.player_id=c.player_id where c.round_id=final_round.id;
 if cohort_count=0 then raise exception 'GW38 cohort is empty'; end if;
 if survivor_count>0 then rule:='gw38_survivors'; winners:=survivor_count;
 elsif available_count=0 or available_count=cohort_count then rule:='gw38_all_lost_split'; winners:=cohort_count;
 else rule:='gw38_buyback_eligible_split'; winners:=available_count; end if;
 select count(*) filter(where payment_status='paid')*selected_pot.entry_fee_pence,
  count(*) filter(where buy_back_payment_status='received')*selected_pot.buy_back_fee_pence into entry_value,buyback_value from public.pot_players where pot_id=selected_pot_id;
 total_value:=entry_value+buyback_value; base_share:=total_value/winners; remainder:=total_value%winners;
 insert into public.pot_completions(pot_id,round_id,gameweek_number,resolution_rule,entry_contribution_pence,buyback_contribution_pence,total_prize_pence,winner_count,completed_by,completed_at)
 values(selected_pot_id,final_round.id,38,rule,entry_value,buyback_value,total_value,winners,(select auth.uid()),completion_time);
 insert into public.pot_winners(pot_id,player_id,round_id,winner_reason,prize_share_pence,share_order,created_at)
 select selected_pot_id,x.player_id,final_round.id,case rule when 'gw38_survivors' then 'gw38_survivor' when 'gw38_all_lost_split' then 'gw38_all_lost_split' else 'gw38_buyback_eligible_split' end,
  base_share+case when x.ord<=remainder then 1 else 0 end,x.ord,completion_time from(
   select c.player_id,row_number() over(order by m.joined_at,c.player_id)::integer ord from public.pot_round_players c join public.pot_players m on m.pot_id=c.pot_id and m.player_id=c.player_id
   join public.player_picks p on p.round_id=c.round_id and p.player_id=c.player_id where c.round_id=final_round.id and
    ((survivor_count>0 and p.outcome='won') or (survivor_count=0 and (available_count in(0,cohort_count) or m.buy_back_status='available')))
  ) x;
 update public.pot_players m set player_status=case when exists(select 1 from public.pot_winners w where w.pot_id=selected_pot_id and w.player_id=m.player_id) then 'winner' else 'eliminated' end where m.pot_id=selected_pot_id and m.player_status<>'withdrawn';
 update public.pots set status=case when selected_pot.test_mode then 'draft' else 'complete' end,lifecycle_status='complete' where id=selected_pot_id;
 return jsonb_build_object('completed',true,'winner_count',winners,'total_prize_pence',total_value,'resolution_rule',rule);
end $$;
revoke all on function public.finalize_gw38_pot(uuid) from public,anon,authenticated;

alter function public.process_pot_gameweek(uuid,integer,boolean) rename to process_pot_gameweek_phase2f_base;
revoke all on function public.process_pot_gameweek_phase2f_base(uuid,integer,boolean) from public,anon,authenticated;
create or replace function public.process_pot_gameweek(selected_pot_id uuid,selected_gameweek integer,apply_changes boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; completion jsonb;
begin
 if selected_gameweek=38 and exists(select 1 from public.pot_completions where pot_id=selected_pot_id) then return public.finalize_gw38_pot(selected_pot_id); end if;
 if selected_gameweek=38 and exists(select 1 from public.pots where id=selected_pot_id and (review_status='needs_review' or lifecycle_status='review')) then
  return jsonb_build_object('ready',false,'processed',false,'review_required',true,'problems',jsonb_build_array('Unresolved governed review blocks GW38 finalization.'));
 end if;
 result:=public.process_pot_gameweek_phase2f_base(selected_pot_id,selected_gameweek,apply_changes);
 if selected_gameweek=38 and apply_changes and coalesce((result->>'processed')::boolean,false) then completion:=public.finalize_gw38_pot(selected_pot_id); return result||completion; end if;
 return result;
end $$;
revoke all on function public.process_pot_gameweek(uuid,integer,boolean) from public,anon;
grant execute on function public.process_pot_gameweek(uuid,integer,boolean) to authenticated;

create or replace function public.get_pot_completion(selected_pot_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) or (select public.is_current_user_admin()) then
 coalesce((select jsonb_build_object('pot_id',c.pot_id,'gameweek_number',38,'resolution_rule',c.resolution_rule,'entry_contribution_pence',c.entry_contribution_pence,
 'buyback_contribution_pence',c.buyback_contribution_pence,'total_prize_pence',c.total_prize_pence,'winner_count',c.winner_count,'completed_at',c.completed_at,
 'winners',(select jsonb_agg(jsonb_build_object('player_id',w.player_id,'name',coalesce(nullif(trim(concat_ws(' ',p.first_name,p.last_name)),''),p.display_name,p.email),'prize_share_pence',w.prize_share_pence,'winner_reason',w.winner_reason,'is_me',w.player_id=(select auth.uid())) order by w.share_order) from public.pot_winners w join public.profiles p on p.id=w.player_id where w.pot_id=c.pot_id)) from public.pot_completions c where c.pot_id=selected_pot_id),'null'::jsonb) else null end;
$$;
revoke all on function public.get_pot_completion(uuid) from public,anon; grant execute on function public.get_pot_completion(uuid) to authenticated;

create or replace function public.complete_pot_with_winner(selected_pot_id uuid,selected_winner_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.pots where id=selected_pot_id and test_mode) then raise exception 'A pot in test mode cannot be completed'; end if;
 raise exception 'Winner completion is determined by processing GW38';
end $$;
revoke all on function public.complete_pot_with_winner(uuid,uuid) from public,anon;
grant execute on function public.complete_pot_with_winner(uuid,uuid) to authenticated;

alter function public.reset_draft_test_pot(uuid) rename to reset_draft_test_pot_phase2f_base;
revoke all on function public.reset_draft_test_pot_phase2f_base(uuid) from public,anon,authenticated;
create or replace function public.reset_draft_test_pot(selected_pot_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
 if not exists(select 1 from public.pots where id=selected_pot_id and status='draft' and test_mode) then raise exception 'Only a draft pot in test mode can be reset'; end if;
 delete from public.pot_winners where pot_id=selected_pot_id; delete from public.pot_completions where pot_id=selected_pot_id;
 update public.pots set lifecycle_status='setup' where id=selected_pot_id;
 perform public.reset_draft_test_pot_phase2f_base(selected_pot_id);
end $$;
revoke all on function public.reset_draft_test_pot(uuid) from public,anon; grant execute on function public.reset_draft_test_pot(uuid) to authenticated;

commit;
