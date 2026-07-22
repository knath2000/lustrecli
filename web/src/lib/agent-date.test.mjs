import assert from "node:assert/strict";
import test from "node:test";

import { agentDateMilliseconds } from "./agent-date.ts";

test("agentDateMilliseconds converts Foundation reference-date seconds", () => {
  assert.equal(agentDateMilliseconds(0), Date.UTC(2001, 0, 1));
  assert.equal(agentDateMilliseconds(804_531_599.5), Date.UTC(2026, 5, 30, 16, 59, 59, 500));
});

test("agentDateMilliseconds accepts ISO-8601 API dates", () => {
  assert.equal(agentDateMilliseconds("2026-07-22T06:30:59Z"), Date.UTC(2026, 6, 22, 6, 30, 59));
});

test("agentDateMilliseconds makes invalid values sort last", () => {
  assert.equal(agentDateMilliseconds("not-a-date"), 0);
});
