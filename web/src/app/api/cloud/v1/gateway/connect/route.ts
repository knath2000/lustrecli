import { establishPresence } from "@/lib/cloud/device-repository";
import { requireGateway } from "@/lib/cloud/gateway";
import { jsonError, requestBody } from "@/lib/cloud/route";

export async function POST(request: Request) {
  try {
    requireGateway(request);
    const body = await requestBody(request);
    if (typeof body.deviceID !== "string" || typeof body.connectionID !== "string" || typeof body.agentVersion !== "string") throw new Error("Invalid gateway connection.");
    await establishPresence(body.deviceID, body.connectionID, body.agentVersion.slice(0, 80));
    return Response.json({ status: "connected" }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) { return jsonError(error); }
}
