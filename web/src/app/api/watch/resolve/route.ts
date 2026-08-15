import { feedPlaybackResolutionSchema, resolveRequestSchema, type FeedPlaybackResolution } from "@/lib/lustre-watch/contracts";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { errorResponse, resolverRequest } from "@/lib/lustre-watch/resolver";

export async function POST(request: Request) {
  try {
    await watchAccountID();
    const input = resolveRequestSchema.safeParse(await request.json());
    if (!input.success) return Response.json({ error: { code: "invalid_request", message: "A supported source URL is required." } }, { status: 400 });
    const result = await resolverRequest<FeedPlaybackResolution>("/internal/resolve", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(input.data) });
    return Response.json(feedPlaybackResolutionSchema.parse(result));
  } catch (reason) { return errorResponse(reason); }
}
