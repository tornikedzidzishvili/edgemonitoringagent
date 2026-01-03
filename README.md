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

## Deploy to a new Ubuntu server (safe)

These steps only create/update a single container named `edgemonitoringagent` and a single folder under `/opt/edgemonitoringagent`. They do not prune images/volumes and do not touch other containers.

### 1) SSH into the server

From your local machine:

```bash
ssh -i ~/.ssh/id_ed25519 root@<SERVER_IP>
```

### 2) Create the agent env file

On the server (recommended: keep secrets out of shell history by using a heredoc):

```bash
install -d -m 700 /opt/edgemonitoringagent
cat >/opt/edgemonitoringagent/agent.env <<'EOF'
CENTRAL_API_URL=https://monitoring.edge.ge/api
SERVER_NAME=<friendly-name>
AGENT_API_KEY=<agent-api-key>
REPORT_INTERVAL_SECONDS=30
DOCKER_SOCKET_PATH=/var/run/docker.sock
EOF

chmod 600 /opt/edgemonitoringagent/agent.env
```

### 3) Install / update the agent container

On the server:

```bash
git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git /opt/edgemonitoringagent/src
cd /opt/edgemonitoringagent/src

# Pick a tag (recommended) or use main
git fetch --tags origin
git checkout -f v0.1.1

sudo bash scripts/deploy-ubuntu.sh --tag v0.1.1
```

Logs:

```bash
docker logs -f edgemonitoringagent
```

### Changing `agent.env`

If you edit `/opt/edgemonitoringagent/agent.env`, you must recreate the container for changes to take effect (restart is not enough):

```bash
docker rm -f edgemonitoringagent
docker run -d --name edgemonitoringagent \
  --restart unless-stopped \
  --env-file /opt/edgemonitoringagent/agent.env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  edgemonitoringagent:v0.1.1
```

## Run (Node)
Requires Node.js 20+.

```bash
npm install
npm run build
npm start
```
