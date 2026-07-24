import assert from "node:assert/strict";
import test from "node:test";

import { pornHubAuthAction, pornHubAuthLabel, pornHubAuthMutationMessage } from "./pornhub-auth-model.ts";

test("PornHub auth UI model maps live login states to truthful labels and actions", () => {
  assert.deepEqual(
    [undefined, "signingIn", "signedIn", "expired"].map((state) => [pornHubAuthLabel(state), pornHubAuthAction(state)]),
    [["Signed out", "signIn"], ["Signing in", "cancel"], ["Signed in", "signOut"], ["Expired", "signIn"]],
  );
});

test("PornHub auth mutation messages use the returned state instead of stale local state", () => {
  assert.equal(pornHubAuthMutationMessage(true, "signedOut"), "PornHub sign-in cancelled.");
  assert.equal(pornHubAuthMutationMessage(true, "signedIn"), "PornHub sign-in completed.");
  assert.equal(pornHubAuthMutationMessage(false, "signedOut"), "PornHub session removed from this Mac.");
});
