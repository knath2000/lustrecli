import { enforceRateLimit } from "@/lib/cloud/rate-limit";
import { createStage, serializeStage, verifyStagingToken } from "@/lib/cloud/staging";
import { verifyDeviceToken } from "@/lib/cloud/device-token";

async function device(request: Request) {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) throw new Error("unauthorized");
  return verifyDeviceToken(authorization.slice(7));
}

export async function POST(request: Request) {
  try {
    const verified = await device(request);
    const deviceID = verified.payload.sub!;
    const accountID = verified.payload.accountID as string;
    await enforceRateLimit(`cloud-stage:${deviceID}`, 10, 60);
    const body = await request.json();
    if (!body || typeof body.stagingToken !== "string" || body.stagingToken.length > 8192) return Response.json({ error: { code: "invalid_request", message: "A staging token is required." } }, { status: 400 });
    const claims = await verifyStagingToken(body.stagingToken, deviceID);
    return Response.json(serializeStage(await createStage(accountID, deviceID, claims)), { status: 202, headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    const code = error instanceof Error ? error.message : "staging_unavailable";
    const status = code === "unauthorized" ? 401 : code === "invalid_staging_token" ? 400 : code === "staging_disabled_or_quota" ? 409 : 502;
    return Response.json({ error: { code, message: "Cloud staging is unavailable; use local download." } }, { status });
  }
}
