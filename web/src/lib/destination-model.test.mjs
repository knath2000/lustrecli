import assert from "node:assert/strict";
import test from "node:test";

import { destinationUsageCounts, destinationSecurityLabel, safeDestinationHost } from "./destination-model.ts";

const jobs = [
  { destination: "local" },
  { destination: "webdav:ABC-123" },
  { destination: "webdav:abc-123" },
  { destination: "/Users/example/Downloads" },
];

test("destinationUsageCounts groups local paths and WebDAV profiles", () => {
  assert.deepEqual(destinationUsageCounts(jobs), { local: 2, "abc-123": 2 });
});

test("safeDestinationHost returns a display-safe HTTPS host", () => {
  assert.equal(safeDestinationHost("https://media.example.com:8443/dav"), "media.example.com:8443");
  assert.equal(safeDestinationHost("not a url"), "Invalid endpoint");
});

test("destinationSecurityLabel makes certificate exceptions explicit", () => {
  assert.equal(destinationSecurityLabel(false), "Strict TLS validation");
  assert.equal(destinationSecurityLabel(true), "Certificate exception enabled");
});
