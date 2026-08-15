import type { FeedPlaybackResolution } from "@/lib/lustre-watch/contracts";
import { refreshHQPornerSources } from "./hqporner-refresh";

type Fetcher = typeof fetch;

export async function resolveClientBoundSources(resolution: FeedPlaybackResolution, fetcher: Fetcher = fetch, signal?: AbortSignal): Promise<FeedPlaybackResolution> {
  if (!resolution.clientResolverURL) return resolution;
  const qualities = await refreshHQPornerSources(resolution.clientResolverURL, fetcher, signal);
  return { ...resolution, qualities };
}
