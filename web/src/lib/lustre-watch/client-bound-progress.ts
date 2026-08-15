import type { ResolutionProgressEvent } from "@/lib/lustre-watch/contracts";

export function displayProgressEvent(event: ResolutionProgressEvent): ResolutionProgressEvent {
  if (event.type !== "completed" || !event.resolution.clientResolverURL) return event;
  return {
    type: "validating",
    at: event.at,
    message: `Refreshing ${event.resolution.qualities.length} HQPorner candidate${event.resolution.qualities.length === 1 ? "" : "s"} on this device.`,
  };
}
