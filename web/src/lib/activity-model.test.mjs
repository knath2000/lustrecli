import assert from "node:assert/strict";
import test from "node:test";

import { deriveActivityEvents, filterActivityEvents } from "./activity-model.ts";

const jobs = [
  {
    id: "job-a",
    sourcePageURL: "https://example.com/videos/alpha",
    destination: "local",
    status: "completed",
    updatedAt: "2026-07-22T10:02:00Z",
    logs: [
      { timestamp: "2026-07-22T10:00:00Z", level: "info", message: "Transfer started." },
      { timestamp: "2026-07-22T10:02:00Z", level: "info", message: "Download completed." },
    ],
  },
  {
    id: "job-b",
    sourcePageURL: "https://provider.test/watch/beta",
    destination: "webdav:remote-1",
    status: "failed",
    updatedAt: "2026-07-22T10:01:00Z",
    logs: [{ timestamp: "2026-07-22T10:01:00Z", level: "error", message: "WebDAV upload failed." }],
  },
];

test("deriveActivityEvents flattens durable job logs newest first", () => {
  const events = deriveActivityEvents(jobs);
  assert.deepEqual(events.map((event) => event.message), ["Download completed.", "WebDAV upload failed.", "Transfer started."]);
  assert.equal(events[1].jobId, "job-b");
  assert.equal(events[1].title, "beta");
});

test("deriveActivityEvents classifies attention and destination events", () => {
  const events = deriveActivityEvents(jobs);
  assert.equal(events[0].severity, "success");
  assert.equal(events[1].severity, "error");
  assert.equal(events[1].category, "destination");
});

test("filterActivityEvents combines attention, category, and text search", () => {
  const events = deriveActivityEvents(jobs);
  assert.deepEqual(filterActivityEvents(events, { filter: "attention", query: "webdav" }).map((event) => event.jobId), ["job-b"]);
  assert.equal(filterActivityEvents(events, { filter: "transfer", query: "" }).length, 2);
});
