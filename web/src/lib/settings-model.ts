export const supportedPollingIntervals = [2000, 5000, 10000] as const;
export type PollingInterval = typeof supportedPollingIntervals[number];

export function normalizePollingInterval(value: number): PollingInterval {
  return supportedPollingIntervals.includes(value as PollingInterval) ? value as PollingInterval : 2000;
}

export function pollingIntervalLabel(value: number): string {
  return `Every ${normalizePollingInterval(value) / 1000} seconds`;
}
