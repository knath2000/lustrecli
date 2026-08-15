FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json tsconfig.base.json ./
COPY packages/contracts/package.json packages/contracts/
COPY packages/providers/package.json packages/providers/
COPY services/assets-worker/package.json services/assets-worker/
COPY services/resolver/package.json services/resolver/
RUN npm ci
COPY packages packages
COPY services/resolver services/resolver
RUN npm run build -w @lustre/resolver
RUN npx esbuild services/resolver/src/server.ts --bundle --platform=node --format=esm \
  --external:fastify --external:cheerio --external:zod \
  --outfile=services/resolver/dist/server.js

FROM node:22-bookworm-slim
ARG YT_DLP_VERSION=2026.07.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl python3 && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/yt-dlp" -o /usr/local/bin/yt-dlp \
  && echo "495be29ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd  /usr/local/bin/yt-dlp" | sha256sum -c - \
  && chmod 0755 /usr/local/bin/yt-dlp
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/services/resolver/dist ./services/resolver/dist
COPY package.json ./
USER 65532:65532
CMD ["node", "services/resolver/dist/server.js"]
