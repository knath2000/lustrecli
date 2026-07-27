export interface Env {
  CONTROL_PLANE_ORIGIN: string;
  LUSTRE_DEVICE_TOKEN_SECRET: string;
  LUSTRE_GATEWAY_RELAY_SECRET: string;
  LUSTRE_GATEWAY_CONTROL_SECRET: string;
  DEVICE_CONNECTION: DurableObjectNamespace<DeviceConnection>;
}

type DeviceClaims = { sub: string; aud: string | string[]; exp: number; use: string; accountID: string };

const tokenPrefix = "lustre.";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const JOB_STATUSES = new Set(["queued", "running", "paused", "completed", "failed", "cancelled", "verificationRequired"]);
const JOB_PHASES = new Set(["resolving", "downloading", "materializing", "postProcessing", "uploading", "verifying"]);
const ACKNOWLEDGEMENT_CODES = new Set(["provider_verification_required", "provider_http_error", "provider_unreachable", "provider_changed", "authentication_required", "result_too_large", "invalid_request"]);

function isRecord(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function isUUID(value: unknown): value is string { return typeof value === "string" && UUID_PATTERN.test(value); }
function isBoundedString(value: unknown, maximum: number): value is string { return typeof value === "string" && value.trim().length > 0 && Array.from(value).length <= maximum; }
function isNonNegativeInteger(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function heartbeatSchema(value: Record<string, unknown>): { acknowledgementCount: number; jobCount: number } | null {
  if (typeof value.sentAt !== "string" || Number.isNaN(Date.parse(value.sentAt)) || !isBoundedString(value.agentVersion, 80) || !isBoundedString(value.correlationID, 64)) return null;
  if (!Array.isArray(value.commandAcks) || value.commandAcks.length > 8 || !Array.isArray(value.jobs) || value.jobs.length > 50) return null;
  for (const acknowledgement of value.commandAcks) {
    if (!isRecord(acknowledgement) || !isUUID(acknowledgement.id) || !["completed", "failed"].includes(acknowledgement.status as string) || (acknowledgement.jobID !== undefined && !isUUID(acknowledgement.jobID)) || (acknowledgement.result !== undefined && !isRecord(acknowledgement.result)) || (acknowledgement.code !== undefined && (typeof acknowledgement.code !== "string" || !ACKNOWLEDGEMENT_CODES.has(acknowledgement.code)))) return null;
    if (acknowledgement.status === "failed" && acknowledgement.result !== undefined) return null;
    if (acknowledgement.status === "completed" && isRecord(acknowledgement.result) && acknowledgement.result.kind === "feed_page" && !validFeedPageAcknowledgement(acknowledgement)) return null;
    if (acknowledgement.status === "completed" && isRecord(acknowledgement.result) && acknowledgement.result.kind === "destinations_list" && !validDestinationsAcknowledgement(acknowledgement)) return null;
  }
  for (const job of value.jobs) {
    if (!isRecord(job) || !isUUID(job.id) || typeof job.status !== "string" || !JOB_STATUSES.has(job.status) || !isNonNegativeInteger(job.attempts)) return null;
    if (job.progress !== undefined && (typeof job.progress !== "number" || !Number.isFinite(job.progress) || job.progress < 0 || job.progress > 1)) return null;
    if (job.downloadedBytes !== undefined && !isNonNegativeInteger(job.downloadedBytes)) return null;
    if (job.totalBytes !== undefined && !isNonNegativeInteger(job.totalBytes)) return null;
    if (job.phase !== undefined && (typeof job.phase !== "string" || !JOB_PHASES.has(job.phase))) return null;
    if (job.displayName !== undefined && !isBoundedString(job.displayName, 512)) return null;
    if (job.preferredQualityLabel !== undefined && !isBoundedString(job.preferredQualityLabel, 512)) return null;
    if (job.sourcePageURL !== undefined) {
      if (!isBoundedString(job.sourcePageURL, 4_096)) return null;
      try { if (!["http:", "https:"].includes(new URL(job.sourcePageURL).protocol)) return null; }
      catch { return null; }
    }
    if (job.updatedAt !== undefined && (typeof job.updatedAt !== "string" || Number.isNaN(Date.parse(job.updatedAt)))) return null;
  }
  return { acknowledgementCount: value.commandAcks.length, jobCount: value.jobs.length };
}

function base64URL(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function tokenFrom(request: Request) {
  return request.headers.get("sec-websocket-protocol")?.split(",").map((value) => value.trim()).find((value) => value.startsWith(tokenPrefix))?.slice(tokenPrefix.length);
}

function canonicalOrigin(value: string) {
  return new URL(value).origin;
}

async function deviceClaims(token: string, env: Env): Promise<DeviceClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("token_shape");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.LUSTRE_DEVICE_TOKEN_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const verified = await crypto.subtle.verify("HMAC", key, base64URL(parts[2]) as BufferSource, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!verified) throw new Error("token_signature");
  const claims = JSON.parse(new TextDecoder().decode(base64URL(parts[1]))) as DeviceClaims;
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (claims.use !== "realtime" || !claims.sub || !claims.accountID || claims.exp * 1_000 <= Date.now() || !audience.some((value) => canonicalOrigin(value) === canonicalOrigin(env.CONTROL_PLANE_ORIGIN))) throw new Error("token_claims");
  return claims;
}

export class DeviceConnection extends DurableObject<Env> {
  private readonly pendingAttachments = new Map<WebSocket, { deviceID: string; connectionID: string; connectedAt: string; protocolVersion: 1; lastSequence: number; connectionKind: "realtime" | "smoke"; commandDeliveryV1: boolean; feedPageV1: boolean; destinationsListV1: boolean; feedQueueV1: boolean; commandWakeV1: boolean }>();

  async fetch(request: Request) {
    if (request.method === "POST" && new URL(request.url).pathname === "/control/command-wake") {
      const wake = await request.json() as { commandID?: unknown };
      if (!isUUID(wake.commandID)) return new Response("Invalid wake.", { status: 400 });
      const previous = await this.ctx.storage.get<{ commandID: string; receivedAt: number }>("lastCommandWake");
      if (previous?.commandID === wake.commandID && Date.now() - previous.receivedAt < 60_000) {
        return Response.json({ status: "coalesced", notified: 0 });
      }
      await this.ctx.storage.put("lastCommandWake", { commandID: wake.commandID, receivedAt: Date.now() });
      let notified = 0;
      for (const socket of this.ctx.getWebSockets()) {
        const attachment = socket.deserializeAttachment() as { connectionKind?: unknown; commandWakeV1?: unknown } | null;
        if (attachment?.connectionKind !== "realtime" || attachment.commandWakeV1 !== true) continue;
        try {
          socket.send(JSON.stringify({ version: 1, type: "command-available" }));
          notified += 1;
        } catch {}
      }
      return Response.json({ status: "accepted", notified });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket upgrade required.", { status: 426 });
    const smoke = new URL(request.url).pathname === "/_ws-smoke-do";
    const protocol = tokenFrom(request);
    const deviceID = protocol ? (JSON.parse(new TextDecoder().decode(base64URL(protocol.split(".")[1]))) as DeviceClaims).sub : null;
    if (!deviceID) return new Response("Missing device.", { status: 400 });
    await this.ctx.storage.put("stage", "do_fetch_entered");
    const connectionID = crypto.randomUUID();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    await this.ctx.storage.put("stage", "do_socket_accepted");
    this.pendingAttachments.set(server, { deviceID, connectionID, connectedAt: new Date().toISOString(), protocolVersion: 1, lastSequence: 0, connectionKind: smoke ? "smoke" : "realtime", commandDeliveryV1: false, feedPageV1: false, destinationsListV1: false, feedQueueV1: false, commandWakeV1: false });
    if (smoke) return new Response(null, { status: 101, headers: { "Sec-WebSocket-Protocol": "lustre-v1" }, webSocket: client });
    return new Response(null, { status: 101, headers: { "Sec-WebSocket-Protocol": "lustre-v1" }, webSocket: client });
  }

  async webSocketMessage(webSocket: WebSocket, message: string | ArrayBuffer) {
    if (message instanceof ArrayBuffer) {
      if (message.byteLength > 131_072) { webSocket.close(4400, "frame-too-large"); return; }
      await this.ctx.storage.put("stage", "binary_frame_received");
      console.log("binary_frame_received");
      const decoded = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(message);
      const record = { stage: "binary_utf8_decoded", byteLength: message.byteLength, decodedCharacterLength: decoded.length };
      await this.ctx.storage.put("lastBinarySmoke", record);
      console.log("binary_utf8_decoded", record);
      let parsed: unknown;
      try {
        parsed = JSON.parse(decoded);
      } catch {
        await this.ctx.storage.put("stage", "binary_json_parse_failed");
        console.log("binary_json_parse_failed");
        webSocket.close(4400, "invalid-json");
        return;
      }
      const parsedRecord = { stage: "binary_json_parsed", byteLength: message.byteLength, decodedCharacterLength: decoded.length };
      await this.ctx.storage.put("lastBinarySmoke", parsedRecord);
      console.log("binary_json_parsed", parsedRecord);
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        await this.ctx.storage.put("stage", "heartbeat_envelope_invalid");
        webSocket.close(4400, "invalid-envelope");
        return;
      }
      const envelope = parsed as Record<string, unknown>;
      if (envelope.version !== 1 || envelope.type !== "heartbeat" || !Number.isSafeInteger(envelope.sequence) || (envelope.sequence as number) <= 0) {
        await this.ctx.storage.put("stage", "heartbeat_envelope_invalid");
        webSocket.close(4400, "invalid-envelope");
        return;
      }
      const sequence = envelope.sequence as number;
      const envelopeRecord = { stage: "heartbeat_envelope_recognized", byteLength: message.byteLength, decodedCharacterLength: decoded.length, sequence };
      await this.ctx.storage.put("lastBinarySmoke", envelopeRecord);
      console.log("heartbeat_envelope_recognized", envelopeRecord);
      const schema = heartbeatSchema(envelope);
      if (!schema) {
        await this.ctx.storage.put("stage", "heartbeat_schema_invalid");
        console.log("heartbeat_schema_invalid");
        webSocket.close(4400, "invalid-heartbeat");
        return;
      }
      const schemaRecord = { stage: "heartbeat_schema_validated", sequence, ...schema };
      await this.ctx.storage.put("lastBinarySmoke", schemaRecord);
      console.log("heartbeat_schema_validated", schemaRecord);
      let attachment: unknown;
      try {
        attachment = webSocket.deserializeAttachment();
      } catch {
        await this.ctx.storage.put("stage", "heartbeat_attachment_invalid");
        console.log("heartbeat_attachment_invalid");
        webSocket.close(1011, "attachment-unavailable");
        return;
      }
      if (typeof attachment !== "object" || attachment === null || Array.isArray(attachment)) {
        await this.ctx.storage.put("stage", "heartbeat_attachment_invalid");
        console.log("heartbeat_attachment_invalid");
        webSocket.close(1011, "attachment-unavailable");
        return;
      }
      const connection = attachment as Record<string, unknown>;
      if (
        typeof connection.deviceID !== "string" || connection.deviceID.trim() === "" ||
        typeof connection.connectionID !== "string" || connection.connectionID.trim() === "" ||
        typeof connection.connectedAt !== "string" || connection.connectedAt.trim() === "" ||
        !Number.isFinite(Date.parse(connection.connectedAt)) ||
        connection.protocolVersion !== 1
      ) {
        await this.ctx.storage.put("stage", "heartbeat_attachment_invalid");
        console.log("heartbeat_attachment_invalid");
        webSocket.close(1011, "attachment-unavailable");
        return;
      }
      const lastSequence = connection.lastSequence;
      if (lastSequence !== undefined && (!Number.isSafeInteger(lastSequence) || (lastSequence as number) < 0)) {
        await this.ctx.storage.put("stage", "heartbeat_attachment_invalid");
        console.log("heartbeat_attachment_invalid");
        webSocket.close(1011, "attachment-unavailable");
        return;
      }
      const connectionKind = connection.connectionKind;
      if (connectionKind !== undefined && connectionKind !== "realtime" && connectionKind !== "smoke") {
        await this.ctx.storage.put("stage", "heartbeat_attachment_invalid");
        console.log("heartbeat_attachment_invalid");
        webSocket.close(1011, "attachment-unavailable");
        return;
      }
      const commandDeliveryV1 = connection.commandDeliveryV1 === true;
      const feedPageV1 = connection.feedPageV1 === true;
      const destinationsListV1 = connection.destinationsListV1 === true;
      const feedQueueV1 = connection.feedQueueV1 === true;
      const commandWakeV1 = connection.commandWakeV1 === true;
      const previousSequence = lastSequence === undefined ? 0 : lastSequence as number;
      const attachmentRecord = { stage: "heartbeat_attachment_restored", connectionID: connection.connectionID, protocolVersion: connection.protocolVersion, sequence };
      await this.ctx.storage.put("lastBinarySmoke", attachmentRecord);
      console.log("heartbeat_attachment_restored", attachmentRecord);
      const sequenceRecord = { connectionID: connection.connectionID, sequence, previousSequence };
      if (sequence <= previousSequence) {
        const rejectedRecord = { stage: "heartbeat_sequence_rejected", ...sequenceRecord };
        await this.ctx.storage.put("lastBinarySmoke", rejectedRecord);
        console.log("heartbeat_sequence_rejected", rejectedRecord);
        webSocket.close(4400, "stale-sequence");
        return;
      }
      webSocket.serializeAttachment({
        deviceID: connection.deviceID,
        connectionID: connection.connectionID,
        connectedAt: connection.connectedAt,
        protocolVersion: 1,
        lastSequence: sequence,
        ...(connectionKind === undefined ? {} : { connectionKind }),
        commandDeliveryV1,
        feedPageV1,
        destinationsListV1,
        feedQueueV1,
        commandWakeV1,
      });
      const acceptedRecord = { stage: "heartbeat_sequence_accepted", ...sequenceRecord };
      await this.ctx.storage.put("lastBinarySmoke", acceptedRecord);
      console.log("heartbeat_sequence_accepted", acceptedRecord);
      webSocket.send(JSON.stringify({ version: 1, type: "heartbeat-accepted", sequence, command: null, acknowledgedCommandAcks: [] }));
      if (connectionKind === "realtime") {
        const delivery = await this.relayHeartbeat(
          connection.deviceID as string,
          connection.connectionID as string,
          connection.connectedAt as string,
          envelope,
          commandDeliveryV1,
          feedPageV1,
          destinationsListV1,
          feedQueueV1,
        );
        if (commandDeliveryV1) webSocket.send(JSON.stringify(delivery));
      }
      return;
    }
    const text = message;
    if (new TextEncoder().encode(text).byteLength > 131_072) { webSocket.close(4400, "frame-too-large"); return; }
    const frame = JSON.parse(text) as { type?: string; sequence?: number; commandAcks?: unknown[] };
    if (frame.type === "gateway_hello") {
      await this.ctx.storage.put("stage", "do_hello_received");
      const attachment = this.pendingAttachments.get(webSocket);
      const commandDeliveryV1 = negotiatedCommandDelivery(frame as Record<string, unknown>, attachment?.connectionKind === "realtime");
      const feedPageV1 = negotiatedFeedPage(frame as Record<string, unknown>, attachment?.connectionKind === "realtime");
      const destinationsListV1 = negotiatedDestinationsList(frame as Record<string, unknown>, attachment?.connectionKind === "realtime");
      const feedQueueV1 = negotiatedFeedQueue(frame as Record<string, unknown>, attachment?.connectionKind === "realtime");
      const commandWakeV1 = negotiatedCommandWake(frame as Record<string, unknown>, attachment?.connectionKind === "realtime");
      webSocket.send(JSON.stringify({ version: 1, type: "gateway_hello_ack", capabilities: [...(commandDeliveryV1 ? [commandDeliveryCapability] : []), ...(feedPageV1 ? [feedPageCapability] : []), ...(destinationsListV1 ? [destinationsListCapability] : []), ...(feedQueueV1 ? [feedQueueCapability] : []), ...(commandWakeV1 ? [commandWakeCapability] : [])] }));
      if (attachment) { webSocket.serializeAttachment({ ...attachment, commandDeliveryV1, feedPageV1, destinationsListV1, feedQueueV1, commandWakeV1 }); this.pendingAttachments.delete(webSocket); }
      await this.ctx.storage.put("stage", "do_hello_acked");
      return;
    }
    const correlationID = (frame as { correlationID?: unknown }).correlationID;
    const agentVersion = (frame as { agentVersion?: unknown }).agentVersion;
    if ((frame as { version?: unknown }).version !== 1 || frame.type !== "heartbeat" || !Number.isSafeInteger(frame.sequence) || frame.sequence! < 1 || typeof correlationID !== "string" || correlationID.length > 64 || typeof agentVersion !== "string" || agentVersion.length > 80 || !Array.isArray(frame.commandAcks)) { webSocket.close(4400, "invalid-heartbeat"); return; }
    const { connectionID } = webSocket.deserializeAttachment() as { connectionID: string };
    const lastSequence = await this.ctx.storage.get<number>(`sequence:${connectionID}`) ?? 0;
    if (frame.sequence! <= lastSequence) { webSocket.close(4400, "stale-sequence"); return; }
    const receivedAt = new Date().toISOString();
    await this.ctx.storage.put(`sequence:${connectionID}`, frame.sequence!);
    await this.ctx.storage.put("lastHeartbeat", { stage: "local_heartbeat_accepted", connectionID, sequence: frame.sequence, correlationID, receivedAt });
    webSocket.send(JSON.stringify({ version: 1, type: "heartbeat-accepted", sequence: frame.sequence, command: null, acknowledgedCommandAcks: [] }));
  }

  private async relayHeartbeat(deviceID: string, connectionID: string, connectedAt: string, frame: Record<string, unknown>, commandDeliveryV1: boolean, feedPageV1: boolean, destinationsListV1: boolean, feedQueueV1: boolean) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5_000);
    let acknowledgedCommandAckIDs: string[] = [];
    const fallback = () => commandDeliveryFrame({ sequence: frame.sequence as number, correlationID: frame.correlationID as string, acknowledgedCommandAckIDs, command: null });
    try {
      await this.ctx.storage.put("stage", "vercel_persistence_started");
      console.log("vercel_persistence_started");
      const response = await fetch(new URL("/api/cloud/v1/gateway/heartbeat", this.env.CONTROL_PLANE_ORIGIN), {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Lustre-Gateway-Relay-Secret": this.env.LUSTRE_GATEWAY_RELAY_SECRET },
        body: JSON.stringify({ deviceID, connectionID, connectedAt, frame }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`http_${response.status}`);
      const payload: unknown = await response.json();
      if (!validPersistenceResponse(payload, frame.sequence as number, frame.correlationID as string)) throw new Error("invalid_response");
      acknowledgedCommandAckIDs = payload.acknowledgedCommandAckIDs;
      await this.ctx.storage.put("stage", "vercel_persistence_accepted");
      console.log("vercel_persistence_accepted");
      if (!commandDeliveryV1) return fallback();
      const commandResponse = await fetch(new URL("/api/cloud/v1/gateway/commands/next", this.env.CONTROL_PLANE_ORIGIN), {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Lustre-Gateway-Relay-Secret": this.env.LUSTRE_GATEWAY_RELAY_SECRET },
        body: JSON.stringify({ deviceID, connectionID, sequence: frame.sequence, correlationID: frame.correlationID, allowFeedPage: feedPageV1, allowDestinationsList: destinationsListV1, allowFeedQueue: feedQueueV1 }),
        signal: controller.signal,
      });
      if (!commandResponse.ok) throw new Error(`http_${commandResponse.status}`);
      const selected: unknown = await commandResponse.json();
      const command = selectedGatewayCommand(selected, frame.sequence as number, frame.correlationID as string, feedPageV1, destinationsListV1, feedQueueV1);
      if (command === undefined) throw new Error("invalid_response");
      return commandDeliveryFrame({
        sequence: frame.sequence as number,
        correlationID: frame.correlationID as string,
        acknowledgedCommandAckIDs: payload.acknowledgedCommandAckIDs,
        command,
      });
    } catch (error) {
      const category = controller.signal.aborted ? "timeout" : error instanceof Error && error.message.startsWith("http_") ? "http" : error instanceof Error && error.message === "invalid_response" ? "response" : "network";
      const stage = `vercel_persistence_failed_${category}`;
      console.log(stage);
      try { await this.ctx.storage.put("stage", stage); } catch {}
      return fallback();
    } finally {
      clearTimeout(timeout);
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/control/command-wake" && request.method === "POST") {
      const body = await request.arrayBuffer();
      if (body.byteLength === 0 || body.byteLength > 1_024) return new Response("Invalid request.", { status: 400 });
      const timestamp = request.headers.get("X-Lustre-Control-Timestamp");
      const signature = request.headers.get("X-Lustre-Control-Signature");
      const issuedAt = timestamp && /^\d{13}$/.test(timestamp) ? Number(timestamp) : NaN;
      if (!Number.isSafeInteger(issuedAt) || Math.abs(Date.now() - issuedAt) > 30_000 || !signature || !/^[0-9a-f]{64}$/i.test(signature)) return new Response("Unauthenticated.", { status: 401 });
      const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.LUSTRE_GATEWAY_CONTROL_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
      const prefix = new TextEncoder().encode(`${timestamp}.`);
      const signed = new Uint8Array(prefix.byteLength + body.byteLength);
      signed.set(prefix);
      signed.set(new Uint8Array(body), prefix.byteLength);
      const verified = await crypto.subtle.verify("HMAC", key, Uint8Array.from(signature.match(/../g)!, (byte) => Number.parseInt(byte, 16)), signed);
      if (!verified) return new Response("Unauthenticated.", { status: 401 });
      let wake: unknown;
      try { wake = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(body)); }
      catch { return new Response("Invalid request.", { status: 400 }); }
      if (!isRecord(wake) || Object.keys(wake).sort().join(",") !== "commandID,deviceID,version" || wake.version !== 1 || !isUUID(wake.deviceID) || !isUUID(wake.commandID)) return new Response("Invalid request.", { status: 400 });
      return env.DEVICE_CONNECTION.getByName(wake.deviceID).fetch(new Request("https://durable-object/control/command-wake", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ commandID: wake.commandID }) }));
    }
    if (path === "/probe" && request.method === "GET") {
      const token = tokenFrom(request);
      if (!token) return new Response("Unauthenticated.", { status: 401 });
      try { await deviceClaims(token, env); return Response.json({ status: "worker_authenticated", stage: "worker_request" }); }
      catch (error) { console.warn("lustre_gateway_rejected", { stage: "token_verification", code: error instanceof Error ? error.message : "failed" }); return new Response("Unauthenticated.", { status: 401 }); }
    }
    if (!["/realtime", "/_ws-smoke-worker", "/_ws-smoke-do"].includes(path)) return new Response("Not found.", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket upgrade required.", { status: 426 });
    const token = tokenFrom(request);
    if (!token) return new Response("Unauthenticated.", { status: 401 });
    try {
      const claims = await deviceClaims(token, env);
      if (path === "/_ws-smoke-worker") {
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        server.accept();
        server.addEventListener("message", (event) => { if (event.data === JSON.stringify({ version: 1, type: "gateway_hello" })) server.send(JSON.stringify({ version: 1, type: "gateway_hello_ack" })); });
        return new Response(null, { status: 101, headers: { "Sec-WebSocket-Protocol": "lustre-v1" }, webSocket: client });
      }
      return env.DEVICE_CONNECTION.getByName(claims.sub).fetch(request);
    } catch (error) {
      console.warn("lustre_gateway_rejected", { stage: "token_verification", code: error instanceof Error ? error.message : "failed" });
      return new Response("Unauthenticated.", { status: 401 });
    }
  },
} satisfies ExportedHandler<Env>;
import { DurableObject } from "cloudflare:workers";
import { commandDeliveryCapability, commandDeliveryFrame, commandWakeCapability, destinationsListCapability, feedPageCapability, feedQueueCapability, negotiatedCommandDelivery, negotiatedCommandWake, negotiatedDestinationsList, negotiatedFeedPage, negotiatedFeedQueue, selectedGatewayCommand, validDestinationsAcknowledgement, validFeedPageAcknowledgement, validPersistenceResponse } from "./protocol";
