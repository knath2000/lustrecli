import type { AgentDate } from "@/lib/agent-date";
import type { JobStatus } from "@/lib/job-actions";

export type TransferPhase = "resolving" | "downloading" | "materializing" | "postProcessing" | "uploading" | "verifying";

export type JobLog = {
  timestamp: AgentDate;
  level: "info" | "error";
  message: string;
};

export type DownloadJob = {
  id: string;
  sourcePageURL: string;
  displayName?: string;
  preferredQualityLabel?: string;
  destination: string;
  status: JobStatus;
  message: string;
  progress?: number;
  downloadedBytes?: number;
  totalBytes?: number;
  transferPhase?: TransferPhase;
  phaseProgress?: number;
  phaseBytes?: number;
  phaseTotalBytes?: number;
  phaseTotalIsEstimated?: boolean;
  phaseBytesPerSecond?: number;
  phaseETASeconds?: number;
  logs?: JobLog[];
  queuePriority?: number;
  updatedAt: AgentDate;
};
