# Two targets from one build:
#   test    : everything incl. dev tools (vitest). Only ./kit test uses it, then deletes it.
#   runtime : what actually runs (dev tools pruned, runs as the unprivileged "node" user).
FROM node:22.23.4-alpine AS test
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json vitest.config.ts ./
COPY src ./src
COPY test ./test
RUN npm run build
ENV KIT_SCHEMA=/app/client/schema.json KIT_SEED=/app/client/seed.json

FROM test AS runtime
RUN npm prune --omit=dev --no-audit --no-fund
USER node
EXPOSE 8787
CMD ["node", "dist/src/http.js"]
