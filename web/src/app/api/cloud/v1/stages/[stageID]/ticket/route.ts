import { stageTicket } from "@/lib/cloud/staging";
import { verifyDeviceToken } from "@/lib/cloud/device-token";
type RouteContext = { params: Promise<{ stageID: string }> };
export async function POST(request: Request, context: RouteContext) {
  try { const value = request.headers.get("authorization"); if (!value?.startsWith("Bearer ")) throw new Error(); const verified = await verifyDeviceToken(value.slice(7)); const { stageID } = await context.params; return Response.json(await stageTicket(stageID, verified.payload.sub!), { headers: { "Cache-Control": "no-store" } }); }
  catch { return Response.json({ error: { code: "stage_not_ready", message: "Cloud stage is not ready." } }, { status: 409 }); }
}
