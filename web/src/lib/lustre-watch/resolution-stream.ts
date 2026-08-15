import { resolutionProgressEventSchema, type ResolutionProgressEvent } from "@/lib/lustre-watch/contracts";

export async function readResolutionStream(
  response: Response,
  onEvent: (event: ResolutionProgressEvent) => void,
): Promise<number> {
  if (!response.ok || !response.body) throw new Error("Resolution stream is unavailable.");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let count = 0;
  while (true) {
    const { done, value } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const event = resolutionProgressEventSchema.parse(JSON.parse(line));
      count += 1;
      onEvent(event);
    }
    if (done) break;
  }
  if (buffer.trim()) {
    const event = resolutionProgressEventSchema.parse(JSON.parse(buffer));
    count += 1;
    onEvent(event);
  }
  return count;
}
