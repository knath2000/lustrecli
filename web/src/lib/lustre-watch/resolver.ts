import { ResolverError } from "@/lib/lustre-watch/contracts";

export async function resolverRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const origin = process.env.RESOLVER_ORIGIN;
  const key = process.env.MODAL_PROXY_KEY;
  const secret = process.env.MODAL_PROXY_SECRET;
  if (!origin || !key || !secret) throw new ResolverError("provider_unavailable", "Resolver is not configured.", 503);
  let response: Response;
  try {
    response = await fetch(new URL(path, origin), {
      ...init,
      headers: { ...init?.headers, "Modal-Key": key, "Modal-Secret": secret },
      cache: "no-store",
      signal: AbortSignal.timeout(55_000),
    });
  } catch (reason) {
    if (reason instanceof DOMException && reason.name === "TimeoutError") throw new ResolverError("timeout", "Resolver request timed out.", 504);
    throw reason;
  }
  const body = await response.json();
  if (!response.ok) {
    const error = body?.error;
    throw new ResolverError(error?.code ?? "provider_unavailable", error?.message ?? "Resolver unavailable.", response.status);
  }
  return body as T;
}

export function errorResponse(reason: unknown): Response {
  if (reason instanceof ResolverError) return Response.json({ error: { code: reason.code, message: reason.message } }, { status: reason.status });
  if (reason instanceof Response) return reason;
  if (reason instanceof Error && reason.message === "unauthenticated") return Response.json({ error: { code: "unauthenticated", message: "Sign in required." } }, { status: 401 });
  if (reason instanceof Error && reason.message === "email_unverified") return Response.json({ error: { code: "email_unverified", message: "Verified email required." } }, { status: 403 });
  console.error(reason);
  return Response.json({ error: { code: "provider_unavailable", message: "Service unavailable." } }, { status: 500 });
}
