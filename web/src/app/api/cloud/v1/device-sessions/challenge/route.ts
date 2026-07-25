import { requireProtocolVersion } from "@/lib/cloud/device-contract";
import { createSessionChallenge } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";
export async function POST(request: Request) { try { const body = await requestBody(request); requireProtocolVersion(body.protocolVersion); if (typeof body.deviceID !== "string") throw new Error("Invalid device ID."); const { challenge } = await createSessionChallenge(body.deviceID); return Response.json({ protocolVersion: 1, challengeID: challenge.id, nonce: challenge.nonce, expiresAt: challenge.expiresAt.toISOString() }, { headers: { "Cache-Control": "no-store" } }); } catch (error) { return jsonError(error); } }
