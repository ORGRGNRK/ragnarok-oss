# syntax=docker/dockerfile:1
# Business MCP image. Multi-stage: build with dev deps, ship prod deps + dist only.
# Never copies .env, dumps or data (see .dockerignore).
ARG NODE_IMAGE=node:22.23.3-bookworm-slim

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production \
    BUSINESS_HTTP_HOST=0.0.0.0 \
    BUSINESS_HTTP_PORT=8787
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY sql ./sql
COPY evals ./evals
COPY scripts/run-evals.mjs scripts/mcp-check.mjs ./scripts/
USER node
EXPOSE 8787
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8787/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
# Default: Streamable HTTP on :8787 (published to 127.0.0.1 only by compose.yaml).
# stdio: docker compose exec -T mcp node dist/index.js
CMD ["node", "dist/http.js"]
