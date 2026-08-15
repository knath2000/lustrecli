import { resolveRequestSchema } from "@/lib/lustre-watch/contracts";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { errorResponse } from "@/lib/lustre-watch/resolver";

export async function POST(request: Request) {
  try {
    await watchAccountID();
    const input = resolveRequestSchema.safeParse(await request.json());
    if (!input.success) return Response.json({ error: { code: "invalid_request", message: "A supported source URL is required." } }, { status: 400 });
    const origin = process.env.RESOLVER_ORIGIN;
    const key = process.env.MODAL_PROXY_KEY;
    const secret = process.env.MODAL_PROXY_SECRET;
    if (!origin || !key || !secret) return Response.json({ error: { code: "provider_unavailable", message: "Resolver is not configured." } }, { status: 503 });
    const upstream = await fetch(new URL("/internal/resolve/stream", origin), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Modal-Key": key,
        "Modal-Secret": secret,
      },
      body: JSON.stringify(input.data),
      cache: "no-store",
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(55_000)]),
    });
    if (!upstream.ok || !upstream.body) {
      const body = await upstream.json().catch(() => ({}));
      return Response.json({ error: body?.error ?? { code: "provider_unavailable", message: "Resolver stream is unavailable." } }, { status: upstream.status });
    }
    return new Response(upstream.body, {
      headers: {
        "Content-Type": "application/x-ndjson; charset=utf-8",
        "Cache-Control": "no-store, no-transform",
        "X-Accel-Buffering": "no",
      },
    });
  } catch (reason) { return errorResponse(reason); }
}
