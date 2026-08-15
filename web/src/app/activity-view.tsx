"use client";

import { useMemo, useState } from "react";
import { deriveActivityEvents, filterActivityEvents, type ActivityEvent, type ActivityFilter } from "@/lib/activity-model";
import type { AgentDate } from "@/lib/agent-date";

type ActivityJob = { id: string; sourcePageURL: string; preferredQualityLabel?: string; destination: string; status: string; updatedAt: AgentDate; logs?: Array<{ timestamp: AgentDate; level: "info" | "error"; message: string }> };
type ActivityDestination = { id: string; name: string };

type Props = { jobs: ActivityJob[]; destinations: ActivityDestination[]; error: string | null; onOpenDownloads: (jobId?: string) => void };

const filters: Array<{ value: ActivityFilter; label: string }> = [
  { value: "all", label: "All activity" },
  { value: "attention", label: "Needs attention" },
  { value: "transfer", label: "Transfers" },
  { value: "provider", label: "Providers" },
  { value: "destination", label: "Destinations" },
];

function destinationName(event: ActivityEvent, destinations: ActivityDestination[]) {
  if (!/^(webdav|gdrive):/i.test(event.destination)) return "Local Downloads";
  const id = event.destination.replace(/^(webdav|gdrive):/i, "");
  return destinations.find((item) => item.id.toLowerCase() === id.toLowerCase())?.name ?? (/^gdrive:/i.test(event.destination) ? "Removed Google Drive profile" : "Removed WebDAV profile");
}

function dayLabel(milliseconds: number) {
  const date = new Date(milliseconds);
  const today = new Date();
  const yesterday = new Date(); yesterday.setDate(today.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return "Today";
  if (date.toDateString() === yesterday.toDateString()) return "Yesterday";
  return date.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" });
}

function categoryLabel(event: ActivityEvent) {
  return event.category === "provider" ? "Provider resolution" : event.category === "destination" ? "Destination operation" : "Transfer lifecycle";
}

export function ActivityView({ jobs, destinations, error, onOpenDownloads }: Props) {
  const [filter, setFilter] = useState<ActivityFilter>("all");
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const events = useMemo(() => deriveActivityEvents(jobs), [jobs]);
  const visible = useMemo(() => filterActivityEvents(events, { filter, query }), [events, filter, query]);
  const selected = visible.find((event) => event.id === selectedId) ?? visible[0] ?? null;
  const attentionCount = events.filter((event) => event.severity === "warning" || event.severity === "error").length;


  return <div className="activity-page">
    <header className="activity-header"><div><p className="eyebrow">Operational audit trail</p><h2>Activity</h2><p>Follow durable worker events across transfers, providers, and destinations.</p></div><button className="secondary-button" onClick={() => onOpenDownloads()}>Open downloads</button></header>
    <section className="activity-summary" aria-label="Activity summary"><div><span>Recorded events</span><strong>{events.length}</strong></div><div><span>Needs attention</span><strong className={attentionCount ? "attention" : ""}>{attentionCount}</strong></div><div><span>Tracked jobs</span><strong>{jobs.length}</strong></div><p><i /> Live from bounded agent job logs</p></section>
    <nav className="activity-tabs" aria-label="Filter activity">{filters.map((item) => <button className={filter === item.value ? "active" : ""} key={item.value} onClick={() => setFilter(item.value)}>{item.label}{item.value === "attention" && <span>{attentionCount}</span>}</button>)}</nav>
    <label className="activity-search"><span aria-hidden>⌕</span><span className="sr-only">Search activity</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search event messages, source titles, or job IDs" /><small>{visible.length} event{visible.length === 1 ? "" : "s"}</small></label>
    {error && <p className="inline-error" role="alert">{error}</p>}
    <div className="activity-layout">
      <section className="activity-timeline glass-panel" aria-label="Activity timeline">
        {visible.map((event, index) => {
          const label = dayLabel(event.milliseconds); const showDay = index === 0 || dayLabel(visible[index - 1].milliseconds) !== label;
          return <div key={event.id}>{showDay && <h3 className="activity-day">{label}</h3>}<button className={`activity-event severity-${event.severity} ${selected?.id === event.id ? "selected" : ""}`} onClick={() => setSelectedId(event.id)} aria-pressed={selected?.id === event.id}><span className="event-rail"><i /></span><time>{new Date(event.milliseconds).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</time><span className="event-copy"><strong>{event.message}</strong><small>{event.title} · {categoryLabel(event)}</small></span><span className={`event-severity ${event.severity}`}>{event.severity}</span></button></div>;
        })}
        {!visible.length && <div className="activity-empty"><span>⌁</span><h3>No matching events</h3><p>Adjust the filter or search. New durable worker events appear automatically.</p></div>}
      </section>
      <aside className="activity-inspector glass-panel" aria-label="Activity event details">{selected ? <><header><p className="eyebrow">Event inspector</p><h3>{selected.message}</h3><span className={`event-severity ${selected.severity}`}>{selected.severity}</span></header><dl><div><dt>Time</dt><dd>{new Date(selected.milliseconds).toLocaleString()}</dd></div><div><dt>Category</dt><dd>{categoryLabel(selected)}</dd></div><div><dt>Transfer</dt><dd>{selected.title}</dd></div><div><dt>Status</dt><dd>{selected.status.replace(/([A-Z])/g, " $1")}</dd></div><div><dt>Destination</dt><dd>{destinationName(selected, destinations)}</dd></div><div><dt>Job ID</dt><dd className="mono-wrap">{selected.jobId}</dd></div></dl><section><span>Source page</span><a href={selected.sourcePageURL} target="_blank" rel="noreferrer">{selected.sourcePageURL}</a></section><footer><button className="queue-button" onClick={() => onOpenDownloads(selected.jobId)}>Inspect transfer</button></footer></> : <div className="activity-inspector-empty"><span>◎</span><h3>Select an event</h3><p>Choose an activity record to inspect its associated transfer.</p></div>}</aside>
    </div>
    <p className="activity-boundary">This feed currently reflects durable per-job worker logs. Device connectivity, configuration changes, and remote command acknowledgements require a future agent-wide event API.</p>
  </div>;
}
