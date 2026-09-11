-- 15 — Edit pot players and delete draft pots
-- Run once in the Supabase SQL Editor after buy_back_setup.sql.

create or replace function public.add_player_to_pot(selected_pot_id uuid,selected_player_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status in ('draft','open')) then
    raise exception 'Players can only be added while a pot is draft or open';
  end if;
  if not exists(select 1 from public.profiles where id=selected_player_id and approved) then
    raise exception 'Only approved players can be added';
  end if;
  insert into public.pot_players(pot_id,player_id) values(selected_pot_id,selected_player_id)
  on conflict(pot_id,player_id) do nothing;
end;
$$;
revoke all on function public.add_player_to_pot(uuid,uuid) from public;
grant execute on function public.add_player_to_pot(uuid,uuid) to authenticated;

create or replace function public.remove_player_from_pot(selected_pot_id uuid,selected_player_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id and status='draft') then
    raise exception 'Players can only be removed from a draft pot';
  end if;
  delete from public.player_picks where pot_id=selected_pot_id and player_id=selected_player_id;
  delete from public.pot_players where pot_id=selected_pot_id and player_id=selected_player_id;
  if not found then raise exception 'Player is not assigned to this pot'; end if;
end;
$$;
revoke all on function public.remove_player_from_pot(uuid,uuid) from public;
grant execute on function public.remove_player_from_pot(uuid,uuid) to authenticated;

create or replace function public.delete_draft_pot(selected_pot_id uuid,confirmation_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare selected_pot public.pots%rowtype;
begin
  if not (select public.is_current_user_admin()) then raise exception 'Administrator access required'; end if;
  select * into selected_pot from public.pots where id=selected_pot_id;
  if not found then raise exception 'Pot not found'; end if;
  if selected_pot.status<>'draft' then raise exception 'Only draft pots can be deleted'; end if;
  if confirmation_name<>selected_pot.name then raise exception 'Pot name confirmation did not match'; end if;
  delete from public.pots where id=selected_pot_id;
end;
$$;
revoke all on function public.delete_draft_pot(uuid,text) from public;
grant execute on function public.delete_draft_pot(uuid,text) to authenticated;
