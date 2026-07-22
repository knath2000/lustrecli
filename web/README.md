# Lustre Cloud Web

The Next.js frontend for Lustre's future account-based, multi-device remote-control product. This first slice implements the local device workspace and Queue Transfer sheet against the real Swift agent API.

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
- Queueing creates a durable agent job, and pause/resume/cancel/retry invoke real job actions.
- Numeric Foundation `Date` values from the Swift API are normalized at the frontend boundary; ISO-8601 dates are also accepted.

The loopback bridge is for local development. The hosted product will use an outbound authenticated device channel rather than attempting to access a user's loopback interface from the cloud.

## Validation

```sh
npm test
npm run lint
npm run build
```