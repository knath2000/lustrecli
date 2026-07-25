import { requireCurrentAccount } from "@/lib/auth/current-account";
import { validateDisplayName } from "@/lib/cloud/device-contract";
import { renameDevice, revokeDevice } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";
export async function PATCH(request: Request, context: RouteContext<"/api/cloud/v1/devices/[deviceID]">) { try { const account = await requireCurrentAccount(); const { deviceID } = await context.params; const device = await renameDevice(account.id, deviceID, validateDisplayName((await requestBody(request)).displayName)); return Response.json({ device: { id: device.id, displayName: device.displayName } }); } catch (error) { return jsonError(error); } }
export async function DELETE(_request: Request, context: RouteContext<"/api/cloud/v1/devices/[deviceID]">) { try { const account = await requireCurrentAccount(); const { deviceID } = await context.params; await revokeDevice(account.id, deviceID); return new Response(null, { status: 204 }); } catch (error) { return jsonError(error); } }
