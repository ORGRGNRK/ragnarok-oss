# Pinned by digest (the exact image), not just the tag. Update both together.
FROM node:22.23.4-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts: no package gets to run its own install script (none of ours needs one)
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
RUN npm run build && npm prune --omit=dev --ignore-scripts --no-audit --no-fund
# dist/test stays in the image on purpose: ./kit test runs the end-to-end test inside this image.
USER node
ENV KIT_SCHEMA=/app/client/schema.json KIT_SEED=/app/client/seed.json
EXPOSE 8787
CMD ["node", "dist/src/http.js"]
