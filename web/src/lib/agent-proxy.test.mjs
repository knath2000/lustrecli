import assert from "node:assert/strict";
import test from "node:test";

import { buildAgentURL } from "./agent-proxy.ts";

test("buildAgentURL keeps an allowed versioned agent path on the loopback endpoint", () => {
  assert.equal(
    buildAgentURL("/v1/jobs?limit=5").toString(),
    "http://127.0.0.1:63406/v1/jobs?limit=5",
  );
});

test("buildAgentURL forwards the browser request query to the loopback agent", () => {
  assert.equal(
    buildAgentURL("/v1/feed/items", "?site=allpornstream&page=2").toString(),
    "http://127.0.0.1:63406/v1/feed/items?site=allpornstream&page=2",
  );
});

test("buildAgentURL rejects a path outside the versioned agent API", () => {
  assert.throws(() => buildAgentURL("/health"), /versioned agent API/);
});

test("buildAgentURL rejects traversal that could escape the agent API", () => {
  assert.throws(() => buildAgentURL("/v1/jobs/../../health"), /versioned agent API/);
});
