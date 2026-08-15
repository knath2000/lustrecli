"use client";

import {
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { UserButton } from "@clerk/nextjs";
import { agentDateMilliseconds } from "@/lib/agent-date";
import {
  downloadProgressDisplay,
  formatBytes,
  formatETA,
  formatSpeed,
} from "@/lib/download-progress";
import type { DownloadJob } from "@/lib/download-job";
import { AuthStatusSequence } from "@/lib/auth-status-sequence";
import {
  availableJobActions,
  jobActionLabel,
  type JobAction,
} from "@/lib/job-actions";
import type { FeedItem, FeedPage, FeedQuery, FeedSite } from "@/lib/feed-model";
import {
  cloudDashboardRefreshPaths,
  cloudDashboardPollingDelay,
  cloudDeviceIsOnline,
  cloudDeviceOfflineMessage,
  cloudDestinationViewNeedsRefresh,
  cloudFeedRequestKey,
  cloudGoogleDriveFolderListPath,
  coalesceCloudFeedRequest,
  normalizeCloudFeedQuery,
} from "@/lib/cloud-feed-ui";
import type { CloudDevicePresence } from "@/lib/cloud-feed-ui";
import { pornHubAuthMutationMessage } from "@/lib/pornhub-auth-model";
import type { PollingInterval } from "@/lib/settings-model";
import { ActivityView } from "./activity-view";
import { DestinationsView, type DestinationProfile, type GoogleDriveFolder } from "./destinations-view";
import { DownloadsView } from "./downloads-view";
import { type FeedRefresh } from "./feed-view";
import { SettingsView } from "./settings-view";
import { DevicesView } from "./devices/devices-view";
import { HomeWorkspaceView } from "./home-workspace-view";
import { LibraryView } from "./library-view";
import { WatchApp } from "@/components/lustre-watch/watch-app";
import type { FeedItem as WatchFeedItem, FeedPlaybackResolution as WatchPlaybackResolution, WatchlistItem as WatchlistEntry } from "@/lib/lustre-watch/contracts";

type Destination = DestinationProfile;
type PornHubAuthStatus = {
  state: "signedOut" | "signingIn" | "signedIn" | "expired";
  lastValidatedAt?: string;
  message?: string;
  code?: string;
};
type DashboardCounts = {
  active: number;
  queued: number;
  failed: number;
  completed: number;
};
type CloudJobPayload = {
  id: string;
  sourcePageURL?: string | null;
  displayName: string;
  preferredQualityLabel?: string | null;
  status: string;
  progress?: number | null;
  downloadedBytes?: number | null;
  totalBytes?: number | null;
  phase?: string | null;
  updatedAt: string;
};

const navigation = [
  ["Dashboard", "devices"],
  ["Downloads", "downloads"],
  ["Destinations", "destinations"],
  ["Activity", "activity"],
  ["Settings", "settings"],
  ["Devices", "computer"],
] as const;
const feedNavigation = ["Feed", "feed"] as const;
const tokenPattern = /^[A-Za-z0-9+/=]+$/;

function cloudJobs(payload: { jobs?: CloudJobPayload[] }): DownloadJob[] {
  return (payload.jobs ?? []).map((job) => ({
    id: job.id,
    sourcePageURL: job.sourcePageURL ?? `lustre://job/${job.id}`,
    displayName: job.displayName,
    preferredQualityLabel: job.preferredQualityLabel ?? undefined,
    destination: "local",
    status: job.status as DownloadJob["status"],
    message: `${job.displayName} · synced from paired Mac`,
    progress: job.progress ?? undefined,
    downloadedBytes: job.downloadedBytes ?? undefined,
    totalBytes: job.totalBytes ?? undefined,
    transferPhase: job.phase as DownloadJob["transferPhase"] | undefined,
    logs: [{
      timestamp: job.updatedAt,
      level: ["failed", "verificationRequired"].includes(job.status) ? "error" as const : "info" as const,
      message: `${job.status} reported by paired Mac.`,
    }],
    updatedAt: job.updatedAt,
  }));
}

function Glyph({ name, size = 18 }: { name: string; size?: number }) {
  const props = {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.7,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
  const shapes: Record<string, React.ReactNode> = {
    menu: (
      <>
        <path d="M5 7h14M5 12h14M5 17h14" />
      </>
    ),
    home: (
      <>
        <path d="m4 10 8-6 8 6" />
        <path d="M6.5 9v10h11V9M10 19v-5h4v5" />
      </>
    ),
    broadcast: (
      <>
        <path d="M8.2 8.2a5.4 5.4 0 0 0 0 7.6M5.4 5.4a9.4 9.4 0 0 0 0 13.2M15.8 8.2a5.4 5.4 0 0 1 0 7.6M18.6 5.4a9.4 9.4 0 0 1 0 13.2" />
        <circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" />
      </>
    ),
    books: (
      <>
        <rect x="4" y="6" width="4" height="13" rx="1" />
        <rect x="10" y="3" width="4" height="16" rx="1" />
        <path d="m16.5 6 3.5-1 3.2 12.8-3.5.9Z" />
      </>
    ),
    cloud: (
      <>
        <path d="M7 18.5h10a4 4 0 0 0 .7-7.94A5.5 5.5 0 0 0 7.1 9.14 4.7 4.7 0 0 0 7 18.5Z" />
        <path d="M8.5 14.5h7" />
      </>
    ),
    devices: (
      <>
        <rect x="3" y="5" width="13" height="11" rx="1.5" />
        <path d="M7 20h5M9.5 16v4M19 8v8M17 10h4M17 14h4" />
      </>
    ),
    downloads: (
      <>
        <path d="M12 3v11" />
        <path d="m8 10 4 4 4-4" />
        <path d="M5 19h14" />
      </>
    ),
    feed: (
      <>
        <rect x="3" y="4" width="18" height="16" rx="2" />
        <path d="m8 9 2.5 2.5L8 14M13 9h4M13 14h4" />
      </>
    ),
    folder: (
      <>
        <path d="M3.5 7.5h6l2 2h9v8.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z" />
        <path d="M3.5 7.5V6a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v1.5" />
      </>
    ),
    activity: (
      <>
        <rect x="4" y="3" width="16" height="18" rx="2" />
        <path d="M8 16v-4M12 16V8M16 16v-6" />
      </>
    ),
    settings: (
      <>
        <circle cx="12" cy="12" r="3" />
        <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.05 2.05-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56v.09h-2.9v-.09A1.7 1.7 0 0 0 10.85 18.6a1.7 1.7 0 0 0-1.88.34l-.06.06-2.05-2.05.06-.06A1.7 1.7 0 0 0 7.26 15a1.7 1.7 0 0 0-1.56-1.03h-.09v-2.9h.09A1.7 1.7 0 0 0 7.26 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.05-2.05.06.06A1.7 1.7 0 0 0 10.85 6.4a1.7 1.7 0 0 0 1.03-1.56v-.09h2.9v.09A1.7 1.7 0 0 0 15.82 6.4a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.05 2.05-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.09v2.9h-.09A1.7 1.7 0 0 0 19.4 15Z" />
      </>
    ),
    support: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M9.5 9a2.6 2.6 0 1 1 4.55 1.72c-.9.94-2.05 1.3-2.05 2.78" />
        <path d="M12 17h.01" />
      </>
    ),
    account: (
      <>
        <circle cx="12" cy="8" r="3.2" />
        <path d="M5 20c.8-3.3 3.1-5 7-5s6.2 1.7 7 5" />
      </>
    ),
    computer: (
      <>
        <rect x="3.5" y="4.5" width="17" height="12" rx="1.5" />
        <path d="M8 20h8M12 16.5V20" />
      </>
    ),
    plus: (
      <>
        <path d="M12 5v14M5 12h14" />
      </>
    ),
    media: (
      <>
        <rect x="3" y="5" width="18" height="15" rx="2" />
        <path d="M8 5V3M16 5V3M3 10h18" />
        <path d="m10 13 5 2.5-5 2.5Z" />
      </>
    ),
    archive: (
      <>
        <path d="M5 3.5h10l4 4V20a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 4 20V5a1.5 1.5 0 0 1 1-1.5Z" />
        <path d="M15 3.5V8h4M8 13h8M8 17h5" />
      </>
    ),
    control: (
      <>
        <path d="M5 7h14M5 17h14" />
        <circle cx="8" cy="7" r="2" />
        <circle cx="16" cy="17" r="2" />
      </>
    ),
    bell: (
      <>
        <path d="M18 10a6 6 0 1 0-12 0c0 7-3 7-3 8.5h18C21 17 18 17 18 10Z" />
        <path d="M10 21h4" />
      </>
    ),
    close: (
      <>
        <path d="m6 6 12 12M18 6 6 18" />
      </>
    ),
    key: (
      <>
        <circle cx="8" cy="15" r="3" />
        <path d="m10 13 8-8M14 7l3 3M16 5l3 3" />
      </>
    ),
  };
  return <svg {...props}>{shapes[name] ?? shapes.activity}</svg>;
}

function titleFor(job: DownloadJob) {
  if (job.displayName?.trim()) return job.displayName;
  try {
    return decodeURIComponent(
      new URL(job.sourcePageURL).pathname.split("/").filter(Boolean).at(-1) ||
        new URL(job.sourcePageURL).hostname,
    );
  } catch {
    return job.sourcePageURL;
  }
}
function destinationName(job: DownloadJob, destinations: Destination[]) {
  if (job.destination === "local") return "Local Downloads";
  const id = job.destination.replace(/^(webdav|gdrive):/i, "");
  return (
    destinations.find(
      (destination) => destination.id.toLowerCase() === id.toLowerCase(),
    )?.name ?? (/^gdrive:/i.test(job.destination) ? "Google Drive" : "Remote WebDAV")
  );
}
async function waitForCloudCommand(base: string, id: string) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (attempt)
      await new Promise((resolve) => window.setTimeout(resolve, 2_000));
    let response: Response;
    try {
      response = await fetch(`${base}/commands/${id}`, { cache: "no-store" });
    } catch {
      throw new Error("The paired Mac is offline or cannot be reached.");
    }
    const payload = await response.json().catch(() => ({}));
    if (!response.ok)
      throw new Error(
        payload.error?.message ??
          "The paired Mac command status is unavailable.",
      );
    if (payload.command.status === "completed")
      return payload.command.result ?? {};
    if (payload.command.status === "failed")
      throw new Error(feedCommandFailureMessage(payload.command.result?.code));
  }
  throw new Error(
    "The paired Mac did not respond within five minutes. Complete verification in Chrome on the paired Mac, then try again.",
  );
}

function feedCommandFailureMessage(code: unknown) {
  switch (code) {
    case "provider_verification_required": return "Complete verification in Chrome on the paired Mac, then retry. Cached cards remain available where possible.";
    case "browser_extension_required": return "Install and enable the Lustre Chrome extension on the paired Mac with `lustre browser install --chrome`, then retry.";
    case "provider_http_error": return "The source returned an HTTP error. Cached cards remain available where possible.";
    case "provider_unreachable": return "The paired Mac could not reach this source. Check its network route, then refresh.";
    case "provider_changed": return "The source page changed and could not be parsed. Cached cards remain available where possible.";
    case "authentication_required": return "Sign in to this source on the paired Mac, then refresh.";
    case "result_too_large": return "This source returned too many items for one safe Cloud page.";
    case "invalid_request": return "The Feed request was rejected as invalid.";
    case "signing_in": return "A PornHub sign-in window is already open on the paired Mac.";
    case "auth_helper_unavailable": return "The PornHub sign-in helper is unavailable on the paired Mac.";
    case "auth_helper_failed": return "The PornHub sign-in helper did not complete.";
    case "auth_timeout": return "The PornHub sign-in window timed out.";
    case "invalid_session": return "PornHub rejected the saved session.";
    case "auth_storage_unavailable": return "PornHub session storage is unavailable on the paired Mac.";
    case "agent_offline": return "Paired Mac is offline. Mount MyPassport and start Lustre Agent, then retry.";
    case "command_expired": return "The PornHub sign-in request expired before the paired Mac received it. Confirm the agent is online, then retry.";
    default: return "The paired Mac could not complete this request.";
  }
}

function cloudPornHubAuthStatus(value: PornHubAuthStatus): PornHubAuthStatus {
  return { ...value, message: value.code ? feedCommandFailureMessage(value.code) : undefined };
}

async function fetchCloudPresence(deviceID: string): Promise<CloudDevicePresence> {
  const response = await fetch(`/api/cloud/v1/devices/${deviceID}/presence`, { cache: "no-store" });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error?.message ?? "Unable to load paired Mac presence.");
  return payload as CloudDevicePresence;
}

async function beginFeedCommand<T>(
  deviceID: string,
  body: Record<string, unknown>,
  select: (result: Record<string, unknown>) => T,
): Promise<FeedRefresh<T>> {
  const base = `/api/cloud/v1/devices/${deviceID}`;
  const response = await fetch(`${base}/commands`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error?.message ?? "The paired Mac request failed.");
  const cachedResult = payload.cache?.result && typeof payload.cache.result === "object"
    ? select(payload.cache.result)
    : null;
  return {
    cache: cachedResult ? {
      result: cachedResult,
      acknowledgedAt: payload.cache.acknowledgedAt,
      freshness: payload.cache.freshness,
    } : null,
    live: waitForCloudCommand(base, payload.command.id).then((result) => select(result)),
  };
}
async function agentRequest<T>(
  deviceID: string,
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const base = `/api/cloud/v1/devices/${deviceID}`;
  let target = "";
  let body: unknown = undefined;
  if (path === "/v1/jobs" && (options.method ?? "GET") === "GET")
    target = `${base}/jobs`;
  else if (path === "/v1/jobs" && options.method === "POST") {
    target = `${base}/commands`;
    const input = JSON.parse(String(options.body ?? "{}"));
    body = {
      kind: "queue_url",
      url: input.sourcePageURL,
      title: input.title ?? undefined,
      preferredQualityLabel: input.preferredQualityLabel ?? undefined,
      destination: input.destination ?? "local",
      requestID: input.requestID ?? undefined,
    };
  } else {
    const match = path.match(/^\/v1\/jobs\/([^/]+)\/action$/);
    if (match && options.method === "POST") {
      target = `${base}/commands`;
      const input = JSON.parse(String(options.body ?? "{}"));
      body = { kind: "job_action", jobID: match[1], action: input.action };
    }
  }
  if (path === "/v1/feed/sites") {
    target = `${base}/commands`;
    body = { kind: "feed_sites" };
  }
  if (path === "/v1/feed/queue" && options.method === "POST") {
    const input = JSON.parse(String(options.body ?? "{}"));
    target = `${base}/commands`;
    body = { kind: "feed_queue", ...input };
  }
  if (path === "/v1/feed/resolve" && options.method === "POST") {
    const input = JSON.parse(String(options.body ?? "{}"));
    target = `${base}/commands`;
    body = { kind: "feed_resolve", ...input };
  }
  if (path === "/v1/watchlist/resolve" && options.method === "POST") {
    const input = JSON.parse(String(options.body ?? "{}"));
    target = `${base}/commands`;
    body = { kind: "watchlist_resolve", watchlistID: input.watchlistID };
  }
  if (path === "/v1/destinations") {
    target = `${base}/commands`;
    body = { kind: "destinations_list" };
  } else if (path === "/v1/destinations/local-folder" && (options.method ?? "GET") === "GET") {
    target = `${base}/commands`;
    body = { kind: "local_folder_status" };
  } else if (path === "/v1/destinations/local-folder" && options.method === "POST") {
    target = `${base}/commands`;
    body = { kind: "local_folder_choose" };
  } else if (path === "/v1/destinations/local-folder" && options.method === "DELETE") {
    target = `${base}/commands`;
    body = { kind: "local_folder_reset" };
  } else {
    const feed = path.match(/^\/v1\/feed\/items\?(.+)$/);
    if (feed) {
      const query = new URLSearchParams(feed[1]);
      target = `${base}/commands`;
      body = {
        kind: "feed_page",
        siteID: query.get("site"),
        page: Number(query.get("page") ?? "1"),
        query: query.get("q") ?? undefined,
      };
    }
  }
  if (path === "/v1/destinations/webdav" && options.method === "POST") {
    const input = JSON.parse(String(options.body ?? "{}"));
    target = `${base}/commands`;
    body = {
      kind: "webdav_add",
      name: input.name,
      baseURL: input.baseURL,
      username: input.username,
      remotePath: input.remotePath,
      allowInvalidCertificate: input.allowInvalidCertificate,
    };
  }
  if (path === "/v1/destinations/google-drive/connect" && options.method === "POST") {
    target = `${base}/commands`;
    body = { kind: "gdrive_connect" };
  } else {
    const folders = path.match(/^\/v1\/destinations\/([^/]+)\/google-drive\/folders\?path=(.*)$/);
    const createFolder = path.match(/^\/v1\/destinations\/([^/]+)\/google-drive\/folders$/);
    const selectFolder = path.match(/^\/v1\/destinations\/([^/]+)\/google-drive\/folder$/);
    if (folders) {
      target = `${base}/commands`;
      body = { kind: "gdrive_folders", profileID: folders[1], path: decodeURIComponent(folders[2]) };
    } else if (createFolder && options.method === "POST") {
      const input = JSON.parse(String(options.body ?? "{}"));
      target = `${base}/commands`;
      body = { kind: "gdrive_create_folder", profileID: createFolder[1], path: input.path };
    } else if (selectFolder && options.method === "POST") {
      const input = JSON.parse(String(options.body ?? "{}"));
      target = `${base}/commands`;
      body = { kind: "gdrive_select_folder", profileID: selectFolder[1], path: input.path };
    }
  }
  {
    const test = path.match(/^\/v1\/destinations\/([^/]+)\/google-drive\/test$/);
    if (test && options.method === "POST") {
      target = `${base}/commands`;
      body = { kind: "gdrive_test", profileID: test[1] };
    }
  }
  if (path === "/v1/auth/pornhub" && (options.method ?? "GET") === "GET") {
    target = `${base}/commands`;
    body = { kind: "pornhub_auth_status" };
  } else if (path === "/v1/auth/pornhub/login" && options.method === "POST") {
    target = `${base}/commands`;
    body = { kind: "pornhub_auth_login" };
  } else if (path === "/v1/auth/pornhub/login" && options.method === "DELETE") {
    target = `${base}/commands`;
    body = { kind: "pornhub_auth_cancel" };
  } else if (path === "/v1/auth/pornhub" && options.method === "DELETE") {
    target = `${base}/commands`;
    body = { kind: "pornhub_auth_logout" };
  }
  if (!target)
    throw new Error(
      "This dashboard capability is still being moved to the paired-agent transport.",
    );
  const response = await fetch(target, {
    method: body
      ? "POST"
      : (options.method ?? "GET") === "GET"
        ? "GET"
        : "POST",
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    cache: "no-store",
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok)
    throw new Error(payload.error?.message ?? "The paired Mac request failed.");
  if (path === "/v1/jobs" && (options.method ?? "GET") === "GET")
    return cloudJobs(payload) as T;
  if (target === `${base}/commands`) {
    const result = await waitForCloudCommand(base, payload.command.id);
    if (path === "/v1/feed/queue") {
      if (result.jobID !== payload.command.id) throw new Error("The paired Mac returned an invalid Feed queue acknowledgement.");
      for (let attempt = 0; attempt < 24; attempt += 1) {
        const jobsResponse = await fetch(`${base}/jobs`, { cache: "no-store" });
        const jobsPayload = await jobsResponse.json().catch(() => ({}));
        if (!jobsResponse.ok) throw new Error(jobsPayload.error?.message ?? "The queued transfer status is unavailable.");
        const job = jobsPayload.jobs?.find((candidate: { id: string }) => candidate.id === payload.command.id);
        if (job) return job as T;
        await new Promise((resolve) => window.setTimeout(resolve, 2_000));
      }
      throw new Error("The queued transfer was acknowledged but has not appeared in projected job status.");
    }
    if (cloudGoogleDriveFolderListPath(path))
      return (result.googleDriveFolders ?? []) as T;
    if (path === "/v1/destinations/local-folder")
      return result.localDownloadFolder as T;
    if (path === "/v1/feed/resolve" || path === "/v1/watchlist/resolve") {
      const playback = result.playback as {
        sourcePageURL: string;
        title?: string;
        provider: string;
        qualities: Array<{ label: string; url: string; mediaKind: string; headers: Record<string, string> }>;
      } | undefined;
      if (!playback?.qualities?.length) throw new Error("The paired Mac returned no playable sources.");
      return {
        sourcePageURL: playback.sourcePageURL,
        title: playback.title ?? "Lustre extraction",
        providerAttempts: [{ provider: playback.provider, status: "resolved" }],
        qualities: playback.qualities.map((quality) => ({
          label: quality.label,
          url: quality.url,
          mediaKind: quality.mediaKind === "hls" ? "hls" : "video",
          headers: quality.headers,
          provider: playback.provider,
          resolutionMethod: "native",
        })),
      } as T;
    }
    if (path.startsWith("/v1/feed/") || path === "/v1/destinations" || path === "/v1/destinations/google-drive/connect" || path.includes("/google-drive/folder"))
      return (result.sites ?? result.page ?? result.destinations ?? []) as T;
    if (path.includes("/google-drive/test"))
      return { message: "Google Drive connection succeeded." } as T;
    if (path.startsWith("/v1/auth/pornhub"))
      return cloudPornHubAuthStatus(result.pornHubAuth as PornHubAuthStatus) as T;
    return result as T;
  }
  return (payload.jobs ?? payload) as T;
}

function QueueSheet({
  destinations,
  token,
  onClose,
  onQueued,
}: {
  destinations: Destination[];
  token: string;
  onClose: () => void;
  onQueued: () => Promise<void>;
}) {
  const [sourcePageURL, setSourcePageURL] = useState("");
  const [quality, setQuality] = useState("");
  const [destination, setDestination] = useState("local");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      new URL(sourcePageURL);
      await agentRequest<DownloadJob>(token, "/v1/jobs", {
        method: "POST",
        body: JSON.stringify({
          sourcePageURL,
          preferredQualityLabel: quality || null,
          destination,
        }),
      });
      await onQueued();
      onClose();
    } catch (reason) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Unable to queue this transfer.",
      );
    } finally {
      setSubmitting(false);
    }
  };
  return (
    <div className="modal-backdrop" role="presentation">
      <section
        className="queue-sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="queue-title"
      >
        <button
          className="modal-close"
          aria-label="Close queue download"
          onClick={onClose}
        >
          <Glyph name="close" />
        </button>
        <header>
          <p className="eyebrow">Device command</p>
          <h2 id="queue-title">Queue Transfer: Mission Entry</h2>
          <p>Send a PMVHaven, AllPornStream, HQPorner, PornHub, or direct media source to the connected local Lustre agent.</p>
        </header>
        <form onSubmit={submit}>
          <label className="field-label">
            Source URL <em>required</em>
            <input
              value={sourcePageURL}
              onChange={(event) => setSourcePageURL(event.target.value)}
              type="url"
              required
              placeholder="https://pmvhaven.com/video/…"
              autoFocus
            />
          </label>
          <div className="queue-fields">
            <label className="field-label">
              Quality profile
              <input
                value={quality}
                onChange={(event) => setQuality(event.target.value)}
                placeholder="Auto (optional exact label)"
              />
            </label>
            <label className="field-label">
              Destination
              <select
                value={destination}
                onChange={(event) => setDestination(event.target.value)}
              >
                <option value="local">Local Downloads</option>
                {destinations.map((item) => (
                  <option value={`${item.kind === "google_drive" ? "gdrive" : "webdav"}:${item.id}`} key={item.id}>
                    {item.name} · {item.kind === "google_drive" ? "Google Drive" : "WebDAV"}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {error && (
            <p className="form-error" role="alert">
              {error}
            </p>
          )}
          <footer>
            <p>
              <Glyph name="key" size={15} /> Credentials remain on-device;
              Lustre Cloud never receives saved destination passwords.
            </p>
            <div>
              <button
                className="secondary-button"
                type="button"
                onClick={onClose}
              >
                Cancel
              </button>
              <button className="initiate-button" disabled={submitting}>
                {submitting ? "Queueing…" : "Initiate transfer"}
              </button>
            </div>
          </footer>
        </form>
      </section>
    </div>
  );
}

function TransferCard({
  job,
  destinations,
  onAction,
}: {
  job: DownloadJob;
  destinations: Destination[];
  onAction: (action: JobAction) => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [workingAction, setWorkingAction] = useState<JobAction | null>(null);
  const actions = availableJobActions(job.status);
  const progress = downloadProgressDisplay(job);
  const act = async (action: JobAction) => {
    setWorkingAction(action);
    try {
      await onAction(action);
      setOpen(false);
    } finally {
      setWorkingAction(null);
    }
  };
  const totalLabel =
    progress.totalBytes === undefined
      ? "Total unavailable"
      : `${progress.totalIsEstimated ? "Estimated " : ""}${formatBytes(progress.totalBytes)}`;
  const speed = formatSpeed(progress.speed);
  const eta = formatETA(progress.etaSeconds);
  const active = progress.state === "indeterminate";
  return (
    <article className={`transfer-card status-${job.status}`}>
      <div className="transfer-heading">
        <span className="file-icon">
          <Glyph
            name={
              job.sourcePageURL.match(/\.(zip|tar|gz|rar|7z)(?:$|\?)/i)
                ? "archive"
                : "media"
            }
          />
        </span>
        <div className="file-identity">
          <h3>{titleFor(job)}</h3>
          <p>{job.preferredQualityLabel || "Automatic quality"}</p>
        </div>
        <span className="phase-label">{progress.phaseLabel}</span>
      </div>
      <p className="job-message">{job.message}</p>
      <div className="transfer-status">
        <span>{formatBytes(progress.bytesWritten)}</span>
        <strong>{progress.progressLabel}</strong>
        <span>{totalLabel}</span>
      </div>
      <div
        className="progress-track"
        {...(progress.state === "static"
          ? {}
          : {
              role: "progressbar",
              "aria-label": `${titleFor(job)} progress`,
              "aria-valuetext": progress.accessibleText,
              ...(progress.percent === undefined
                ? {}
                : {
                    "aria-valuenow": progress.percent,
                    "aria-valuemin": 0,
                    "aria-valuemax": 100,
                  }),
            })}
      >
        <span
          className={`progress-fill ${active ? "indeterminate" : ""} ${progress.state === "static" ? "static" : ""}`}
          style={
            progress.percent === undefined
              ? undefined
              : { width: `${progress.percent}%` }
          }
        />
      </div>
      {(speed || eta) && (
        <div className="transfer-telemetry">
          {speed && <span>{speed}</span>}
          {eta && <span>{eta}</span>}
        </div>
      )}
      <div className="transfer-footer">
        <dl>
          <div>
            <dt>Destination</dt>
            <dd>{destinationName(job, destinations)}</dd>
          </div>
          <div>
            <dt>Updated</dt>
            <dd>
              {new Date(
                agentDateMilliseconds(job.updatedAt),
              ).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
            </dd>
          </div>
        </dl>
        {actions.length > 0 && (
          <div className="control-menu">
            <button
              className="control-button"
              onClick={() => setOpen((value) => !value)}
              aria-expanded={open}
            >
              <Glyph name="control" size={15} /> Control
            </button>
            {open && (
              <div className="control-popover">
                {actions.map((action) => (
                  <button
                    disabled={workingAction === action}
                    className={action === "cancel" ? "danger-action" : ""}
                    key={action}
                    onClick={() => void act(action)}
                  >
                    {workingAction === action
                      ? `${jobActionLabel(action)}…`
                      : jobActionLabel(action)}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </article>
  );
}

export function CloudFullDashboard({
  feedEnabled,
  feedMediaEnabled = false,
  feedDestinationsEnabled = false,
  feedQueueEnabled = false,
  suppressDestinationPolling = false,
}: {
  feedEnabled: boolean;
  feedMediaEnabled?: boolean;
  feedDestinationsEnabled?: boolean;
  feedQueueEnabled?: boolean;
  suppressDestinationPolling?: boolean;
}) {
  const [activeNav, setActiveNav] = useState("Home");
  const [token, setToken] = useState("");
  const [tokenInput, setTokenInput] = useState("");
  const [jobs, setJobs] = useState<DownloadJob[]>([]);
  const [jobCounts, setJobCounts] = useState<DashboardCounts>({
    active: 0,
    queued: 0,
    failed: 0,
    completed: 0,
  });
  const [destinations, setDestinations] = useState<Destination[]>([]);
  const [connected, setConnected] = useState(false);
  const [loading, setLoading] = useState(false);
  const [showQueue, setShowQueue] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [downloadInitialStatus, setDownloadInitialStatus] = useState<"all" | "active" | "queued" | "failed" | "completed">("all");
  const [homeDownloadsStatus, setHomeDownloadsStatus] = useState<"active" | "queued" | "failed" | "completed" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [pollingInterval, setPollingInterval] = useState<PollingInterval>(2000);
  const [selectedDownloadId, setSelectedDownloadId] = useState<string | null>(
    null,
  );
  const [pornHubAuth, setPornHubAuth] = useState<PornHubAuthStatus | null>(
    null,
  );
  const homeDownloadsModalRef = useRef<HTMLElement | null>(null);
  const authStatusSequence = useRef(new AuthStatusSequence());
  const feedRequests = useRef(new Map<string, Promise<unknown>>());
  const visibleNavigation = useMemo(
    () =>
      feedEnabled
        ? [navigation[0], feedNavigation, ...navigation.slice(1)]
        : navigation,
    [feedEnabled],
  );
  useEffect(() => {
    void (async () => {
      try {
        const response = await fetch("/api/cloud/v1/devices", {
          cache: "no-store",
        });
        const payload = await response.json();
        const devices = (payload.devices ?? []).filter(
          (device: { revokedAt: string | null }) => !device.revokedAt,
        );
        const saved = window.localStorage.getItem(
          "lustre.cloud.selected-device",
        );
        const device =
          devices.find((candidate: { id: string }) => candidate.id === saved) ??
          devices[0];
        if (!device) return;
        window.localStorage.setItem("lustre.cloud.selected-device", device.id);
        setToken(device.id);
        const presence = await fetchCloudPresence(device.id);
        setConnected(cloudDeviceIsOnline(presence));
        setError(cloudDeviceOfflineMessage(presence));
      } catch {
        setError("Unable to load a paired Mac. Open Devices to pair one.");
      }
    })();
  }, []);
  const refreshSequence = useRef(0);
  const refreshInFlight = useRef<{
    token: string;
    promise: Promise<void>;
  } | null>(null);
  const notify = (message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(null), 3200);
  };
  const refresh = useCallback(
    async (activeToken = token, force = false) => {
      if (!activeToken) return;
      if (refreshInFlight.current?.token === activeToken && !force)
        return refreshInFlight.current.promise;
      while (refreshInFlight.current?.token === activeToken) {
        await refreshInFlight.current.promise.catch(() => undefined);
      }
      const sequence = refreshSequence.current;
      const refreshPaths = cloudDashboardRefreshPaths(suppressDestinationPolling);
      const historyStatus = homeDownloadsStatus;
      const needsHistory = historyStatus !== null || ["Downloads", "Activity", "Destinations"].includes(activeNav);
      const snapshotRequest = fetch(`/api/cloud/v1/devices/${activeToken}/jobs?scope=dashboard`, { cache: "no-store" })
        .then(async (response) => {
          const payload = await response.json().catch(() => ({}));
          if (!response.ok) throw new Error(payload.error?.message ?? "Download status is unavailable.");
          return payload as { jobs: CloudJobPayload[]; counts: DashboardCounts; presence: CloudDevicePresence };
        });
      const historyRequest = needsHistory
        ? fetch(`/api/cloud/v1/devices/${activeToken}/jobs?limit=100${historyStatus ? `&status=${encodeURIComponent(historyStatus)}` : ""}`, { cache: "no-store" })
          .then(async (response) => {
            const payload = await response.json().catch(() => ({}));
            if (!response.ok) throw new Error(payload.error?.message ?? "Download history is unavailable.");
            return cloudJobs(payload);
          })
        : Promise.resolve(null);
      const promise = Promise.all([
        snapshotRequest,
        historyRequest,
        refreshPaths.includes("/v1/destinations")
          ? agentRequest<Destination[]>(activeToken, "/v1/destinations")
          : Promise.resolve([]),
      ]).then(([snapshot, historyJobs, nextDestinations]) => {
        if (sequence !== refreshSequence.current) return;
        setJobs(historyJobs ?? cloudJobs(snapshot));
        setJobCounts(snapshot.counts);
        if (refreshPaths.includes("/v1/destinations"))
          setDestinations(nextDestinations);
        setConnected(cloudDeviceIsOnline(snapshot.presence));
        setError(cloudDeviceOfflineMessage(snapshot.presence));
      });
      refreshInFlight.current = { token: activeToken, promise };
      try {
        await promise;
      } catch (reason) {
        if (sequence !== refreshSequence.current) return;
        throw reason;
      } finally {
        if (refreshInFlight.current?.promise === promise)
          refreshInFlight.current = null;
      }
    },
    [activeNav, homeDownloadsStatus, suppressDestinationPolling, token],
  );
  useEffect(() => {
    if (!token) return;
    let timer: number | undefined;
    let cancelled = false;
    const schedule = (immediate = false) => {
      if (cancelled || document.hidden) return;
      timer = window.setTimeout(poll, immediate ? 0 : cloudDashboardPollingDelay(jobCounts.active + jobCounts.queued, pollingInterval));
    };
    const poll = () => {
      if (document.hidden) return;
      void refresh(token).catch((reason) => {
        setConnected(false);
        setError(
          reason instanceof Error
            ? reason.message
            : "The local agent connection failed.",
        );
      }).finally(() => schedule());
    };
    const visibilityChanged = () => {
      if (timer !== undefined) window.clearTimeout(timer);
      if (!document.hidden) schedule(true);
    };
    document.addEventListener("visibilitychange", visibilityChanged);
    schedule(true);
    return () => {
      cancelled = true;
      if (timer !== undefined) window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [jobCounts.active, jobCounts.queued, token, refresh, pollingInterval]);
  useEffect(() => {
    if (!homeDownloadsStatus) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    requestAnimationFrame(() => homeDownloadsModalRef.current?.querySelector<HTMLElement>(".home-downloads-close")?.focus());
    const close = (event: KeyboardEvent) => {
      if (event.key === "Escape") setHomeDownloadsStatus(null);
      if (event.key !== "Tab" || !homeDownloadsModalRef.current) return;
      const focusable = [...homeDownloadsModalRef.current.querySelectorAll<HTMLElement>("button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex='-1'])")];
      if (!focusable.length) return;
      const first = focusable[0]!;
      const last = focusable.at(-1)!;
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    window.addEventListener("keydown", close);
    return () => {
      document.body.style.overflow = previous;
      window.removeEventListener("keydown", close);
    };
  }, [homeDownloadsStatus]);
  useEffect(() => {
    if (activeNav !== "Home") setHomeDownloadsStatus(null);
  }, [activeNav]);
  useEffect(() => {
    if (!token || !connected || activeNav !== "Settings" || (pornHubAuth && pornHubAuth.state !== "signingIn")) return;
    let active = true;
    const timer = window.setTimeout(async () => {
      try {
        const status = await agentRequest<PornHubAuthStatus>(token, "/v1/auth/pornhub");
        if (active) setPornHubAuth(status);
      } catch (reason) {
        if (active) setError(reason instanceof Error ? reason.message : "Unable to load PornHub sign-in status.");
      }
    }, pornHubAuth?.state === "signingIn" ? 5_000 : 0);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [activeNav, connected, pornHubAuth, token]);
  const connect = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const nextToken = tokenInput.trim();
    if (!tokenPattern.test(nextToken)) {
      setError("Paste only the token printed by `lustre token`.");
      return;
    }
    setLoading(true);
    const sequence = ++refreshSequence.current;
    try {
      await refresh(nextToken, true);
      if (sequence !== refreshSequence.current) return;
      setToken(nextToken);
      setTokenInput("");
      notify("Connected to the local Lustre agent.");
    } catch (reason) {
      if (sequence === refreshSequence.current)
        setError(
          reason instanceof Error
            ? reason.message
            : "Unable to connect to the local agent.",
        );
    } finally {
      if (sequence === refreshSequence.current) setLoading(false);
    }
  };
  const apply = async (job: DownloadJob, action: JobAction) => {
    try {
      await agentRequest<DownloadJob>(token, `/v1/jobs/${job.id}/action`, {
        method: "POST",
        body: JSON.stringify({ action }),
      });
      await refresh(token, true);
      notify(`${jobActionLabel(action)} requested for ${titleFor(job)}.`);
    } catch (reason) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Unable to update this transfer.",
      );
    }
  };
  const saveDestination = async (
    input: { name: string; baseURL: string; username: string; remotePath: string; allowInvalidCertificate: boolean; password: string },
  ) => {
    await agentRequest<DestinationProfile>(token, "/v1/destinations/webdav", {
      method: "POST",
      body: JSON.stringify(input),
    });
    await refresh(token, true);
    notify(`${input.name} saved to the local agent.`);
  };
  const connectGoogleDrive = async () => {
    const next = await agentRequest<DestinationProfile[]>(token, "/v1/destinations/google-drive/connect", { method: "POST" });
    setDestinations(next);
    notify("Google Drive connected through the paired Mac.");
  };
  const loadGoogleDriveFolders = (id: string, path: string) =>
    agentRequest<GoogleDriveFolder[]>(token, `/v1/destinations/${id}/google-drive/folders?path=${encodeURIComponent(path)}`);
  const selectGoogleDriveFolder = async (id: string, path: string) => {
    const next = await agentRequest<DestinationProfile[]>(token, `/v1/destinations/${id}/google-drive/folder`, { method: "POST", body: JSON.stringify({ path }) });
    setDestinations(next);
    notify(`Google Drive uploads will use ${path}.`);
  };
  const createGoogleDriveFolder = async (id: string, path: string) => {
    await agentRequest<Record<string, unknown>>(token, `/v1/destinations/${id}/google-drive/folders`, { method: "POST", body: JSON.stringify({ path }) });
    notify(`Created ${path.split("/").at(-1)} in Google Drive.`);
  };
  const loadLocalDownloadFolder = () =>
    agentRequest<{ mode: "default" | "custom"; folderName: string }>(token, "/v1/destinations/local-folder");
  const chooseLocalDownloadFolder = async () => {
    const status = await agentRequest<{ mode: "default" | "custom"; folderName: string }>(token, "/v1/destinations/local-folder", { method: "POST" });
    notify(`Local downloads will be saved in ${status.folderName}.`);
    return status;
  };
  const resetLocalDownloadFolder = async () => {
    const status = await agentRequest<{ mode: "default" | "custom"; folderName: string }>(token, "/v1/destinations/local-folder", { method: "DELETE" });
    notify("Local downloads reset to Lustre’s default Downloads folder.");
    return status;
  };
  const testDestination = async (id: string) => {
    const profile = destinations.find((item) => item.id === id);
    const result = await agentRequest<{ message: string }>(
      token,
      profile?.kind === "google_drive" ? `/v1/destinations/${id}/google-drive/test` : `/v1/destinations/${id}/test`,
      { method: "POST" },
    );
    notify(result.message);
    return result.message;
  };
  const deleteDestination = async (id: string) => {
    const profile = destinations.find((item) => item.id === id);
    await agentRequest<{ status: string }>(token, `/v1/destinations/${id}`, {
      method: "DELETE",
    });
    await refresh(token, true);
    notify(`${profile?.name ?? "Destination"} removed.`);
  };
  const disconnect = () => {
    setActiveNav("Devices");
  };
  const manualRefresh = async () => {
    try {
      await refresh(token, true);
      notify("Live agent state refreshed.");
    } catch (reason) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Unable to refresh the local agent.",
      );
    }
  };
  const signInWithPornHub = async () => {
    const sequence = authStatusSequence.current.beginAction();
    try {
      const presence = await fetchCloudPresence(token);
      if (!cloudDeviceIsOnline(presence)) throw new Error(cloudDeviceOfflineMessage(presence)!);
      const status = await agentRequest<PornHubAuthStatus>(
        token,
        "/v1/auth/pornhub/login",
        { method: "POST" },
      );
      if (authStatusSequence.current.acceptsAction(sequence)) {
        setPornHubAuth(status);
        notify("PornHub sign-in window opened.");
      }
    } catch (reason) {
      if (authStatusSequence.current.acceptsAction(sequence))
        setError(
          reason instanceof Error ? reason.message : "PornHub sign-in failed.",
        );
    }
  };
  const signOutOfPornHub = async () => {
    const sequence = authStatusSequence.current.beginAction();
    try {
      const signingIn = pornHubAuth?.state === "signingIn";
      const status = await agentRequest<PornHubAuthStatus>(
        token,
        signingIn ? "/v1/auth/pornhub/login" : "/v1/auth/pornhub",
        { method: "DELETE" },
      );
      if (authStatusSequence.current.acceptsAction(sequence)) {
        setPornHubAuth(status);
        notify(pornHubAuthMutationMessage(signingIn, status.state));
      }
    } catch (reason) {
      if (authStatusSequence.current.acceptsAction(sequence))
        setError(
          reason instanceof Error ? reason.message : "PornHub sign-out failed.",
        );
    }
  };
  const loadFeedSites = useCallback(() => {
    if (!token)
      return Promise.reject(new Error("Pair a Mac before opening Cloud Feed."));
    const key = cloudFeedRequestKey({ deviceID: token, kind: "feed_sites" });
    return coalesceCloudFeedRequest(feedRequests.current, key, () =>
      beginFeedCommand<FeedSite[]>(token, { kind: "feed_sites" }, (result) => (result.sites ?? []) as FeedSite[]),
    );
  }, [token]);
  const loadFeedPage = useCallback(
    (site: FeedSite["id"], query: FeedQuery) => {
      if (!token)
        return Promise.reject(
          new Error("Pair a Mac before opening Cloud Feed."),
        );
      const normalizedQuery = normalizeCloudFeedQuery(query.text);
      const key = cloudFeedRequestKey({
        deviceID: token,
        kind: "feed_page",
        siteID: site,
        query: normalizedQuery,
        page: query.page,
      });
      const search = new URLSearchParams({ site, page: String(query.page) });
      if (normalizedQuery) search.set("q", normalizedQuery);
      return coalesceCloudFeedRequest(feedRequests.current, key, () =>
        beginFeedCommand<FeedPage>(token, {
          kind: "feed_page",
          siteID: site,
          page: query.page,
          query: normalizedQuery || undefined,
        }, (result) => result.page as FeedPage),
      );
    },
    [token],
  );
  const loadFeedDestinations = useCallback(() => {
    if (!token)
      return Promise.reject(new Error("Pair a Mac before loading destinations."));
    const key = cloudFeedRequestKey({
      deviceID: token,
      kind: "destinations_list",
    });
    return coalesceCloudFeedRequest(feedRequests.current, key, () =>
      agentRequest<Destination[]>(token, "/v1/destinations"),
    );
  }, [token]);
  useEffect(() => {
    const needsDestinations = cloudDestinationViewNeedsRefresh(
      activeNav,
      feedEnabled,
    );
    if (!feedDestinationsEnabled || !needsDestinations || !token)
      return;
    let active = true;
    void loadFeedDestinations()
      .then((nextDestinations) => {
        if (!active) return;
        setDestinations(nextDestinations);
      })
      .catch((reason) => {
        if (!active) return;
        setError(
          reason instanceof Error
            ? reason.message
            : "Unable to load destinations from the paired Mac.",
        );
      });
    return () => {
      active = false;
    };
  }, [activeNav, feedDestinationsEnabled, feedEnabled, loadFeedDestinations, token]);
  const queueFeedItem = useCallback(
    async (item: FeedItem, destination: string, requestID: string) => {
      await agentRequest<DownloadJob>(token, "/v1/feed/queue", {
        method: "POST",
        body: JSON.stringify({
          requestID,
          itemID: item.id,
          siteID: item.siteID,
          sourcePageURL: item.sourcePageURL,
          title: item.title,
          destination,
        }),
      });
    },
    [token],
  );
  const resolveFeedItem = useCallback(
    (item: WatchFeedItem) =>
      agentRequest<WatchPlaybackResolution>(token, "/v1/feed/resolve", {
        method: "POST",
        body: JSON.stringify({
          itemID: item.id,
          siteID: item.siteID,
          sourcePageURL: item.sourcePageURL,
        }),
      }),
    [token],
  );
  const resolveWatchlistItem = useCallback(
    (item: WatchlistEntry) =>
      agentRequest<WatchPlaybackResolution>(token, "/v1/watchlist/resolve", {
        method: "POST",
        body: JSON.stringify({ watchlistID: item.id }),
      }),
    [token],
  );
  const saveFeedItem = useCallback(async (item: FeedItem) => {
    const response = await fetch("/api/cloud/v1/watchlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sourcePageURL: item.sourcePageURL,
        title: item.title,
        provider: item.studio ?? item.siteID,
        thumbnailURL: item.thumbnailURL ?? null,
      }),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error?.message ?? "Unable to save this video.");
  }, []);
  const queueWatchItem = useCallback(async (item: WatchFeedItem) => {
    await queueFeedItem(item as FeedItem, "local", crypto.randomUUID());
    if (token) await refresh(token, true);
  }, [queueFeedItem, refresh, token]);
  const loadFeedAsset = useCallback(async (url: string, kind: "image" | "video") => {
    if (!token || !feedMediaEnabled) throw new Error("Feed media is unavailable.");
    const ticketResponse = await fetch(`/api/cloud/v1/devices/${token}/feed-assets/ticket`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, kind }),
      cache: "no-store",
    });
    const ticketPayload = await ticketResponse.json().catch(() => ({}));
    if (!ticketResponse.ok || typeof ticketPayload.ticket !== "string" || typeof ticketPayload.assetURL !== "string") {
      throw new Error("Unable to authorize feed media.");
    }
    const assetResponse = await fetch(ticketPayload.assetURL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ticket: ticketPayload.ticket }),
      cache: "no-store",
    });
    if (!assetResponse.ok) throw new Error("Unable to load feed media.");
    return assetResponse.blob();
  }, [feedMediaEnabled, token]);
  const refreshAfterFeedQueue = useCallback(async () => {
    await refresh(token, true);
  }, [refresh, token]);
  const latestLogs = useMemo(
    () =>
      jobs
        .flatMap((job) => (job.logs ?? []).map((log) => ({ ...log, job })))
        .sort(
          (a, b) =>
            agentDateMilliseconds(b.timestamp) -
            agentDateMilliseconds(a.timestamp),
        )
        .slice(0, 5),
    [jobs],
  );
  return (
    <main className={`studio-shell ${activeNav === "Feed" || activeNav === "Watchlist" ? "watch-mode" : activeNav === "Home" ? "home-mode" : activeNav === "Downloads" ? "download-mode" : ""}`}>
      <section className="studio-shell-workspace" id="workspace">
        {activeNav === "Devices" ? (
          <DevicesView />
        ) : feedEnabled && activeNav === "Feed" ? (
          <WatchApp activeTab="feed" canQueue={connected && feedQueueEnabled} canAgentResolve={connected} onQueue={queueWatchItem} onAgentResolveFeed={resolveFeedItem} onAgentResolveWatchlist={resolveWatchlistItem} onTabChange={(tab) => setActiveNav(tab === "feed" ? "Feed" : "Watchlist")} onExit={() => setActiveNav("Home")} />
        ) : activeNav === "Downloads" ? (
          <DownloadsView
            jobs={jobs}
            destinations={destinations}
            error={error}
            selectedJobId={selectedDownloadId}
            onSelectJob={setSelectedDownloadId}
            onQueue={() => setShowQueue(true)}
            onAction={apply}
            initialStatus={downloadInitialStatus}
          />
        ) : activeNav === "Library" ? (
          <LibraryView
            deviceID={token}
            connected={connected}
            destinations={destinations}
            onJobsChanged={() => refresh(token, true)}
            onReExtract={(url) => {
              const key = `lustre.home.workspace.${token}`;
              let current: Record<string, unknown> = {};
              try { current = JSON.parse(sessionStorage.getItem(key) ?? "{}"); } catch {}
              sessionStorage.setItem(key, JSON.stringify({ ...current, draft: url }));
              setActiveNav("Home");
            }}
          />
        ) : activeNav === "Watchlist" ? (
          <WatchApp activeTab="watchlist" canQueue={connected && feedQueueEnabled} canAgentResolve={connected} onQueue={queueWatchItem} onAgentResolveFeed={resolveFeedItem} onAgentResolveWatchlist={resolveWatchlistItem} onTabChange={(tab) => setActiveNav(tab === "feed" ? "Feed" : "Watchlist")} onExit={() => setActiveNav("Home")} />
        ) : activeNav === "Destinations" ? (
          <DestinationsView
            destinations={destinations}
            jobs={jobs}
            error={error}
            onSave={saveDestination}
            onTest={testDestination}
            onDelete={deleteDestination}
            onConnectGoogleDrive={connectGoogleDrive}
            onLoadGoogleDriveFolders={loadGoogleDriveFolders}
            onSelectGoogleDriveFolder={selectGoogleDriveFolder}
            onCreateGoogleDriveFolder={createGoogleDriveFolder}
            onLoadLocalDownloadFolder={loadLocalDownloadFolder}
            onChooseLocalDownloadFolder={chooseLocalDownloadFolder}
            onResetLocalDownloadFolder={resetLocalDownloadFolder}
          />
        ) : activeNav === "Activity" ? (
          <ActivityView
            jobs={jobs}
            destinations={destinations}
            error={error}
            onOpenDownloads={(jobId) => {
              if (jobId) setSelectedDownloadId(jobId);
              setActiveNav("Downloads");
            }}
          />
        ) : activeNav === "Settings" ? (
          <SettingsView
            connected={connected}
            pollingInterval={pollingInterval}
            jobsCount={jobs.length}
            destinationsCount={destinations.length}
            error={error}
            onPollingIntervalChange={setPollingInterval}
            onRefresh={manualRefresh}
            onDisconnect={disconnect}
            pornHubAuth={pornHubAuth}
            onPornHubSignIn={signInWithPornHub}
            onPornHubSignOut={signOutOfPornHub}
          />
        ) : (
          <>
            <HomeWorkspaceView
              deviceID={token}
              connected={connected}
              jobCounts={jobCounts}
              destinations={destinations}
              onJobsChanged={() => refresh(token, true)}
              onOpenDownloads={(status) => {
                setSelectedDownloadId(null);
                setJobs([]);
                setHomeDownloadsStatus(status);
              }}
            />
          </>
        )}
      </section>
      {activeNav === "Home" && homeDownloadsStatus && (
        <div className="home-downloads-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setHomeDownloadsStatus(null); }}>
          <section ref={homeDownloadsModalRef} className="home-downloads-modal download-mode" role="dialog" aria-modal="true" aria-label={`${homeDownloadsStatus} downloads`}>
            <button className="home-downloads-close" aria-label="Close downloads" onClick={() => setHomeDownloadsStatus(null)}>×</button>
            <DownloadsView
              jobs={jobs}
              destinations={destinations}
              error={error}
              selectedJobId={selectedDownloadId}
              onSelectJob={setSelectedDownloadId}
              onQueue={() => setShowQueue(true)}
              onAction={apply}
              fixedStatus={homeDownloadsStatus}
              variant="modal"
            />
          </section>
        </div>
      )}
      <div className="studio-bottom-navigation">
        <div className={`studio-nav-menu ${menuOpen ? "open" : ""}`}>
          {(["Watchlist", "Downloads", "Destinations", "Activity", "Devices"] as const).map((label) => (
            <button key={label} onClick={() => { setActiveNav(label); setMenuOpen(false); }}>
              <Glyph name={label === "Watchlist" ? "archive" : label === "Downloads" ? "downloads" : label === "Destinations" ? "folder" : label === "Activity" ? "activity" : "computer"} />
              {label}
            </button>
          ))}
          <span className="studio-account"><UserButton appearance={{ elements: { avatarBox: "avatar" } }} /> Account</span>
        </div>
        <nav aria-label="Primary navigation">
          <button className="studio-menu-toggle" aria-expanded={menuOpen} aria-label="More pages" onClick={() => setMenuOpen((value) => !value)}><Glyph name="menu" size={22} /></button>
          <span className="studio-nav-divider" aria-hidden="true" />
          {([
            ["Home", "home"],
            ...(feedEnabled ? [["Feed", "broadcast"]] : []),
            ["Library", "books"],
            ["Settings", "settings"],
          ] as Array<[string, string]>).map(([label, icon]) => (
            <button key={label} className={activeNav === label ? "active" : ""} onClick={() => { setActiveNav(label); setMenuOpen(false); }}>
              <Glyph name={icon} size={22} />
              <span>{label}</span>
              {label === "Home" && jobCounts.active > 0 && <b>{jobCounts.active}</b>}
            </button>
          ))}
        </nav>
      </div>
      {showQueue && (
        <QueueSheet
          destinations={destinations}
          token={token}
          onClose={() => setShowQueue(false)}
          onQueued={async () => {
            await refresh(token, true);
            notify("Transfer queued with the local agent.");
          }}
        />
      )}
      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </main>
  );
}

export default CloudFullDashboard;
