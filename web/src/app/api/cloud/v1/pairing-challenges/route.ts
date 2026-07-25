import { requireCurrentAccount } from "@/lib/auth/current-account";
import { pairingCode, secretHash } from "@/lib/cloud/device-crypto";
import { createPairingChallenge } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";
import { enforceRateLimit } from "@/lib/cloud/rate-limit";
export async function POST() { try { const account = await requireCurrentAccount(true); await enforceRateLimit(`pairing:create:${account.id}`, 5, 3600); const code = pairingCode(); const challenge = await createPairingChallenge(account.id, secretHash(code.replace(/-/g, ""))); return Response.json({ protocolVersion: 1, challengeID: challenge.id, pairingCode: code, expiresAt: challenge.expiresAt.toISOString() }, { headers: { "Cache-Control": "no-store" } }); } catch (error) { return jsonError(error); } }
