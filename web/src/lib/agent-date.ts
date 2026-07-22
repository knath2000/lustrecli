export type AgentDate = string | number;

const foundationReferenceDateMilliseconds = Date.UTC(2001, 0, 1);

export function agentDateMilliseconds(value: AgentDate): number {
  if (typeof value === "number") {
    return Number.isFinite(value)
      ? foundationReferenceDateMilliseconds + value * 1_000
      : 0;
  }

  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? milliseconds : 0;
}
