-- Phase P1 intentional failure seed
-- Run only in a separately reset disposable Supabase database after all pre-P1
-- modules. It constructs a schema-valid ambiguity without weakening constraints.
-- Never run in production.

begin;

insert into public.football_teams(id,fpl_team_id,code,name,short_name)
values
  (-24901,-24901,-24901,'P1 Failure Shared Home','FSH'),
  (-24902,-24902,-24902,'P1 Failure Shared Away','FSA');

insert into public.football_fixtures(
  id,fpl_fixture_id,season,gameweek_number,home_team_id,away_team_id,started,finished,provisional_start_time
)
values
  (-25901,-25901,'P1-FAIL-A',1,-24901,-24902,false,false,false),
  (-25902,-25902,'P1-FAIL-B',1,-24901,-24902,false,false,false);

commit;
