import assert from "node:assert/strict";
import test from "node:test";
import { gatewayCommandHandler } from "./gateway-command-delivery.ts";

const secret = "stage-j1-secret";
const deviceID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const connectionID = "88e5c12c-43a1-4b17-ae2a-4231c3644ff8";

function request(body, relaySecret = secret) {
  return new Request("http://localhost/api/cloud/v1/gateway/commands/next", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(relaySecret ? { "X-Lustre-Gateway-Relay-Secret": relaySecret } : {}) },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("command selection returns only the bounded feed_sites command", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const handler = gatewayCommandHandler(async () => ({ id: deviceID, kind: "feed_sites", payload: {} }));
  const response = await handler(request({ deviceID, connectionID, sequence: 7, correlationID: "stage-j1", allowFeedPage: false }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "stage-j1", command: { id: deviceID, kind: "feed_sites", payload: {} } });
});

test("command selection gates and validates feed_page", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const calls = [];
  const handler = gatewayCommandHandler(async (input) => {
    calls.push(input);
    return { id: deviceID, kind: "feed_page", payload: { siteID: "hqporner", page: 1, query: "  newest   clips " } };
  });
  const legacy = await handler(request({ deviceID, connectionID, sequence: 7, correlationID: "legacy" }));
  assert.equal(legacy.status, 200);
  assert.equal(calls[0].allowFeedPage, false);
  const response = await handler(request({ deviceID, connectionID, sequence: 8, correlationID: "j2", allowFeedPage: true }));
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).command.payload, { siteID: "hqporner", page: 1, query: "newest clips" });
  const invalid = gatewayCommandHandler(async () => ({ id: deviceID, kind: "feed_page", payload: { siteID: "unknown", page: 1 } }));
  assert.equal((await invalid(request({ deviceID, connectionID, sequence: 9, correlationID: "j2", allowFeedPage: true }))).status, 400);
});

test("command selection supports null delivery and requires exact boundary fields", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  let calls = 0;
  const handler = gatewayCommandHandler(async () => { calls += 1; return null; });
  const response = await handler(request({ deviceID, connectionID, sequence: 8, correlationID: "stage-j1-null" }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).command, null);
  assert.equal((await handler(request({ deviceID, connectionID, sequence: 0, correlationID: "bad" }))).status, 400);
  assert.equal((await handler(request({ deviceID, connectionID: "bad", sequence: 1, correlationID: "bad" }))).status, 400);
  assert.equal(calls, 1);
});

test("command selection requires the relay secret and isolates failures", async () => {
  process.env.LUSTRE_GATEWAY_RELAY_SECRET = secret;
  const handler = gatewayCommandHandler(async () => { throw new Error("database unavailable"); });
  assert.equal((await handler(request({ deviceID, connectionID, sequence: 1, correlationID: "stage-j1" }, null))).status, 401);
  assert.equal((await handler(request({ deviceID, connectionID, sequence: 1, correlationID: "stage-j1" }))).status, 500);
});
