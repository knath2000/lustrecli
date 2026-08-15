import { requireCurrentAccount } from "@/lib/auth/current-account";
import { cachedLibrarySnapshot } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

export async function GET(_request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount();
    const { deviceID } = await context.params;
    const snapshot = await cachedLibrarySnapshot(account.id, deviceID);
    return Response.json({
      library: snapshot ? {
        revision: snapshot.revision,
        items: snapshot.items,
        syncedAt: snapshot.syncedAt.toISOString(),
      } : null,
    }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return jsonError(error);
  }
}
