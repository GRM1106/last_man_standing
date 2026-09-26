-- Member-facing names must not reveal the contact email used as a fallback by
-- the signup trigger. Keep real names/nicknames and administrator email fields.
begin;
create function public.lms_player_display_name(first_name text, last_name text, display_name text, email text)
returns text language sql immutable set search_path='' as $$
  select coalesce(
    nullif(trim(concat_ws(' ',first_name,last_name)),''),
    case when lower(trim(display_name)) is distinct from lower(trim(email))
      then nullif(trim(display_name),'') end,
    'Player'
  );
$$;
revoke execute on function public.lms_player_display_name(text,text,text,text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_pot_standings(selected_pot_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; declare viewer_is_admin boolean;
begin
  viewer_is_admin:=(select public.is_current_user_admin());
  if not viewer_is_admin and not exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) then raise exception 'You are not assigned to this pot'; end if;
  if not exists(select 1 from public.pots where id=selected_pot_id) then raise exception 'Pot not found'; end if;
  select jsonb_build_object('pot_id',pot.id,'pot_name',pot.name,'season',pot.season,'status',pot.status,
    'current_gameweek',coalesce(
      (select min(gameweek.gameweek_number) from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id and not exists(select 1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id and processed.gameweek_number=gameweek.gameweek_number)),
      (select max(gameweek.gameweek_number) from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id)),
    'gameweeks',coalesce((select jsonb_agg(visible_gameweek.gameweek_number order by visible_gameweek.gameweek_number) from (
      select gameweek.gameweek_number from public.pot_gameweeks gameweek where gameweek.pot_id=pot.id order by gameweek.gameweek_number
      limit greatest(5,(select count(*)+1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id))
    ) visible_gameweek),'[]'::jsonb),
    'players',coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',public.lms_player_display_name(profile.first_name,profile.last_name,profile.display_name,profile.email),
      'email',case when viewer_is_admin then profile.email else null end,'player_status',membership.player_status,
      'payment_status',case when viewer_is_admin then membership.payment_status else null end,'buy_back_status',case when viewer_is_admin then membership.buy_back_status else null end,
      'picks',coalesce((select jsonb_agg(jsonb_build_object('gameweek_number',pick.gameweek_number,'team_name',team.name,'short_name',team.short_name,
        'emblem_url',team.emblem_url,'selection_source',pick.selection_source,'outcome',pick.outcome) order by pick.gameweek_number)
        from public.player_picks pick join public.football_teams team on team.id=pick.team_id
        where pick.pot_id=pot.id and pick.player_id=membership.player_id and (viewer_is_admin
          or exists(select 1 from public.pot_gameweek_processes processed where processed.pot_id=pot.id and processed.gameweek_number=pick.gameweek_number)
          or now()>=(select min(fixture.kickoff_at) from public.football_fixtures fixture where fixture.season=pot.season and fixture.gameweek_number=pick.gameweek_number))),'[]'::jsonb)
    ) order by case membership.player_status when 'winner' then 0 when 'active' then 1 else 2 end,coalesce(profile.first_name,profile.display_name,profile.email))
    from public.pot_players membership join public.profiles profile on profile.id=membership.player_id where membership.pot_id=pot.id),'[]'::jsonb)
  ) into result from public.pots pot where pot.id=selected_pot_id;
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_pot_completion(selected_pot_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid())) or (select public.is_current_user_admin()) then
 coalesce((select jsonb_build_object('pot_id',c.pot_id,'gameweek_number',38,'resolution_rule',c.resolution_rule,'entry_contribution_pence',c.entry_contribution_pence,
 'buyback_contribution_pence',c.buyback_contribution_pence,'total_prize_pence',c.total_prize_pence,'winner_count',c.winner_count,'completed_at',c.completed_at,
 'winners',(select jsonb_agg(jsonb_build_object('player_id',w.player_id,'name',public.lms_player_display_name(p.first_name,p.last_name,p.display_name,p.email),'prize_share_pence',w.prize_share_pence,'winner_reason',w.winner_reason,'is_me',w.player_id=(select auth.uid())) order by w.share_order) from public.pot_winners w join public.profiles p on p.id=w.player_id where w.pot_id=c.pot_id)) from public.pot_completions c where c.pot_id=selected_pot_id),'null'::jsonb) else null end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_pot_review_outcome(selected_pot_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
select case when exists(select 1 from public.pot_players where pot_id=selected_pot_id and player_id=(select auth.uid()))
  or (select public.is_current_user_admin()) then (
    select jsonb_build_object('revision',a.revision_number,'decided_at',a.created_at,
      'total_prize_pence',a.original_total_prize_pence,'winners',coalesce((
        select jsonb_agg(jsonb_build_object(
          'name',public.lms_player_display_name(p.first_name,p.last_name,p.display_name,p.email),
          'is_me',w.player_id=(select auth.uid()),'prize_share_pence',w.prize_share_pence) order by w.share_order)
        from public.pot_adjudicated_winners w join public.profiles p on p.id=w.player_id
        where w.adjudication_id=a.id),'[]'::jsonb))
    from public.pot_completion_adjudications a where a.pot_id=selected_pot_id order by a.revision_number desc limit 1
  ) else null end;
$function$
;

commit;
