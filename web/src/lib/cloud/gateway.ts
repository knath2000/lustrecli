import "server-only";

export function requireGateway(request: Request) {
  const expected = process.env.LUSTRE_DEVICE_TOKEN_SECRET;
  if (!expected || request.headers.get("X-Lustre-Gateway-Secret") !== expected) throw new Error("unauthenticated");
}
