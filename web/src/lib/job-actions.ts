export type JobStatus = "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired";
export type JobAction = "pause" | "resume" | "cancel" | "retry" | "forceStart";

export function availableJobActions(status: JobStatus): JobAction[] {
  if (status === "queued") return ["forceStart", "pause", "cancel"];
  if (status === "running") return ["pause", "cancel"];
  if (status === "paused") return ["resume", "cancel"];
  if (["failed", "cancelled", "verificationRequired"].includes(status)) {
    return ["retry", ...(status === "verificationRequired" ? ["cancel" as const] : [])];
  }
  return [];
}

export function jobActionLabel(action: JobAction): string {
  return action === "forceStart" ? "Force start" : action[0].toUpperCase() + action.slice(1);
}
