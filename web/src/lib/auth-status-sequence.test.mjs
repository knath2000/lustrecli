import assert from "node:assert/strict";
import test from "node:test";
import { AuthStatusSequence } from "./auth-status-sequence.ts";

test("a stale poll cannot overwrite a newer auth action", () => {
  const sequence = new AuthStatusSequence();
  const poll = sequence.beginPoll();
  const action = sequence.beginAction();
  assert.equal(sequence.acceptsPoll(poll), false);
  assert.equal(sequence.acceptsAction(action), true);
});

test("an older auth action cannot overwrite a newer cancellation", () => {
  const sequence = new AuthStatusSequence();
  const login = sequence.beginAction();
  const cancel = sequence.beginAction();
  assert.equal(sequence.acceptsAction(login), false);
  assert.equal(sequence.acceptsAction(cancel), true);
});
