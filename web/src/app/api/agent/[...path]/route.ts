import { buildAgentURL } from "@/lib/agent-proxy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = { params: Promise<{ path: string[] }> };

async function proxy(request: Request, context: RouteContext): Promise<Response> {
  const { path } = await context.params;
  const apiPath = `/${path.map(encodeURIComponent).join("/")}`;
  const authorization = request.headers.get("authorization")?.trim();

  if (!authorization?.startsWith("Bearer ")) {
    return Response.json({ error: "Paste the local agent token before connecting." }, { status: 401 });
  }

  let target: URL;
  try {
    target = buildAgentURL(apiPath);
  } catch {
    return Response.json({ error: "Invalid local agent path." }, { status: 400 });
  }

  try {
    const upstream = await fetch(target, {
      method: request.method,
      headers: {
        Authorization: authorization,
        ...(request.headers.get("content-type") ? { "Content-Type": request.headers.get("content-type")! } : {}),
      },
      body: ["GET", "HEAD"].includes(request.method) ? undefined : await request.arrayBuffer(),
      cache: "no-store",
    });
    const headers = new Headers();
    const contentType = upstream.headers.get("content-type");
    if (contentType) headers.set("content-type", contentType);
    return new Response(await upstream.arrayBuffer(), { status: upstream.status, headers });
  } catch {
    return Response.json(
      { error: "The local Lustre agent is unavailable. Start lustre-agent, then try again." },
      { status: 503 },
    );
  }
}

export const GET = proxy;
export const POST = proxy;
export const DELETE = proxy;
