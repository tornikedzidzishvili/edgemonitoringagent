# syntax=docker/dockerfile:1.7

FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY tsconfig.json ./
COPY src ./src
RUN npm run build \
 && npm prune --omit=dev

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false

RUN apk add --no-cache tini ca-certificates \
 && addgroup -S -g 10001 agent \
 && adduser  -S -u 10001 -G agent -h /app -s /sbin/nologin agent

COPY --from=build --chown=agent:agent /app/node_modules ./node_modules
COPY --from=build --chown=agent:agent /app/dist ./dist
COPY --chown=agent:agent package.json ./

USER agent

ENV AGENT_HEARTBEAT_PATH=/tmp/agent-heartbeat

HEALTHCHECK --interval=60s --timeout=10s --start-period=45s --retries=3 \
  CMD node -e "const fs=require('fs');try{const s=fs.statSync(process.env.AGENT_HEARTBEAT_PATH||'/tmp/agent-heartbeat');process.exit(Date.now()-s.mtimeMs<5*60*1000?0:1)}catch{process.exit(1)}"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "--enable-source-maps", "dist/index.js"]
