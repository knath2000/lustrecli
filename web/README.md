# Lustre Cloud Web

The Next.js frontend for Lustre's future account-based, multi-device remote-control product. This slice implements the local device workspace, Downloads ledger and Transfer Inspector, Destinations manager, Activity timeline, Settings, Queue Transfer sheet, and multi-source Feed against the real Swift agent API.

## Run locally

Start the Swift agent from the repository root:

```sh
swift run lustre-agent
```

Then start the web application:

```sh
cd web
npm install
npm run dev
```

Open `http://localhost:3000`. In another terminal, run `swift run lustre token` from the repository root and paste the token into the connection screen. The token remains in browser-tab memory only.

## Current architecture

- The browser calls the same-origin `/api/agent/v1/*` route.
- The Next.js route handler permits only versioned agent paths and forwards them to `127.0.0.1:63406` with the browser-supplied bearer token.
- Job and destination data comes from the running Swift agent; there are no dashboard placeholders.
- The Downloads screen provides live status counts, search, status and destination filters, job selection, complete bounded worker logs, and state-valid transfer controls.
- The Destinations screen manages real WebDAV profiles, validates HTTPS-only input, tests remote authentication/write access, displays explicit TLS exceptions, and leaves passwords in the local agent's macOS Keychain.
- Activity flattens and classifies the bounded worker logs already attached to durable jobs; agent-wide connectivity and configuration events await a dedicated event API.
- Settings applies session-only polling cadence changes, manual refresh, disconnect, and status-only PornHub sign-in/logout controls without inventing unsupported Swift-agent preferences. Credentials and cookies never enter the Next.js process.
- Queueing creates a durable agent job, and pause/resume/cancel/retry/Force Start invoke real job actions. Force Start is offered only for queued jobs.
- Feed loads normalized AllPornStream, OnlyFan420, HQPorner, public PornHub, and signed-in PornHub section cards through the authenticated agent proxy, queues individual or selected cards to local/WebDAV destinations, derives card state from durable jobs, and rotates up to four distinct scene thumbnails on hover.
- The proxy preserves validated feed query strings such as `site=allpornstream&page=1`; it still cannot target arbitrary hosts.
- Numeric Foundation `Date` values from the Swift API are normalized at the frontend boundary; ISO-8601 dates are also accepted.

The loopback bridge is for local development. The hosted product will use an outbound authenticated device channel rather than attempting to access a user's loopback interface from the cloud.

## Validation

```sh
npm test
npm run lint
npm run build
```