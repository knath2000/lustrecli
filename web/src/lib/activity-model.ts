export type ActivitySeverity = "info" | "success" | "warning" | "error";
export type ActivityCategory = "transfer" | "provider" | "destination";
export type ActivityFilter = "all" | "attention" | ActivitySeverity | ActivityCategory;

type AgentDate = string | number;
type ActivityLog = { timestamp: AgentDate; level: "info" | "error"; message: string };
type ActivityJob = { id: string; sourcePageURL: string; preferredQualityLabel?: string; destination: string; status: string; updatedAt: AgentDate; logs?: ActivityLog[] };

export type ActivityEvent = {
  id: string;
  timestamp: AgentDate;
  milliseconds: number;
  severity: ActivitySeverity;
  category: ActivityCategory;
  message: string;
  jobId: string;
  title: string;
  sourcePageURL: string;
  destination: string;
  status: string;
};

const foundationReferenceDateMilliseconds = Date.UTC(2001, 0, 1);
function dateMilliseconds(value: AgentDate) {
  if (typeof value === "number") return foundationReferenceDateMilliseconds + value * 1000;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? Number.NEGATIVE_INFINITY : parsed;
}

function jobTitle(sourcePageURL: string) {
  try {
    const url = new URL(sourcePageURL);
    return decodeURIComponent(url.pathname.split("/").filter(Boolean).at(-1) || url.hostname);
  } catch {
    return sourcePageURL;
  }
}

function severityFor(log: ActivityLog): ActivitySeverity {
  if (log.level === "error" || /fail(?:ed|ure)?|timed out|unavailable/i.test(log.message)) return "error";
  if (/verification|required|warning|retry/i.test(log.message)) return "warning";
  if (/completed|succeeded|saved|ready/i.test(log.message)) return "success";
  return "info";
}

function categoryFor(message: string): ActivityCategory {
  if (/webdav|destination|upload|remote path/i.test(message)) return "destination";
  if (/provider|resolve|quality|stream|source page/i.test(message)) return "provider";
  return "transfer";
}

export function deriveActivityEvents(jobs: ActivityJob[]): ActivityEvent[] {
  return jobs.flatMap((job) => (job.logs ?? []).map((log, index) => ({
    id: `${job.id}:${index}:${dateMilliseconds(log.timestamp)}`,
    timestamp: log.timestamp,
    milliseconds: dateMilliseconds(log.timestamp),
    severity: severityFor(log),
    category: categoryFor(log.message),
    message: log.message,
    jobId: job.id,
    title: jobTitle(job.sourcePageURL),
    sourcePageURL: job.sourcePageURL,
    destination: job.destination,
    status: job.status,
  }))).sort((a, b) => b.milliseconds - a.milliseconds);
}

export function filterActivityEvents(events: ActivityEvent[], options: { filter: ActivityFilter; query: string }): ActivityEvent[] {
  const query = options.query.trim().toLocaleLowerCase();
  return events.filter((event) => {
    const matchesFilter = options.filter === "all"
      || (options.filter === "attention" && (event.severity === "warning" || event.severity === "error"))
      || event.severity === options.filter
      || event.category === options.filter;
    if (!matchesFilter) return false;
    if (!query) return true;
    return [event.message, event.title, event.jobId, event.sourcePageURL, event.status]
      .some((value) => value.toLocaleLowerCase().includes(query));
  });
}
