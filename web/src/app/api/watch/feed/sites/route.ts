import type { FeedSite } from "@/lib/lustre-watch/contracts";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { errorResponse, resolverRequest } from "@/lib/lustre-watch/resolver";

export async function GET() {
  try {
    await watchAccountID();
    return Response.json(await resolverRequest<FeedSite[]>("/internal/feed/sites"));
  } catch (reason) { return errorResponse(reason); }
}
