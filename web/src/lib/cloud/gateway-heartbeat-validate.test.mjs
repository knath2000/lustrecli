import assert from "node:assert/strict";
import test from "node:test";
import { POST } from "../../app/api/cloud/v1/gateway/heartbeat/validate/route.ts";

const secret = "stage-h-test-secret";
const deviceID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const connectionID = "88e5c12c-43a1-4b17-ae2a-4231c3644ff8";
const frame = { version: 1, type: "heartbeat", sequence: 7, sentAt: "2026-07-26T08:00:00Z", agentVersion: "0.1.0", correlationID: "stage-h-correlation", commandAcks: [], jobs: [] };

function request(body, relaySecret = secret, headers = {}) {
  return new Request("http://localhost/api/cloud/v1/gateway/heartbeat/validate", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(relaySecret === null ? {} : { "X-Lustre-Gateway-Relay-Secret": relaySecret }), ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("gateway heartbeat validation returns only validated identity fields", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const response = await POST(request({ deviceID, connectionID, frame }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 1, type: "gateway-heartbeat-validated", sequence: 7, correlationID: "stage-h-correlation" });
});

test("gateway heartbeat validation requires its dedicated relay secret", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  assert.equal((await POST(request({ deviceID, connectionID, frame }, null))).status, 401);
  assert.equal((await POST(request({ deviceID, connectionID, frame }, "wrong"))).status, 401);
});

test("gateway heartbeat validation rejects malformed and oversized bodies", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  assert.equal((await POST(request("{"))).status, 400);
  assert.equal((await POST(request({ deviceID, connectionID, frame }, secret, { "Content-Length": "200000" }))).status, 400);
});

test("gateway heartbeat validation rejects invalid IDs and heartbeat contracts", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  assert.equal((await POST(request({ deviceID: "invalid", connectionID, frame }))).status, 400);
  assert.equal((await POST(request({ deviceID, connectionID: "invalid", frame }))).status, 400);
  assert.equal((await POST(request({ deviceID, connectionID, frame: { ...frame, sentAt: "invalid" } }))).status, 400);
});
