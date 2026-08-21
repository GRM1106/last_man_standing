const FPL_BASE_URL="https://fantasy.premierleague.com/api";

export default async function handler(_request,response){
  try{
    const [bootstrapResponse,fixturesResponse]=await Promise.all([
      fetch(`${FPL_BASE_URL}/bootstrap-static/`,{headers:{"user-agent":"GRM-LMS/1.0"}}),
      fetch(`${FPL_BASE_URL}/fixtures/`,{headers:{"user-agent":"GRM-LMS/1.0"}})
    ]);
    if(!bootstrapResponse.ok||!fixturesResponse.ok){
      response.status(502).json({error:"The FPL feed is temporarily unavailable."});
      return;
    }
    const [bootstrap,fixtures]=await Promise.all([bootstrapResponse.json(),fixturesResponse.json()]);
    const teams=bootstrap.teams.map(({id,code,name,short_name})=>({id,code,name,short_name}));
    const fixtureData=fixtures.map(({id,event,kickoff_time,team_h,team_a,team_h_score,team_a_score,started,finished,provisional_start_time})=>({id,event,kickoff_time,team_h,team_a,team_h_score,team_a_score,started,finished,provisional_start_time}));
    response.setHeader("Cache-Control","s-maxage=900, stale-while-revalidate=3600");
    response.status(200).json({teams,fixtures:fixtureData});
  }catch{
    response.status(502).json({error:"Could not reach the FPL feed."});
  }
}
