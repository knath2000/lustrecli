import assert from "node:assert/strict";
import test from "node:test";

import { normalizePollingInterval, pollingIntervalLabel } from "./settings-model.ts";

test("normalizePollingInterval accepts only supported live refresh intervals", () => {
  assert.equal(normalizePollingInterval(2000), 2000);
  assert.equal(normalizePollingInterval(5000), 5000);
  assert.equal(normalizePollingInterval(10000), 10000);
  assert.equal(normalizePollingInterval(3000), 2000);
});

test("pollingIntervalLabel describes refresh cadence", () => {
  assert.equal(pollingIntervalLabel(2000), "Every 2 seconds");
  assert.equal(pollingIntervalLabel(10000), "Every 10 seconds");
});
