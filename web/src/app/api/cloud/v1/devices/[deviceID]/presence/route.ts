import { requireCurrentAccount } from "@/lib/auth/current-account";
import { PRESENCE_FRESHNESS_SECONDS } from "@/lib/cloud/device-contract";
import { presenceForOwnedDevice } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";

export async function GET(_request: Request, context: { params: Promise<{ deviceID: string }> }) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const presence = await presenceForOwnedDevice(account.id, deviceID);
    const age = presence.lastHeartbeatAt ? Date.now() - presence.lastHeartbeatAt.getTime() : null;
    const state = presence.revokedAt ? "revoked" : !presence.lastHeartbeatAt ? "neverConnected" : age! <= PRESENCE_FRESHNESS_SECONDS * 1000 ? "online" : "offline";
    return Response.json({ state, lastSeenAt: presence.lastHeartbeatAt?.toISOString() ?? null, agentVersion: presence.agentVersion ?? null }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) { return jsonError(error); }
}
