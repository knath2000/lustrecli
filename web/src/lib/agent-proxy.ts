const agentBaseURL = "http://127.0.0.1:63406";

export function buildAgentURL(path: string, search = ""): URL {
  const url = new URL(path, agentBaseURL);
  if (!url.pathname.startsWith("/v1/")) {
    throw new Error("Only the versioned agent API can be proxied.");
  }
  if (search) url.search = search;
  return url;
}
