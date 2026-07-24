import type { DownloadJob, TransferPhase } from "@/lib/download-job";

const phaseLabels: Record<TransferPhase, string> = {
  resolving: "Resolving",
  downloading: "Downloading",
  materializing: "Materializing",
  postProcessing: "Post-processing",
  uploading: "Uploading",
  verifying: "Verifying",
};

type ProgressState = "determinate" | "indeterminate" | "static";

export type DownloadProgressDisplay = {
  phaseLabel: string;
  percent?: number;
  state: ProgressState;
  bytesWritten?: number;
  totalBytes?: number;
  totalIsEstimated: boolean;
  speed?: number;
  etaSeconds?: number;
  progressLabel: string;
  accessibleText: string;
};

function validNumber(value: number | undefined): number | undefined {
  return value !== undefined && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function validFraction(value: number | undefined): number | undefined {
  return value !== undefined && Number.isFinite(value) && value >= 0 ? Math.min(1, value) : undefined;
}

export function formatJobStatus(status: DownloadJob["status"]): string {
  return status.replace(/([A-Z])/g, " $1").replace(/^./, (character) => character.toUpperCase());
}

export function formatBytes(value: number | undefined): string {
  if (value === undefined) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  return `${amount.toFixed(unit ? 1 : 0)} ${units[unit]}`;
}

export function formatSpeed(value: number | undefined): string | undefined {
  const speed = validNumber(value);
  return speed && speed > 0 ? `${formatBytes(speed)}/s` : undefined;
}

export function formatETA(value: number | undefined): string | undefined {
  const seconds = validNumber(value);
  if (seconds === undefined) return undefined;
  const whole = Math.floor(seconds);
  if (whole < 60) return `${whole}s remaining`;
  if (whole < 3600) return `${Math.floor(whole / 60)}m ${whole % 60}s remaining`;
  return `${Math.floor(whole / 3600)}h ${Math.floor((whole % 3600) / 60)}m remaining`;
}

export function downloadProgressDisplay(job: DownloadJob): DownloadProgressDisplay {
  const fraction = validFraction(job.phaseProgress) ?? validFraction(job.progress);
  const phaseBytes = validNumber(job.phaseBytes);
  const phaseTotal = validNumber(job.phaseTotalBytes);
  const bytesWritten = phaseBytes ?? validNumber(job.downloadedBytes);
  const totalBytes = phaseTotal ?? validNumber(job.totalBytes);
  const totalIsEstimated = phaseTotal !== undefined ? job.phaseTotalIsEstimated === true : false;
  const terminal = job.status === "completed" || job.status === "failed" || job.status === "cancelled" || job.status === "paused" || job.status === "verificationRequired";
  const phaseLabel = job.status === "completed" ? "Completed" : terminal ? formatJobStatus(job.status) : job.transferPhase ? phaseLabels[job.transferPhase] : formatJobStatus(job.status);
  const percent = job.status === "completed" ? 100 : fraction === undefined ? undefined : Math.round(fraction * 100);
  const state: ProgressState = percent !== undefined ? "determinate" : job.status === "running" ? "indeterminate" : "static";
  const totalLabel = totalBytes === undefined ? "Total unavailable" : `${totalIsEstimated ? "Estimated " : ""}${formatBytes(totalBytes)}`;
  const progressLabel = percent === undefined ? phaseLabel : `${percent}%`;
  const speed = terminal ? undefined : validNumber(job.phaseBytesPerSecond);
  const etaSeconds = terminal ? undefined : validNumber(job.phaseETASeconds);
  const accessibleText = [phaseLabel, percent === undefined ? undefined : `${percent}%`, bytesWritten === undefined ? undefined : `${formatBytes(bytesWritten)} transferred`, totalLabel, formatSpeed(speed), formatETA(etaSeconds)].filter((value): value is string => Boolean(value)).join(", ");

  return { phaseLabel, percent, state, bytesWritten, totalBytes, totalIsEstimated, speed, etaSeconds, progressLabel, accessibleText };
}
