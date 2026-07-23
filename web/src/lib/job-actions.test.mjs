import assert from "node:assert/strict";
import test from "node:test";
import { availableJobActions, jobActionLabel } from "./job-actions.ts";

test("force start is available only for queued jobs", () => {
  assert.deepEqual(availableJobActions("queued"), ["forceStart", "pause", "cancel"]);
  for (const status of ["running", "paused", "completed", "failed", "cancelled", "verificationRequired"]) {
    assert.equal(availableJobActions(status).includes("forceStart"), false);
  }
});

test("force start uses a human label", () => {
  assert.equal(jobActionLabel("forceStart"), "Force start");
  assert.equal(jobActionLabel("retry"), "Retry");
});
