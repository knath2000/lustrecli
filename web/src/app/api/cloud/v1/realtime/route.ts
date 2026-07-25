import { experimental_upgradeWebSocket, type WebSocketData } from "@vercel/functions";
import { randomUUID } from "node:crypto";
import { MAX_HEARTBEAT_FRAME_BYTES, parseHeartbeatFrame } from "@/lib/cloud/device-contract";
import { acceptHeartbeat, establishPresence } from "@/lib/cloud/device-repository";
import { verifyDeviceToken } from "@/lib/cloud/device-token";
import { presenceConnectionLeaseSeconds } from "@/lib/cloud/presence-lease";

export const runtime = "nodejs";
const tokenPrefix = "lustre.";
function tokenFrom(request: Request) { return request.headers.get("sec-websocket-protocol")?.split(",").map((value) => value.trim()).find((value) => value.startsWith(tokenPrefix))?.slice(tokenPrefix.length); }
function errorFrame(code: string) { return JSON.stringify({ version: 1, type: "error", code }); }
function reconnectRequestedFrame() { return JSON.stringify({ version: 1, type: "reconnect-requested", reason: "lease_expired" }); }

export async function GET(request: Request) {
  const token = tokenFrom(request);
  if (!token) return Response.json({ error: { code: "unauthenticated", message: "Missing realtime token." } }, { status: 401 });
  try {
    const verified = await verifyDeviceToken(token); const deviceID = verified.payload.sub!; const connectionID = randomUUID();
    return experimental_upgradeWebSocket(async (socket) => {
      try { await establishPresence(deviceID, connectionID, "unknown"); }
      catch { socket.close(4403, "revoked"); return; }
      const leaseTimer = setTimeout(() => socket.send(reconnectRequestedFrame()), presenceConnectionLeaseSeconds() * 1_000);
      socket.on("close", () => clearTimeout(leaseTimer));
      socket.on("message", (data: WebSocketData) => {
        void (async () => {
          const text = typeof data === "string" ? data : Buffer.isBuffer(data) ? data.toString("utf8") : Array.isArray(data) ? Buffer.concat(data).toString("utf8") : Buffer.from(data as ArrayBuffer).toString("utf8");
          if (Buffer.byteLength(text, "utf8") > MAX_HEARTBEAT_FRAME_BYTES) { socket.close(4400, "frame-too-large"); return; }
          try {
            const frame = parseHeartbeatFrame(JSON.parse(text));
            await acceptHeartbeat(deviceID, connectionID, frame.sequence, frame.agentVersion);
            socket.send(JSON.stringify({ version: 1, type: "heartbeat-accepted", sequence: frame.sequence, serverTime: new Date().toISOString() }));
          } catch { socket.send(errorFrame("heartbeat_rejected")); socket.close(4403, "heartbeat-rejected"); }
        })();
      });
    }, { maxPayload: MAX_HEARTBEAT_FRAME_BYTES });
  } catch { return Response.json({ error: { code: "unauthenticated", message: "Invalid realtime token." } }, { status: 401 }); }
}
