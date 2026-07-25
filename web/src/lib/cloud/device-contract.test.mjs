import assert from "node:assert/strict";
import test from "node:test";
import { normalizePairingCode, validateDisplayName } from "./device-contract.ts";

test("pairing codes normalize grouped Crockford Base32", () => {
  assert.equal(normalizePairingCode("abcde-fghjk-mnpqr-stvwz"), "ABCDEFGHJKMNPQRSTVWZ");
  assert.throws(() => normalizePairingCode("0000-0000"));
});
test("display names are trimmed and bounded", () => {
  assert.equal(validateDisplayName("  Kalyan's Mac  "), "Kalyan's Mac");
  assert.throws(() => validateDisplayName(""));
  assert.throws(() => validateDisplayName("x".repeat(81)));
});
