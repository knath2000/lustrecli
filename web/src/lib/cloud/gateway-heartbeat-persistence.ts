import { DeviceContractError, MAX_HEARTBEAT_FRAME_BYTES, deviceError, parseHeartbeatFrame, type HeartbeatFrame } from "./device-contract.ts";

const MAX_RELAY_BODY_BYTES = MAX_HEARTBEAT_FRAME_BYTES + 4_096;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type PersistGatewayHeartbeat = (input: {
  deviceID: string;
  connectionID: string;
  connectedAt: Date;
  frame: HeartbeatFrame;
}) => Promise<string[]>;

export function gatewayHeartbeatHandler(persist: PersistGatewayHeartbeat) {
  return async (request: Request) => {
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
      if (
        typeof values.deviceID !== "string" || !UUID_PATTERN.test(values.deviceID) ||
        typeof values.connectionID !== "string" || !UUID_PATTERN.test(values.connectionID) ||
        typeof values.connectedAt !== "string" || Number.isNaN(Date.parse(values.connectedAt))
      ) throw new DeviceContractError("invalid_request", "Invalid gateway heartbeat.");
      if (new TextEncoder().encode(JSON.stringify(values.frame)).byteLength > MAX_HEARTBEAT_FRAME_BYTES) throw new DeviceContractError("invalid_request", "Heartbeat is too large.");
      const frame = parseHeartbeatFrame(values.frame);
      if (process.env.LUSTRE_GATEWAY_ACCEPTANCE_FAIL_COMMAND_ACK_PERSISTENCE === "true" && frame.commandAcks.length > 0) {
        return Response.json({ error: { code: "acceptance_relay_failure", message: "Persistence is temporarily unavailable." } }, { status: 503, headers: { "Cache-Control": "no-store" } });
      }
      const acknowledgedCommandAckIDs = await persist({ deviceID: values.deviceID, connectionID: values.connectionID, connectedAt: new Date(values.connectedAt), frame });
      return Response.json({ version: 1, type: "gateway-heartbeat-persisted", sequence: frame.sequence, correlationID: frame.correlationID, acknowledgedCommandAckIDs }, { headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      if (error instanceof Error && error.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Unauthenticated." } }, { status: 401 });
      return Response.json(deviceError(error), { status: error instanceof DeviceContractError ? 400 : 500 });
    }
  };
}
