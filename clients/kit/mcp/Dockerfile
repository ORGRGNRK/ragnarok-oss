FROM node:22.23.4-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
RUN npm run build && npm prune --omit=dev --no-audit --no-fund
USER node
ENV KIT_SCHEMA=/app/client/schema.json KIT_SEED=/app/client/seed.json
EXPOSE 8787
CMD ["node", "dist/src/http.js"]
