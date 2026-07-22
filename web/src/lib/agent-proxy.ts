const agentBaseURL = "http://127.0.0.1:63406";

export function buildAgentURL(path: string): URL {
  const url = new URL(path, agentBaseURL);
  if (!url.pathname.startsWith("/v1/")) {
    throw new Error("Only the versioned agent API can be proxied.");
  }
  return url;
}
