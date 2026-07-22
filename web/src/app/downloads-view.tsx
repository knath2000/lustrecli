"use client";

import { useMemo, useState } from "react";
import { agentDateMilliseconds, type AgentDate } from "@/lib/agent-date";
import { filterAndSortJobs, jobProgressLabel, jobStatusCounts, type DownloadFilterStatus } from "@/lib/download-filters";

type JobStatus = "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired";
type JobAction = "pause" | "resume" | "cancel" | "retry";
type JobLog = { timestamp: AgentDate; level: "info" | "error"; message: string };
export type DownloadJob = { id: string; sourcePageURL: string; preferredQualityLabel?: string; destination: string; status: JobStatus; message: string; progress?: number; downloadedBytes?: number; totalBytes?: number; logs?: JobLog[]; updatedAt: AgentDate };
export type Destination = { id: string; name: string; baseURL: string; remotePath: string };

type DownloadsViewProps = {
  jobs: DownloadJob[];
  destinations: Destination[];
  error: string | null;
  onQueue: () => void;
  onAction: (job: DownloadJob, action: JobAction) => Promise<void>;
};

const statusTabs: Array<{ value: DownloadFilterStatus; label: string }> = [
  { value: "all", label: "All" },
  { value: "active", label: "Active" },
  { value: "queued", label: "Queued" },
  { value: "running", label: "Running" },
  { value: "paused", label: "Paused" },
  { value: "completed", label: "Completed" },
  { value: "failed", label: "Failed" },
  { value: "cancelled", label: "Cancelled" },
  { value: "verificationRequired", label: "Verification" },
];

function jobTitle(job: DownloadJob) {
  try {
    const url = new URL(job.sourcePageURL);
    return decodeURIComponent(url.pathname.split("/").filter(Boolean).at(-1) || url.hostname);
  } catch {
    return job.sourcePageURL;
  }
}

function formatBytes(bytes?: number) {
  if (bytes === undefined) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return `${value.toFixed(unit ? 1 : 0)} ${units[unit]}`;
}

function displayStatus(status: JobStatus) {
  return status.replace(/([A-Z])/g, " $1").trim();
}

function destinationName(job: DownloadJob, destinations: Destination[]) {
  if (job.destination === "local") return "Local Downloads";
  const id = job.destination.replace(/^webdav:/i, "");
  return destinations.find((destination) => destination.id.toLowerCase() === id.toLowerCase())?.name ?? "Remote WebDAV";
}

function availableActions(status: JobStatus): JobAction[] {
  if (status === "queued" || status === "running") return ["pause", "cancel"];
  if (status === "paused") return ["resume", "cancel"];
  if (["failed", "cancelled", "verificationRequired"].includes(status)) return ["retry", ...(status === "verificationRequired" ? ["cancel" as const] : [])];
  return [];
}

function SearchGlyph() {
  return <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></svg>;
}

export function DownloadsView({ jobs, destinations, error, onQueue, onAction }: DownloadsViewProps) {
  const [status, setStatus] = useState<DownloadFilterStatus>("all");
  const [query, setQuery] = useState("");
  const [destination, setDestination] = useState("all");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [workingAction, setWorkingAction] = useState<JobAction | null>(null);

  const filteredJobs = useMemo(() => filterAndSortJobs(jobs, { status, query, destination }), [jobs, status, query, destination]);
  const counts = useMemo(() => jobStatusCounts(jobs), [jobs]);
  const selectedJob = filteredJobs.find((job) => job.id === selectedId) ?? filteredJobs[0] ?? null;


  const act = async (job: DownloadJob, action: JobAction) => {
    setWorkingAction(action);
    try { await onAction(job, action); }
    finally { setWorkingAction(null); }
  };

  return <div className="downloads-page">
    <header className="downloads-header">
      <div><p className="eyebrow">Durable transfer history</p><h2>Downloads</h2><p>Inspect and operate every job owned by this Lustre agent.</p></div>
      <button className="queue-button" onClick={onQueue}>＋ Queue download</button>
    </header>

    <nav className="status-tabs" aria-label="Filter downloads by status">
      {statusTabs.map((tab) => <button key={tab.value} className={status === tab.value ? "active" : ""} onClick={() => setStatus(tab.value)}>{tab.label}<span>{counts[tab.value]}</span></button>)}
    </nav>

    <section className="download-toolbar" aria-label="Download filters">
      <label className="download-search"><SearchGlyph /><span className="sr-only">Search downloads</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search URL, quality, message, or job ID" /></label>
      <label><span>Destination</span><select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="all">All destinations</option><option value="local">Local Downloads</option>{destinations.map((item) => <option key={item.id} value={`webdav:${item.id}`}>{item.name}</option>)}</select></label>
      <p>{filteredJobs.length} of {jobs.length} jobs</p>
    </section>

    {error && <p className="inline-error downloads-error" role="alert">{error}</p>}

    <div className="downloads-layout">
      <section className="download-ledger glass-panel" aria-label="Downloads list">
        <div className="ledger-head"><span>Transfer</span><span>Status</span><span>Progress</span><span>Destination</span><span>Updated</span></div>
        <div className="ledger-body">
          {filteredJobs.map((job) => {
            const progress = job.progress === undefined ? undefined : Math.round(job.progress * 100);
            const visualProgress = progress ?? (job.status === "running" ? 34 : job.status === "completed" ? 100 : 0);
            return <button key={job.id} className={`download-row status-${job.status} ${selectedJob?.id === job.id ? "selected" : ""}`} onClick={() => setSelectedId(job.id)} aria-pressed={selectedJob?.id === job.id}>
              <span className="download-name"><i>↓</i><span><strong>{jobTitle(job)}</strong><small>{job.preferredQualityLabel || job.sourcePageURL}</small></span></span>
              <span className="download-state"><i />{displayStatus(job.status)}</span>
              <span className="download-progress"><span><i style={{ width: `${visualProgress}%` }} className={progress === undefined && job.status === "running" ? "indeterminate" : ""} /></span><small>{jobProgressLabel(job.status, job.progress)}</small></span>
              <span className="download-destination">{destinationName(job, destinations)}</span>
              <time dateTime={new Date(agentDateMilliseconds(job.updatedAt)).toISOString()}>{new Date(agentDateMilliseconds(job.updatedAt)).toLocaleDateString([], { month: "short", day: "numeric" })}<small>{new Date(agentDateMilliseconds(job.updatedAt)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</small></time>
            </button>;
          })}
          {!filteredJobs.length && <div className="downloads-empty"><span>↓</span><h3>No matching downloads</h3><p>Adjust the filters or queue a new transfer.</p><button className="queue-button" onClick={onQueue}>Queue download</button></div>}
        </div>
      </section>

      <aside className="transfer-inspector glass-panel" aria-label="Transfer inspector">
        {selectedJob ? <>
          <header className="inspector-heading"><div><p className="eyebrow">Transfer inspector</p><h3>{jobTitle(selectedJob)}</h3><p className="inspector-id">ID · {selectedJob.id}</p></div><span className={`inspector-status status-${selectedJob.status}`}>{displayStatus(selectedJob.status)}</span></header>
          <section className="inspector-progress"><div><span>{formatBytes(selectedJob.downloadedBytes)}</span><strong>{selectedJob.progress === undefined ? displayStatus(selectedJob.status) : `${Math.round(selectedJob.progress * 100)}%`}</strong><span>{selectedJob.totalBytes ? formatBytes(selectedJob.totalBytes) : "Total unavailable"}</span></div><div className="progress-track"><span className={`progress-fill ${selectedJob.progress === undefined ? "indeterminate" : ""}`} style={selectedJob.progress === undefined ? undefined : { width: `${Math.round(selectedJob.progress * 100)}%` }} /></div><p>{selectedJob.message}</p></section>
          <dl className="inspector-metadata"><div><dt>Source</dt><dd><a href={selectedJob.sourcePageURL} target="_blank" rel="noreferrer">{selectedJob.sourcePageURL}</a></dd></div><div><dt>Quality</dt><dd>{selectedJob.preferredQualityLabel || "Automatic"}</dd></div><div><dt>Destination</dt><dd>{destinationName(selectedJob, destinations)}</dd></div><div><dt>Updated</dt><dd>{new Date(agentDateMilliseconds(selectedJob.updatedAt)).toLocaleString()}</dd></div></dl>
          <section className="inspector-log"><header><span>Worker event log</span><b>{selectedJob.logs?.length ?? 0} events</b></header>{selectedJob.logs?.length ? <ol>{[...selectedJob.logs].sort((a, b) => agentDateMilliseconds(a.timestamp) - agentDateMilliseconds(b.timestamp)).map((log, index) => <li key={`${log.timestamp}-${index}`}><time>{new Date(agentDateMilliseconds(log.timestamp)).toLocaleTimeString()}</time><b className={log.level === "error" ? "error" : ""}>{log.level}</b><span>{log.message}</span></li>)}</ol> : <p>No worker events recorded for this job.</p>}</section>
          {availableActions(selectedJob.status).length > 0 && <footer className="inspector-actions">{availableActions(selectedJob.status).map((action) => <button key={action} className={action === "cancel" ? "danger" : ""} disabled={workingAction !== null} onClick={() => void act(selectedJob, action)}>{workingAction === action ? `${action}…` : action}</button>)}</footer>}
        </> : <div className="inspector-empty"><span>◎</span><h3>Select a transfer</h3><p>Choose a download to inspect its live state and worker log.</p></div>}
      </aside>
    </div>
  </div>;
}
