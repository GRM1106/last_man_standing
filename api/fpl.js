import { fetchFplData, ProviderError } from "../server/fpl-provider.js";

export default async function handler(_request,response){
  try{
    const data=await fetchFplData();
    response.setHeader("Cache-Control","s-maxage=900, stale-while-revalidate=3600");
    response.status(200).json(data);
  }catch(error){
    response.status(502).json({error:error instanceof ProviderError?error.message:"Could not reach the FPL feed."});
  }
}
