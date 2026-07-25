import assert from "node:assert/strict";
import test from "node:test";

import { DEFAULT_PRESENCE_CONNECTION_LEASE_SECONDS, presenceConnectionLeaseSeconds } from "./presence-lease.ts";

test("presence lease defaults below the device-token lifetime", () => {
  assert.equal(DEFAULT_PRESENCE_CONNECTION_LEASE_SECONDS, 9 * 60);
  assert.equal(presenceConnectionLeaseSeconds({}), 9 * 60);
});

test("presence lease accepts a deployment environment override for short preview validation", () => {
  assert.equal(presenceConnectionLeaseSeconds({ LUSTRE_PRESENCE_LEASE_SECONDS: "60" }), 60);
});

test("presence lease ignores invalid deployment environment values", () => {
  assert.equal(presenceConnectionLeaseSeconds({ LUSTRE_PRESENCE_LEASE_SECONDS: "59" }), 9 * 60);
  assert.equal(presenceConnectionLeaseSeconds({ LUSTRE_PRESENCE_LEASE_SECONDS: "601" }), 9 * 60);
  assert.equal(presenceConnectionLeaseSeconds({ LUSTRE_PRESENCE_LEASE_SECONDS: "not-a-number" }), 9 * 60);
});
