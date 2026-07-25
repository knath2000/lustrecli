import { decodeBase64, DeviceContractError, normalizePairingCode, requireProtocolVersion, validateDisplayName } from "@/lib/cloud/device-contract";
import { publicKeyThumbprint, secretHash } from "@/lib/cloud/device-crypto";
import { beginEnrollment } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";
export async function POST(request: Request) {
  let stage = "parse";
  try {
    const body = await requestBody(request); requireProtocolVersion(body.protocolVersion); const point = decodeBase64(body.publicKey, 65, "publicKey"); if (point.length !== 65 || point[0] !== 4) throw new DeviceContractError("invalid_request", "Invalid public key."); const platform = body.platform === "macos" ? "macos" : null; if (!platform || typeof body.agentVersion !== "string" || body.agentVersion.length < 1 || body.agentVersion.length > 80) throw new DeviceContractError("invalid_request", "Invalid device metadata.");
    stage = "pairing_hash";
    const pairingCodeHash = secretHash(normalizePairingCode(String(body.pairingCode)));
    stage = "enrollment_store";
    const enrollment = await beginEnrollment({ pairingCodeHash, publicKey: String(body.publicKey), keyThumbprint: publicKeyThumbprint(point), displayName: validateDisplayName(body.displayName), platform, agentVersion: body.agentVersion });
    return Response.json({ protocolVersion: 1, enrollmentID: enrollment.id, nonce: enrollment.nonce, expiresAt: enrollment.expiresAt.toISOString() }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (!(error instanceof DeviceContractError)) console.error("cloud_enrollment_challenge_failure", { stage });
    return jsonError(error);
  }
}
