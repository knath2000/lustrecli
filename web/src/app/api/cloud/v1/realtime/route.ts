import { experimental_upgradeWebSocket, type WebSocketData } from "@vercel/functions";
import { randomUUID } from "node:crypto";
import { MAX_HEARTBEAT_FRAME_BYTES, parseHeartbeatFrame } from "@/lib/cloud/device-contract";
import { acceptHeartbeat, acknowledgeCommands, establishPresence, nextPendingCommand, syncJobStatus } from "@/lib/cloud/device-repository";
import { verifyDeviceToken } from "@/lib/cloud/device-token";
import { presenceConnectionLeaseSeconds } from "@/lib/cloud/presence-lease";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const tokenPrefix = "lustre.";
function tokenFrom(request: Request) { return request.headers.get("sec-websocket-protocol")?.split(",").map((value) => value.trim()).find((value) => value.startsWith(tokenPrefix))?.slice(tokenPrefix.length); }
function reconnectRequestedFrame() { return JSON.stringify({ version: 1, type: "reconnect-requested", reason: "lease_expired" }); }

export async function GET(request: Request) {
  const token = tokenFrom(request);
  if (!token) return Response.json({ error: { code: "unauthenticated", message: "Missing realtime token." } }, { status: 401 });
  try {
    const verified = await verifyDeviceToken(token); const deviceID = verified.payload.sub!; const connectionID = randomUUID();
    return experimental_upgradeWebSocket((socket) => {
      let closed = false;
      let firstFrameReceived = false;
      let firstFrameAccepted = false;
      const closeOnce = (code: number, reason: string) => {
        if (closed) return;
        closed = true;
        socket.close(code, reason);
      };
      const leaseTimer = setTimeout(() => {
        if (!closed) socket.send(reconnectRequestedFrame());
      }, presenceConnectionLeaseSeconds() * 1_000);
      socket.on("close", (code: number, reason: string) => {
        closed = true;
        clearTimeout(leaseTimer);
        console.info("cloud_realtime_lifecycle", { stage: "close", code, reason: reason.slice(0, 64) });
      });
      socket.on("error", () => console.error("cloud_realtime_failure", { stage: "socket_error" }));
      console.info("cloud_realtime_lifecycle", { stage: "upgrade_entered" });
      const presenceReady = establishPresence(deviceID, connectionID, "unknown").then(() => {
        console.info("cloud_realtime_lifecycle", { stage: "presence_ready" });
      }).catch((error) => {
        console.error("cloud_realtime_failure", { stage: "presence_establishment" });
        closeOnce(4403, "presence-rejected");
        throw error;
      });
      void presenceReady.catch(() => undefined);
      socket.on("message", (data: WebSocketData) => {
        void (async () => {
          await presenceReady;
          if (!firstFrameReceived) {
            firstFrameReceived = true;
            console.info("cloud_realtime_lifecycle", { stage: "first_frame_received" });
          }
          const text = typeof data === "string" ? data : Buffer.isBuffer(data) ? data.toString("utf8") : Array.isArray(data) ? Buffer.concat(data).toString("utf8") : Buffer.from(data as ArrayBuffer).toString("utf8");
          if (Buffer.byteLength(text, "utf8") > MAX_HEARTBEAT_FRAME_BYTES) { closeOnce(4400, "frame-too-large"); return; }
          try {
            const frame = parseHeartbeatFrame(JSON.parse(text));
            try { await acceptHeartbeat(deviceID, connectionID, frame.sequence, frame.agentVersion); }
            catch { console.error("cloud_realtime_failure", { stage: "heartbeat_presence" }); throw new Error("heartbeat_presence"); }
            try { await Promise.all([acknowledgeCommands(deviceID, frame.commandAcks), syncJobStatus(deviceID, frame.jobs)]); }
            catch { console.error("cloud_realtime_failure", { stage: "heartbeat_sync" }); throw new Error("heartbeat_sync"); }
            let command;
            try { command = await nextPendingCommand(deviceID); }
            catch { console.error("cloud_realtime_failure", { stage: "command_dispatch" }); throw new Error("command_dispatch"); }
            if (!firstFrameAccepted) {
              firstFrameAccepted = true;
              console.info("cloud_realtime_lifecycle", { stage: "first_frame_accepted" });
            }
            socket.send(JSON.stringify({ version: 1, type: "heartbeat-accepted", sequence: frame.sequence, serverTime: new Date().toISOString(), acknowledgedCommandAcks: frame.commandAcks, command: command ? { id: command.id, kind: command.kind, payload: command.payload } : null }));
          } catch { console.error("cloud_realtime_failure", { stage: "heartbeat" }); closeOnce(4403, "heartbeat-rejected"); }
        })().catch(() => closeOnce(4403, "heartbeat-rejected"));
      });
    }, { maxPayload: MAX_HEARTBEAT_FRAME_BYTES });
  } catch { return Response.json({ error: { code: "unauthenticated", message: "Invalid realtime token." } }, { status: 401 }); }
}
