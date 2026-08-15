# Lustre Watch cloud runtime

This directory contains the portable cloud extraction runtime used by the
Lustre Cloud Feed and Watchlist:

- `services/resolver`: protected Fastify resolver for Modal
- `services/assets-worker`: exact-ticket thumbnail proxy for Cloudflare Workers
- `packages/contracts` and `packages/providers`: bounded shared contracts and parsers
- `extensions`: scoped Chrome and Firefox browser-capture fallbacks
- `infra/modal`: scale-to-zero Modal wrapper

Run `npm install`, `npm test`, `npm run typecheck`, and `npm run build` before
release. Follow `infra/modal/README.md` for the resolver. Set the asset Worker's
`WEB_ORIGIN` to the exact Lustre Cloud production origin, configure
`ASSET_TICKET_SECRET` with `wrangler secret put`, and use `wrangler deploy
--dry-run` before an authorized production deployment.

The matching Vercel environment variables are documented in
`../web/.env.example`. Apply `../web/drizzle/0009_lustre_feed_cache.sql` before
enabling Feed. Production deployment, secrets, and migrations are intentionally
not performed by repository builds.
