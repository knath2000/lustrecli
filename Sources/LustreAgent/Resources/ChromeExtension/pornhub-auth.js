(() => {
  const extensionAPI = globalThis.browser ?? globalThis.chrome;
  const marker = location.hash.match(/(?:^#|&)lustre-pornhub-auth=([0-9a-f-]{36})(?:&|$)/i);
  let sending = false;

  const check = async () => {
    if (sending) return;
    const requestID = marker?.[1]?.toLowerCase();
    sending = true;
    const response = await extensionAPI.runtime.sendMessage({
      type: "pornhub_auth_probe_v1",
      version: 1,
      requestID
    });
    if (response?.type !== "capture_accepted") sending = false;
  };

  check();
  const timer = setInterval(check, 1000);
  addEventListener("pagehide", () => clearInterval(timer), { once: true });
})();
