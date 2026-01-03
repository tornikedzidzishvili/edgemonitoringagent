# EdgeMonitoringAgent

Standalone agent that reports Docker + system snapshots to the Edge Monitoring central API.

## Configuration
Copy `.env.example` to `.env` and fill values:
- `CENTRAL_API_URL`
  - Direct API: `http://<api-host>:4000`
  - Behind reverse proxy: `https://<monitoring-host>/api`
- `SERVER_NAME`
- `AGENT_API_KEY`
- `REPORT_INTERVAL_SECONDS` (optional)
- `DOCKER_SOCKET_PATH` (optional, default `/var/run/docker.sock`)

## Run (recommended: Docker)
On the monitored server:

```bash
install -d -m 700 /opt/edgemonitoringagent
cat >/opt/edgemonitoringagent/agent.env <<'EOF'
CENTRAL_API_URL=https://monitoring.edge.ge/api
SERVER_NAME=my-server
AGENT_API_KEY=<AGENT_API_KEY>
REPORT_INTERVAL_SECONDS=30
DOCKER_SOCKET_PATH=/var/run/docker.sock
EOF

docker pull ghcr.io/<owner>/edgemonitoringagent:latest

docker run -d --name edgemonitoringagent \
  --restart unless-stopped \
  --env-file /opt/edgemonitoringagent/agent.env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/<owner>/edgemonitoringagent:latest
```

Logs:

```bash
docker logs -f edgemonitoringagent
```

## Run (Node)
Requires Node.js 20+.

```bash
npm install
npm run build
npm start
```
