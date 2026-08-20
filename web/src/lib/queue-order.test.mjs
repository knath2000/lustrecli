import assert from "node:assert/strict";
import test from "node:test";
import { moveQueuedJob, moveQueuedJobByOffset } from "./queue-order.ts";

test("moves a queued job to the dropped position without losing IDs", () => {
  assert.deepEqual(moveQueuedJob(["a", "b", "c", "d"], "d", "b"), ["a", "d", "b", "c"]);
  assert.deepEqual(moveQueuedJob(["a", "b", "c", "d"], "a", "c"), ["b", "c", "a", "d"]);
});

test("keyboard offsets stop at queue boundaries", () => {
  assert.deepEqual(moveQueuedJobByOffset(["a", "b", "c"], "b", -1), ["b", "a", "c"]);
  assert.deepEqual(moveQueuedJobByOffset(["a", "b", "c"], "a", -1), ["a", "b", "c"]);
  assert.deepEqual(moveQueuedJobByOffset(["a", "b", "c"], "c", 1), ["a", "b", "c"]);
});
