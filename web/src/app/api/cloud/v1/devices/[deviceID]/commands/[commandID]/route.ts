import { requireCurrentAccount } from "@/lib/auth/current-account";
import { commandForOwnedDevice } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";
type RouteContext = { params: Promise<{ deviceID: string; commandID: string }> };
export async function GET(_request: Request, context: RouteContext) { try { const account = await requireCurrentAccount(); const { deviceID, commandID } = await context.params; const command = await commandForOwnedDevice(account.id, deviceID, commandID); return Response.json({ command: { id: command.id, status: command.status, result: command.result, createdAt: command.createdAt.toISOString(), acknowledgedAt: command.acknowledgedAt?.toISOString() ?? null } }, { headers: { "Cache-Control": "no-store" } }); } catch (error) { return jsonError(error); } }
