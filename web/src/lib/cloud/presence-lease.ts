export const DEFAULT_PRESENCE_CONNECTION_LEASE_SECONDS = 9 * 60;
export const MINIMUM_PRESENCE_CONNECTION_LEASE_SECONDS = 60;
export const MAXIMUM_PRESENCE_CONNECTION_LEASE_SECONDS = 9 * 60;

export function presenceConnectionLeaseSeconds(environment: NodeJS.ProcessEnv = process.env) {
  const value = Number(environment.LUSTRE_PRESENCE_LEASE_SECONDS);
  return Number.isInteger(value) && value >= MINIMUM_PRESENCE_CONNECTION_LEASE_SECONDS && value <= MAXIMUM_PRESENCE_CONNECTION_LEASE_SECONDS
    ? value
    : DEFAULT_PRESENCE_CONNECTION_LEASE_SECONDS;
}
