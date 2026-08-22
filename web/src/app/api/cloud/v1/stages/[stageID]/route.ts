import { cancelStage, serializeStage, stageForDevice } from "@/lib/cloud/staging";
import { verifyDeviceToken } from "@/lib/cloud/device-token";
type RouteContext = { params: Promise<{ stageID: string }> };
async function identity(request: Request) { const value = request.headers.get("authorization"); if (!value?.startsWith("Bearer ")) throw new Error("unauthorized"); return verifyDeviceToken(value.slice(7)); }
export async function GET(request: Request, context: RouteContext) {
  try { const verified = await identity(request); const { stageID } = await context.params; return Response.json(serializeStage(await stageForDevice(stageID, verified.payload.sub!)), { headers: { "Cache-Control": "no-store" } }); }
  catch { return Response.json({ error: { code: "stage_not_found", message: "Cloud stage not found." } }, { status: 404 }); }
}
export async function DELETE(request: Request, context: RouteContext) {
  try { const verified = await identity(request); const { stageID } = await context.params; await cancelStage(stageID, verified.payload.sub!); return new Response(null, { status: 204 }); }
  catch { return Response.json({ error: { code: "stage_not_found", message: "Cloud stage not found." } }, { status: 404 }); }
}
