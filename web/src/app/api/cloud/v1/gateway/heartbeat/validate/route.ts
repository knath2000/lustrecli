import { DeviceContractError, MAX_HEARTBEAT_FRAME_BYTES, deviceError, parseHeartbeatFrame } from "../../../../../../../lib/cloud/device-contract.ts";

const MAX_RELAY_BODY_BYTES = MAX_HEARTBEAT_FRAME_BYTES + 4_096;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function POST(request: Request) {
  try {
    const secret = process.env.LUSTRE_GATEWAY_RELAY_SECRET;
    if (!secret || request.headers.get("X-Lustre-Gateway-Relay-Secret") !== secret) throw new Error("unauthenticated");
    const declaredSize = Number(request.headers.get("content-length") ?? "0");
    if (!Number.isFinite(declaredSize) || declaredSize < 0 || declaredSize > MAX_RELAY_BODY_BYTES) throw new DeviceContractError("invalid_request", "Request body is too large.");
    const bytes = await request.arrayBuffer();
    if (bytes.byteLength > MAX_RELAY_BODY_BYTES) throw new DeviceContractError("invalid_request", "Request body is too large.");
    let body: unknown;
    try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
    catch { throw new DeviceContractError("invalid_request", "Invalid gateway heartbeat."); }
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new DeviceContractError("invalid_request", "Invalid gateway heartbeat.");
    const values = body as Record<string, unknown>;
    if (typeof values.deviceID !== "string" || !UUID_PATTERN.test(values.deviceID) || typeof values.connectionID !== "string" || !UUID_PATTERN.test(values.connectionID)) throw new DeviceContractError("invalid_request", "Invalid gateway heartbeat.");
    if (new TextEncoder().encode(JSON.stringify(values.frame)).byteLength > MAX_HEARTBEAT_FRAME_BYTES) throw new DeviceContractError("invalid_request", "Heartbeat is too large.");
    const frame = parseHeartbeatFrame(values.frame);
    return Response.json({ version: 1, type: "gateway-heartbeat-validated", sequence: frame.sequence, correlationID: frame.correlationID }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Unauthenticated." } }, { status: 401 });
    return Response.json(deviceError(error), { status: error instanceof DeviceContractError ? 400 : 500 });
  }
}
