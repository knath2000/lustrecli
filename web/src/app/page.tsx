"use client";

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { agentDateMilliseconds, type AgentDate } from "@/lib/agent-date";
import { jobProgressPercent } from "@/lib/download-filters";
import { availableJobActions, jobActionLabel, type JobAction, type JobStatus } from "@/lib/job-actions";
import type { FeedItem, FeedPage, FeedSite } from "@/lib/feed-model";
import type { PollingInterval } from "@/lib/settings-model";
import { ActivityView } from "./activity-view";
import { DestinationsView, type DestinationProfile } from "./destinations-view";
import { DownloadsView } from "./downloads-view";
import { FeedView } from "./feed-view";
import { SettingsView } from "./settings-view";

type JobLog = { timestamp: AgentDate; level: "info" | "error"; message: string };
type DownloadJob = { id: string; sourcePageURL: string; preferredQualityLabel?: string; destination: string; status: JobStatus; message: string; progress?: number; downloadedBytes?: number; totalBytes?: number; logs?: JobLog[]; updatedAt: AgentDate };
type Destination = DestinationProfile;
type PornHubAuthStatus = { state: "signedOut" | "signingIn" | "signedIn" | "expired"; displayName?: string; lastValidatedAt?: string };

const navigation = [["Devices", "devices"], ["Feed", "feed"], ["Downloads", "downloads"], ["Destinations", "destinations"], ["Activity", "activity"], ["Settings", "settings"]] as const;
const tokenPattern = /^[A-Za-z0-9+/=]+$/;

function Glyph({ name, size = 18 }: { name: string; size?: number }) {
  const props = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.7, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  const shapes: Record<string, React.ReactNode> = {
    cloud: <><path d="M7 18.5h10a4 4 0 0 0 .7-7.94A5.5 5.5 0 0 0 7.1 9.14 4.7 4.7 0 0 0 7 18.5Z" /><path d="M8.5 14.5h7" /></>,
    devices: <><rect x="3" y="5" width="13" height="11" rx="1.5" /><path d="M7 20h5M9.5 16v4M19 8v8M17 10h4M17 14h4" /></>,
    downloads: <><path d="M12 3v11" /><path d="m8 10 4 4 4-4" /><path d="M5 19h14" /></>,
    feed: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m8 9 2.5 2.5L8 14M13 9h4M13 14h4" /></>,
    folder: <><path d="M3.5 7.5h6l2 2h9v8.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z" /><path d="M3.5 7.5V6a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v1.5" /></>,
    activity: <><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M8 16v-4M12 16V8M16 16v-6" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.05 2.05-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56v.09h-2.9v-.09A1.7 1.7 0 0 0 10.85 18.6a1.7 1.7 0 0 0-1.88.34l-.06.06-2.05-2.05.06-.06A1.7 1.7 0 0 0 7.26 15a1.7 1.7 0 0 0-1.56-1.03h-.09v-2.9h.09A1.7 1.7 0 0 0 7.26 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.05-2.05.06.06A1.7 1.7 0 0 0 10.85 6.4a1.7 1.7 0 0 0 1.03-1.56v-.09h2.9v.09A1.7 1.7 0 0 0 15.82 6.4a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.05 2.05-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.09v2.9h-.09A1.7 1.7 0 0 0 19.4 15Z" /></>,
    support: <><circle cx="12" cy="12" r="9" /><path d="M9.5 9a2.6 2.6 0 1 1 4.55 1.72c-.9.94-2.05 1.3-2.05 2.78" /><path d="M12 17h.01" /></>,
    account: <><circle cx="12" cy="8" r="3.2" /><path d="M5 20c.8-3.3 3.1-5 7-5s6.2 1.7 7 5" /></>,
    computer: <><rect x="3.5" y="4.5" width="17" height="12" rx="1.5" /><path d="M8 20h8M12 16.5V20" /></>,
    plus: <><path d="M12 5v14M5 12h14" /></>,
    media: <><rect x="3" y="5" width="18" height="15" rx="2" /><path d="M8 5V3M16 5V3M3 10h18" /><path d="m10 13 5 2.5-5 2.5Z" /></>,
    archive: <><path d="M5 3.5h10l4 4V20a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 4 20V5a1.5 1.5 0 0 1 1-1.5Z" /><path d="M15 3.5V8h4M8 13h8M8 17h5" /></>,
    control: <><path d="M5 7h14M5 17h14" /><circle cx="8" cy="7" r="2" /><circle cx="16" cy="17" r="2" /></>,
    bell: <><path d="M18 10a6 6 0 1 0-12 0c0 7-3 7-3 8.5h18C21 17 18 17 18 10Z" /><path d="M10 21h4" /></>,
    close: <><path d="m6 6 12 12M18 6 6 18" /></>,
    key: <><circle cx="8" cy="15" r="3" /><path d="m10 13 8-8M14 7l3 3M16 5l3 3" /></>,
  };
  return <svg {...props}>{shapes[name] ?? shapes.activity}</svg>;
}

function titleFor(job: DownloadJob) {
  try { return decodeURIComponent(new URL(job.sourcePageURL).pathname.split("/").filter(Boolean).at(-1) || new URL(job.sourcePageURL).hostname); } catch { return job.sourcePageURL; }
}
function formatBytes(bytes?: number) { if (bytes === undefined) return "—"; const units = ["B", "KiB", "MiB", "GiB", "TiB"]; let value = bytes; let unit = 0; while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; } return `${value.toFixed(unit ? 1 : 0)} ${units[unit]}`; }
function destinationName(job: DownloadJob, destinations: Destination[]) { if (job.destination === "local") return "Local Downloads"; const id = job.destination.replace(/^webdav:/i, ""); return destinations.find((destination) => destination.id.toLowerCase() === id.toLowerCase())?.name ?? "Remote WebDAV"; }
async function agentRequest<T>(token: string, path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api/agent${path}`, { ...options, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(options.headers ?? {}) }, cache: "no-store" });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error ?? "The local Lustre agent request failed.");
  return payload as T;
}

function QueueSheet({ destinations, token, onClose, onQueued }: { destinations: Destination[]; token: string; onClose: () => void; onQueued: () => Promise<void> }) {
  const [sourcePageURL, setSourcePageURL] = useState("");
  const [quality, setQuality] = useState("");
  const [destination, setDestination] = useState("local");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setError(null); setSubmitting(true);
    try { new URL(sourcePageURL); await agentRequest<DownloadJob>(token, "/v1/jobs", { method: "POST", body: JSON.stringify({ sourcePageURL, preferredQualityLabel: quality || null, destination }) }); await onQueued(); onClose(); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "Unable to queue this transfer."); }
    finally { setSubmitting(false); }
  };
  return <div className="modal-backdrop" role="presentation"><section className="queue-sheet" role="dialog" aria-modal="true" aria-labelledby="queue-title"><button className="modal-close" aria-label="Close queue download" onClick={onClose}><Glyph name="close" /></button><header><p className="eyebrow">Device command</p><h2 id="queue-title">Queue Transfer: Mission Entry</h2><p>Send a source to the connected local Lustre agent.</p></header><form onSubmit={submit}><label className="field-label">Source URL <em>required</em><input value={sourcePageURL} onChange={(event) => setSourcePageURL(event.target.value)} type="url" required placeholder="https://…" autoFocus /></label><div className="queue-fields"><label className="field-label">Quality profile<input value={quality} onChange={(event) => setQuality(event.target.value)} placeholder="Auto (optional exact label)" /></label><label className="field-label">Destination<select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="local">Local Downloads</option>{destinations.map((item) => <option value={`webdav:${item.id}`} key={item.id}>{item.name} · WebDAV</option>)}</select></label></div>{error && <p className="form-error" role="alert">{error}</p>}<footer><p><Glyph name="key" size={15} /> Credentials remain on-device; Lustre Cloud never receives saved destination passwords.</p><div><button className="secondary-button" type="button" onClick={onClose}>Cancel</button><button className="initiate-button" disabled={submitting}>{submitting ? "Queueing…" : "Initiate transfer"}</button></div></footer></form></section></div>;
}

function TransferCard({ job, destinations, onAction }: { job: DownloadJob; destinations: Destination[]; onAction: (action: JobAction) => Promise<void> }) {
  const [open, setOpen] = useState(false); const [workingAction, setWorkingAction] = useState<JobAction | null>(null); const actions = availableJobActions(job.status); const progress = jobProgressPercent(job.progress);
  const act = async (action: JobAction) => { setWorkingAction(action); try { await onAction(action); setOpen(false); } finally { setWorkingAction(null); } };
  return <article className={`transfer-card status-${job.status}`}><div className="transfer-heading"><span className="file-icon"><Glyph name={job.sourcePageURL.match(/\.(zip|tar|gz|rar|7z)(?:$|\?)/i) ? "archive" : "media"} /></span><div className="file-identity"><h3>{titleFor(job)}</h3><p>{job.preferredQualityLabel || "Automatic quality"}</p></div><span className="phase-label">{job.status.replace(/([A-Z])/g, " $1")}</span></div><p className="job-message">{job.message}</p><div className="transfer-status"><span>{formatBytes(job.downloadedBytes)}</span><strong>{progress === undefined ? "Working" : `${progress}%`}</strong><span>{job.totalBytes ? formatBytes(job.totalBytes) : "Total unavailable"}</span></div><div className="progress-track" role="progressbar" aria-label={`${titleFor(job)} progress`} aria-valuetext={progress === undefined ? "Indeterminate" : `${progress}%`} {...(progress === undefined ? {} : { "aria-valuenow": progress, "aria-valuemin": 0, "aria-valuemax": 100 })}><span className={`progress-fill ${progress === undefined ? "indeterminate" : ""}`} style={progress === undefined ? undefined : { width: `${progress}%` }} /></div><div className="transfer-footer"><dl><div><dt>Destination</dt><dd>{destinationName(job, destinations)}</dd></div><div><dt>Updated</dt><dd>{new Date(agentDateMilliseconds(job.updatedAt)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</dd></div></dl>{actions.length > 0 && <div className="control-menu"><button className="control-button" onClick={() => setOpen((value) => !value)} aria-expanded={open}><Glyph name="control" size={15} /> Control</button>{open && <div className="control-popover">{actions.map((action) => <button disabled={workingAction === action} className={action === "cancel" ? "danger-action" : ""} key={action} onClick={() => void act(action)}>{workingAction === action ? `${jobActionLabel(action)}…` : jobActionLabel(action)}</button>)}</div>}</div>}</div></article>;
}

export default function Home() {
  const [activeNav, setActiveNav] = useState("Devices"); const [token, setToken] = useState(""); const [tokenInput, setTokenInput] = useState(""); const [jobs, setJobs] = useState<DownloadJob[]>([]); const [destinations, setDestinations] = useState<Destination[]>([]); const [connected, setConnected] = useState(false); const [loading, setLoading] = useState(false); const [showQueue, setShowQueue] = useState(false); const [error, setError] = useState<string | null>(null); const [toast, setToast] = useState<string | null>(null); const [pollingInterval, setPollingInterval] = useState<PollingInterval>(2000);
  const [selectedDownloadId, setSelectedDownloadId] = useState<string | null>(null); const [pornHubAuth, setPornHubAuth] = useState<PornHubAuthStatus | null>(null);
  const refreshSequence = useRef(0);
  const refreshInFlight = useRef<{ token: string; promise: Promise<void> } | null>(null);
  const notify = (message: string) => { setToast(message); window.setTimeout(() => setToast(null), 3200); };
  const refresh = useCallback(async (activeToken = token, force = false) => {
    if (!activeToken) return;
    if (refreshInFlight.current?.token === activeToken && !force) return refreshInFlight.current.promise;
    while (refreshInFlight.current?.token === activeToken) {
      await refreshInFlight.current.promise.catch(() => undefined);
    }
    const sequence = refreshSequence.current;
    const promise = Promise.all([agentRequest<DownloadJob[]>(activeToken, "/v1/jobs"), agentRequest<Destination[]>(activeToken, "/v1/destinations"), agentRequest<PornHubAuthStatus>(activeToken, "/v1/auth/pornhub")]).then(([nextJobs, nextDestinations, nextPornHubAuth]) => {
      if (sequence !== refreshSequence.current) return;
      setJobs(nextJobs); setDestinations(nextDestinations); setPornHubAuth(nextPornHubAuth); setConnected(true); setError(null);
    });
    refreshInFlight.current = { token: activeToken, promise };
    try {
      await promise;
    } catch (reason) {
      if (sequence !== refreshSequence.current) return;
      throw reason;
    } finally {
      if (refreshInFlight.current?.promise === promise) refreshInFlight.current = null;
    }
  }, [token]);
  useEffect(() => { if (!token) return; const poll = () => void refresh(token).catch((reason) => { setConnected(false); setError(reason instanceof Error ? reason.message : "The local agent connection failed."); }); const firstPoll = window.setTimeout(poll, 0); const timer = window.setInterval(poll, pollingInterval); return () => { window.clearTimeout(firstPoll); window.clearInterval(timer); }; }, [token, refresh, pollingInterval]);
  const connect = async (event: FormEvent<HTMLFormElement>) => { event.preventDefault(); const nextToken = tokenInput.trim(); if (!tokenPattern.test(nextToken)) { setError("Paste only the token printed by `lustre token`."); return; } setLoading(true); const sequence = ++refreshSequence.current; try { await refresh(nextToken, true); if (sequence !== refreshSequence.current) return; setToken(nextToken); setTokenInput(""); notify("Connected to the local Lustre agent."); } catch (reason) { if (sequence === refreshSequence.current) setError(reason instanceof Error ? reason.message : "Unable to connect to the local agent."); } finally { if (sequence === refreshSequence.current) setLoading(false); } };
  const apply = async (job: DownloadJob, action: JobAction) => { try { await agentRequest<DownloadJob>(token, `/v1/jobs/${job.id}/action`, { method: "POST", body: JSON.stringify({ action }) }); await refresh(token, true); notify(`${jobActionLabel(action)} requested for ${titleFor(job)}.`); } catch (reason) { setError(reason instanceof Error ? reason.message : "Unable to update this transfer."); } };
  const saveDestination = async (input: Omit<DestinationProfile, "id"> & { password: string }) => { await agentRequest<DestinationProfile>(token, "/v1/destinations/webdav", { method: "POST", body: JSON.stringify(input) }); await refresh(token, true); notify(`${input.name} saved to the local agent.`); };
  const testDestination = async (id: string) => { const result = await agentRequest<{ message: string }>(token, `/v1/destinations/${id}/test`, { method: "POST" }); notify(result.message); return result.message; };
  const deleteDestination = async (id: string) => { const profile = destinations.find((item) => item.id === id); await agentRequest<{ status: string }>(token, `/v1/destinations/${id}`, { method: "DELETE" }); await refresh(token, true); notify(`${profile?.name ?? "Destination"} removed.`); };
  const disconnect = () => { refreshSequence.current += 1; setToken(""); setConnected(false); setLoading(false); setError(null); };
  const manualRefresh = async () => { try { await refresh(token, true); notify("Live agent state refreshed."); } catch (reason) { setError(reason instanceof Error ? reason.message : "Unable to refresh the local agent."); } };
  const signInWithPornHub = async () => { try { const status = await agentRequest<PornHubAuthStatus>(token, "/v1/auth/pornhub/login", { method: "POST" }); setPornHubAuth(status); notify(status.state === "signedIn" ? "PornHub sign-in completed." : "PornHub is signed out."); } catch (reason) { setError(reason instanceof Error ? reason.message : "PornHub sign-in failed."); } };
  const signOutOfPornHub = async () => { try { const status = await agentRequest<PornHubAuthStatus>(token, "/v1/auth/pornhub", { method: "DELETE" }); setPornHubAuth(status); notify("PornHub session removed from this Mac."); } catch (reason) { setError(reason instanceof Error ? reason.message : "PornHub sign-out failed."); } };
  const loadFeedSites = useCallback(() => agentRequest<FeedSite[]>(token, "/v1/feed/sites"), [token]);
  const loadFeedPage = useCallback((site: FeedSite["id"], page: number) => agentRequest<FeedPage>(token, `/v1/feed/items?site=${encodeURIComponent(site)}&page=${page}`), [token]);
  const queueFeedItem = useCallback(async (item: FeedItem, destination: string) => {
    await agentRequest<DownloadJob>(token, "/v1/jobs", { method: "POST", body: JSON.stringify({ sourcePageURL: item.sourcePageURL, preferredQualityLabel: null, destination }) });
  }, [token]);
  const refreshAfterFeedQueue = useCallback(async () => { await refresh(token, true); }, [refresh, token]);
  const activeJobs = useMemo(() => jobs.filter((job) => !["completed", "failed", "cancelled"].includes(job.status)), [jobs]);
  const latestLogs = useMemo(() => jobs.flatMap((job) => (job.logs ?? []).map((log) => ({ ...log, job }))).sort((a, b) => agentDateMilliseconds(b.timestamp) - agentDateMilliseconds(a.timestamp)).slice(0, 5), [jobs]);
  return <main className="app-shell"><aside className="sidebar"><a className="brand" href="#workspace" aria-label="Lustre Cloud home"><span className="brand-mark"><Glyph name="cloud" /></span><span><strong>LUSTRE<br />CLOUD</strong><small>Local agent bridge</small></span></a><nav aria-label="Primary navigation">{navigation.map(([label, icon]) => <button key={label} className={`nav-item ${activeNav === label ? "active" : ""}`} onClick={() => setActiveNav(label)}><Glyph name={icon} /><span>{label}</span></button>)}</nav><div className="sidebar-bottom"><button className="nav-item"><Glyph name="support" /><span>Support</span></button><button className="nav-item"><Glyph name="account" /><span>Account</span></button></div></aside><section className="workspace" id="workspace"><header className="topbar"><div className="device-heading"><span className="device-icon"><Glyph name="computer" /></span><div><h1>Local Lustre Agent <span className={`online ${connected ? "" : "offline"}`}><i />{connected ? "ONLINE" : "NOT CONNECTED"}</span></h1><p>{connected ? `${activeJobs.length} active transfer${activeJobs.length === 1 ? "" : "s"} · ${jobs.length} durable job${jobs.length === 1 ? "" : "s"}` : "Connect with the token from `lustre token`"}</p></div></div><div className="top-actions"><button className="connect-button" onClick={disconnect}>{connected ? "Disconnect" : "Connect agent"}</button><button className="icon-button" aria-label="Notifications"><Glyph name="bell" /></button><button className="avatar" aria-label="Account menu">KN</button></div></header>{!connected ? <section className="connection-screen"><div className="connection-card glass-panel"><span className="connection-mark"><Glyph name="key" size={24} /></span><p className="eyebrow">Local bridge</p><h2>Connect your Lustre agent</h2><p>Enter the one-time local token printed by <code>lustre token</code>. It stays only in this browser tab and is sent through the local Next.js bridge.</p><form onSubmit={connect}><label>Agent token<input value={tokenInput} onChange={(event) => setTokenInput(event.target.value)} type="password" autoComplete="off" placeholder="Paste the token from lustre token" /></label>{error && <p className="form-error" role="alert">{error}</p>}<button className="initiate-button" disabled={loading}>{loading ? "Connecting…" : "Connect local agent"}</button></form><small>Requires <code>lustre-agent</code> running at 127.0.0.1:63406.</small></div></section> : activeNav === "Feed" ? <FeedView destinations={destinations} jobs={jobs} loadSites={loadFeedSites} loadPage={loadFeedPage} queueItem={queueFeedItem} onQueued={refreshAfterFeedQueue} /> : activeNav === "Downloads" ? <DownloadsView jobs={jobs} destinations={destinations} error={error} selectedJobId={selectedDownloadId} onSelectJob={setSelectedDownloadId} onQueue={() => setShowQueue(true)} onAction={apply} /> : activeNav === "Destinations" ? <DestinationsView destinations={destinations} jobs={jobs} error={error} onSave={saveDestination} onTest={testDestination} onDelete={deleteDestination} /> : activeNav === "Activity" ? <ActivityView jobs={jobs} destinations={destinations} error={error} onOpenDownloads={(jobId) => { if (jobId) setSelectedDownloadId(jobId); setActiveNav("Downloads"); }} /> : activeNav === "Settings" ? <SettingsView connected={connected} pollingInterval={pollingInterval} jobsCount={jobs.length} destinationsCount={destinations.length} error={error} onPollingIntervalChange={setPollingInterval} onRefresh={manualRefresh} onDisconnect={disconnect} pornHubAuth={pornHubAuth} onPornHubSignIn={signInWithPornHub} onPornHubSignOut={signOutOfPornHub} /> : <div className="content-grid"><section className="operations glass-panel"><div className="panel-heading"><div><p className="eyebrow">Live workspace</p><h2>Active Operations <span>{activeJobs.length}</span></h2></div><button className="queue-button" onClick={() => setShowQueue(true)}><Glyph name="plus" size={16} /> Queue download</button></div>{error && <p className="inline-error" role="alert">{error}</p>}<div className="transfer-list">{activeJobs.map((job) => <TransferCard key={job.id} job={job} destinations={destinations} onAction={(action) => apply(job, action)} />)}</div>{activeJobs.length === 0 && <div className="empty-state"><Glyph name="downloads" size={24} /><h3>Queue is clear</h3><p>Your local agent is online and ready for its next transfer.</p><button className="queue-button" onClick={() => setShowQueue(true)}>Queue download</button></div>}</section><aside className="health-panel glass-panel"><div className="panel-heading"><div><p className="eyebrow">Agent telemetry</p><h2>Agent Health</h2></div><span className="health-dot" /></div><section className="agent-summary"><div><span>Connection</span><strong>Protected loopback</strong></div><div><span>Remote profiles</span><strong>{destinations.length}</strong></div><div><span>Last sync</span><strong>Live · {pollingInterval / 1000}s polling</strong></div></section><dl className="health-list"><div><dt>Queued</dt><dd>{jobs.filter((job) => job.status === "queued").length}</dd></div><div><dt>Running</dt><dd className="connection">{jobs.filter((job) => job.status === "running").length}</dd></div><div><dt>Paused</dt><dd>{jobs.filter((job) => job.status === "paused").length}</dd></div><div><dt>Completed</dt><dd>{jobs.filter((job) => job.status === "completed").length}</dd></div></dl><section className="event-log"><div className="log-heading"><span>Agent event log</span><i>LIVE</i></div>{latestLogs.length ? <ol>{latestLogs.map((entry, index) => <li key={`${entry.timestamp}-${index}`}><time>{new Date(agentDateMilliseconds(entry.timestamp)).toLocaleTimeString()}</time><b className={entry.level === "error" ? "warn" : ""}>{entry.level}</b> {entry.message}</li>)}</ol> : <p className="no-events">No worker events yet.</p>}</section></aside></div>}</section>{showQueue && <QueueSheet destinations={destinations} token={token} onClose={() => setShowQueue(false)} onQueued={async () => { await refresh(token, true); notify("Transfer queued with the local agent."); }} />}{toast && <div className="toast" role="status">{toast}</div>}</main>;
}
