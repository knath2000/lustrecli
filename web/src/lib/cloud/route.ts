import { DeviceContractError, deviceError } from "./device-contract";

export function jsonError(error: unknown) {
  if (error instanceof Error && error.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Sign in to manage Lustre devices." } }, { status: 401 });
  if (error instanceof Error && error.message === "email_unverified") return Response.json({ error: { code: "email_unverified", message: "Verify your email before creating a pairing code." } }, { status: 403 });
  const payload = deviceError(error); const code = payload.error.code;
  const status = code === "rate_limited" ? 429 : code === "device_not_found" ? 404 : code === "already_enrolled" || code === "conflict" ? 409 : code === "internal_error" ? 500 : 400;
  return Response.json(payload, { status });
}
export async function requestBody(request: Request, maximumBytes = 16_384): Promise<Record<string, unknown>> {
  const size = Number(request.headers.get("content-length") ?? "0");
  if (size > maximumBytes) throw new DeviceContractError("invalid_request", "Request body is too large.");
  const value: unknown = await request.json();
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DeviceContractError("invalid_request", "Request body must be an object.");
  return value as Record<string, unknown>;
}
export const cloudOrigin = () => process.env.LUSTRE_CLOUD_ORIGIN ?? "http://localhost:3000";
