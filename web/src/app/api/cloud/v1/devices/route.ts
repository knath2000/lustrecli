import { requireCurrentAccount } from "@/lib/auth/current-account";
import { listDevices } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";
export async function GET() { try { const account = await requireCurrentAccount(); const devices = await listDevices(account.id); return Response.json({ devices: devices.map((device) => ({ ...device, createdAt: device.createdAt.toISOString(), lastAuthenticatedAt: device.lastAuthenticatedAt?.toISOString() ?? null, revokedAt: device.revokedAt?.toISOString() ?? null })) }, { headers: { "Cache-Control": "no-store" } }); } catch (error) { return jsonError(error); } }
