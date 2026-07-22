type AgentDate = string | number;

const foundationReferenceDateMilliseconds = Date.UTC(2001, 0, 1);

function agentDateMilliseconds(value: AgentDate): number {
  if (typeof value === "number") return foundationReferenceDateMilliseconds + value * 1000;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? Number.NEGATIVE_INFINITY : parsed;
}

export type DownloadFilterStatus = "all" | "active" | "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired";

type FilterableJob = {
  id: string;
  sourcePageURL: string;
  preferredQualityLabel?: string;
  destination: string;
  status: Exclude<DownloadFilterStatus, "all" | "active">;
  message: string;
  updatedAt: AgentDate;
};

type DownloadFilters = {
  status?: DownloadFilterStatus;
  query?: string;
  destination?: string;
};

const activeStatuses = new Set(["queued", "running", "paused"]);

export function filterAndSortJobs<T extends FilterableJob>(jobs: T[], filters: DownloadFilters): T[] {
  const status = filters.status ?? "all";
  const query = filters.query?.trim().toLocaleLowerCase() ?? "";

  return jobs
    .filter((job) => status === "all" || (status === "active" ? activeStatuses.has(job.status) : job.status === status))
    .filter((job) => !filters.destination || filters.destination === "all" || job.destination === filters.destination)
    .filter((job) => !query || [job.id, job.sourcePageURL, job.preferredQualityLabel, job.message].some((value) => value?.toLocaleLowerCase().includes(query)))
    .sort((a, b) => agentDateMilliseconds(b.updatedAt) - agentDateMilliseconds(a.updatedAt));
}

export function jobStatusCounts(jobs: FilterableJob[]) {
  const counts = {
    all: jobs.length,
    active: 0,
    queued: 0,
    running: 0,
    paused: 0,
    completed: 0,
    failed: 0,
    cancelled: 0,
    verificationRequired: 0,
  };

  for (const job of jobs) {
    counts[job.status] += 1;
    if (activeStatuses.has(job.status)) counts.active += 1;
  }

  return counts;
}

export function jobProgressLabel(status: FilterableJob["status"], progress?: number): string {
  const percent = jobProgressPercent(progress);
  if (percent !== undefined) return `${percent}%`;
  if (status === "running") return "Working";
  return status.replace(/([A-Z])/g, " $1").replace(/^./, (character) => character.toUpperCase());
}

export function jobProgressPercent(progress?: number): number | undefined {
  if (progress === undefined || !Number.isFinite(progress)) return undefined;
  return Math.min(100, Math.max(0, Math.round(progress * 100)));
}
