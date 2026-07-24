export type PornHubAuthState = "signedOut" | "signingIn" | "signedIn" | "expired";

export function pornHubAuthLabel(state: PornHubAuthState | undefined): string {
  if (state === "signedIn") return "Signed in";
  if (state === "signingIn") return "Signing in";
  if (state === "expired") return "Expired";
  return "Signed out";
}

export function pornHubAuthAction(state: PornHubAuthState | undefined): "signIn" | "cancel" | "signOut" {
  if (state === "signedIn") return "signOut";
  if (state === "signingIn") return "cancel";
  return "signIn";
}

export function pornHubAuthMutationMessage(wasSigningIn: boolean, returnedState: PornHubAuthState): string {
  if (wasSigningIn) return returnedState === "signedOut" ? "PornHub sign-in cancelled." : "PornHub sign-in completed.";
  return "PornHub session removed from this Mac.";
}
