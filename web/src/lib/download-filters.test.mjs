import assert from "node:assert/strict";
import test from "node:test";

import { filterAndSortJobs, jobProgressPercent, jobStatusCounts } from "./download-filters.ts";

const jobs = [
  { id: "completed", sourcePageURL: "https://example.com/archive.zip", message: "Completed", destination: "local", status: "completed", updatedAt: 100 },
  { id: "failed", sourcePageURL: "https://media.example/nebula", message: "Provider timed out", destination: "webdav:seedbox", status: "failed", updatedAt: 300 },
  { id: "running", sourcePageURL: "https://example.com/live", message: "Downloading", preferredQualityLabel: "1080p", destination: "local", status: "running", updatedAt: 200 },
  { id: "paused", sourcePageURL: "https://example.com/paused", message: "Paused", destination: "webdav:seedbox", status: "paused", updatedAt: 250 },
];

test("filterAndSortJobs sorts newest first by default", () => {
  assert.deepEqual(filterAndSortJobs(jobs, {}).map((job) => job.id), ["failed", "paused", "running", "completed"]);
});

test("filterAndSortJobs treats queued, running, and paused jobs as active", () => {
  assert.deepEqual(filterAndSortJobs(jobs, { status: "active" }).map((job) => job.id), ["paused", "running"]);
});

test("filterAndSortJobs presents queued jobs in durable priority order", () => {
  const queued = [
    { ...jobs[0], id: "later", status: "queued", queuePriority: 1 },
    { ...jobs[0], id: "first", status: "queued", queuePriority: 0 },
    { ...jobs[0], id: "unranked", status: "queued", queuePriority: undefined },
  ];
  assert.deepEqual(filterAndSortJobs(queued, { status: "queued" }).map((job) => job.id), ["first", "later", "unranked"]);
});

test("filterAndSortJobs combines status, destination, and text search", () => {
  assert.deepEqual(filterAndSortJobs(jobs, { status: "failed", destination: "webdav:seedbox", query: "provider" }).map((job) => job.id), ["failed"]);
  assert.deepEqual(filterAndSortJobs(jobs, { query: "1080P" }).map((job) => job.id), ["running"]);
});

test("jobStatusCounts returns tab-ready totals", () => {
  assert.deepEqual(jobStatusCounts(jobs), { all: 4, active: 2, queued: 0, running: 1, paused: 1, completed: 1, failed: 1, cancelled: 0, verificationRequired: 0 });
});

test("jobProgressPercent clamps malformed or transient API progress", () => {
  assert.equal(jobProgressPercent(-0.1), undefined);
  assert.equal(jobProgressPercent(0.456), 46);
  assert.equal(jobProgressPercent(1.4), 100);
  assert.equal(jobProgressPercent(Number.NaN), undefined);
});
