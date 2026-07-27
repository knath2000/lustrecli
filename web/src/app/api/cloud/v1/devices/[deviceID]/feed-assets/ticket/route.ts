import { requireCurrentAccount } from "@/lib/auth/current-account";
import { recentCompletedFeedPageResults } from "@/lib/cloud/device-repository";
import { createFeedAssetTicketHandler } from "@/lib/cloud/feed-asset-ticket";
import { jsonError } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

const handle = createFeedAssetTicketHandler({
  currentAccount: requireCurrentAccount,
  recentResults: recentCompletedFeedPageResults,
});

export async function POST(request: Request, context: RouteContext) {
  try {
    const { deviceID } = await context.params;
    return await handle(request, deviceID);
  } catch (error) {
    return jsonError(error);
  }
}
