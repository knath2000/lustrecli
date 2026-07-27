import assert from "node:assert/strict";
import test from "node:test";
import { gatewayHeartbeatHandler } from "./gateway-heartbeat-persistence.ts";

const secret = "stage-i-test-secret";
const deviceID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const connectionID = "88e5c12c-43a1-4b17-ae2a-4231c3644ff8";
const connectedAt = "2026-07-26T08:00:00Z";
const frame = { version: 1, type: "heartbeat", sequence: 7, sentAt: "2026-07-26T08:00:01Z", agentVersion: "0.1.0", correlationID: "stage-i-correlation", commandAcks: [], jobs: [] };

function request(body, relaySecret = secret, headers = {}) {
  return new Request("http://localhost/api/cloud/v1/gateway/heartbeat", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(relaySecret === null ? {} : { "X-Lustre-Gateway-Relay-Secret": relaySecret }), ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("persistence relay returns no command fields", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const calls = [];
  const response = await gatewayHeartbeatHandler(async (input) => { calls.push(input); return []; })(request({ deviceID, connectionID, connectedAt, frame }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 1, type: "gateway-heartbeat-persisted", sequence: 7, correlationID: "stage-i-correlation", acknowledgedCommandAckIDs: [] });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].connectedAt.toISOString(), "2026-07-26T08:00:00.000Z");
});

test("persistence relay requires its dedicated secret", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const handler = gatewayHeartbeatHandler(async () => []);
  assert.equal((await handler(request({ deviceID, connectionID, connectedAt, frame }, null))).status, 401);
  assert.equal((await handler(request({ deviceID, connectionID, connectedAt, frame }, "wrong"))).status, 401);
});

test("persistence relay rejects malformed, oversized, and invalid bodies before persistence", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  let calls = 0;
  const handler = gatewayHeartbeatHandler(async () => { calls += 1; return []; });
  assert.equal((await handler(request("{"))).status, 400);
  assert.equal((await handler(request({ deviceID, connectionID, connectedAt, frame }, secret, { "Content-Length": "200000" }))).status, 400);
  assert.equal((await handler(request({ deviceID: "invalid", connectionID, connectedAt, frame }))).status, 400);
  assert.equal((await handler(request({ deviceID, connectionID, connectedAt: "invalid", frame }))).status, 400);
  assert.equal((await handler(request({ deviceID, connectionID, connectedAt, frame: { ...frame, sentAt: "invalid" } }))).status, 400);
  assert.equal(calls, 0);
});

test("persistence rejection returns no successful acknowledgement", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const handler = gatewayHeartbeatHandler(async () => { throw new Error("database unavailable"); });
  const response = await handler(request({ deviceID, connectionID, connectedAt, frame }));
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: { code: "internal_error", message: "Unable to process the device request." } });
});
