import assert from "node:assert/strict";
import test from "node:test";
import { errorResponse } from "./resolver";

test("maps missing authentication to a 401 response", async () => {
  const response = errorResponse(new Error("unauthenticated"));
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: { code: "unauthenticated", message: "Sign in required." } });
});

test("maps an unverified email to a 403 response", async () => {
  const response = errorResponse(new Error("email_unverified"));
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: { code: "email_unverified", message: "Verified email required." } });
});
