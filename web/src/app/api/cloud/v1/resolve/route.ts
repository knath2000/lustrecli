import { enforceRateLimit } from "@/lib/cloud/rate-limit";
import { DeviceContractError } from "@/lib/cloud/device-contract";
import { verifyDeviceToken } from "@/lib/cloud/device-token";
import { feedPlaybackResolutionSchema, resolveRequestSchema, type FeedPlaybackResolution } from "@/lib/lustre-watch/contracts";
import { errorResponse, resolverRequest } from "@/lib/lustre-watch/resolver";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  try {
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return Response.json({ error: { code: "unauthorized", message: "Device authentication is required." } }, { status: 401 });
    }
    let verified;
    try {
      verified = await verifyDeviceToken(authorization.slice(7));
    } catch {
      return Response.json({ error: { code: "unauthorized", message: "Device authentication is invalid." } }, { status: 401 });
    }
    const deviceID = verified.payload.sub!;
    await enforceRateLimit(`cloud-resolve:${deviceID}`, 30, 60);

    const input = resolveRequestSchema.safeParse(await request.json());
    if (!input.success) {
      return Response.json({ error: { code: "invalid_request", message: "A supported source URL is required." } }, { status: 400 });
    }
    const result = await resolverRequest<FeedPlaybackResolution>("/internal/resolve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input.data),
    });
    return Response.json(feedPlaybackResolutionSchema.parse(result), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (reason) {
    if (reason instanceof DeviceContractError && reason.code === "rate_limited") {
      return Response.json({ error: { code: "rate_limit", message: "Cloud extraction rate limit reached." } }, { status: 429 });
    }
    return errorResponse(reason);
  }
}
