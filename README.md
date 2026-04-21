# EdgeMonitoringAgent

Lightweight agent that reports Docker + system snapshots to the Edge Monitoring central API at `https://monitoring.edge.ge`.

- Node.js 22 LTS, TypeScript, `undici` HTTP client
- Hardened multi-stage Docker image (non-root, read-only rootfs, `tini` init)
- Or native `systemd` unit with full hardening sandbox for non-Docker hosts

## Configuration

| Variable | Required | Default | Notes |
|---|---|---|---|
| `CENTRAL_API_URL` | yes | `https://monitoring.edge.ge/api` | API base URL |
| `SERVER_NAME` | yes | — | Display name in the dashboard |
| `AGENT_API_KEY` | yes | — | Issued once by the central API; min 16 chars |
| `REPORT_INTERVAL_SECONDS` | no | `30` | 5–3600 |
| `REPORT_HTTP_TIMEOUT_MS` | no | `15000` | 1000–60000 |
| `DOCKER_SOCKET_PATH` | no | `/var/run/docker.sock` | Only read by the agent |
| `AGENT_HEARTBEAT_PATH` | no | `/tmp/agent-heartbeat` | Touched each successful tick; used by Docker HEALTHCHECK |

Copy `.env.example` to `.env` for local dev.

## Deploy — Docker (recommended for Docker hosts)

The `deploy-ubuntu.sh` script creates one container (`edgemonitoringagent`) and one directory (`/opt/edgemonitoringagent`). It does **not** prune images/volumes and does **not** touch other containers.

```bash
# 1) SSH in as root
ssh root@<SERVER_IP>

# 2) Clone (once)
git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git \
  /opt/edgemonitoringagent/src

# 3) Install / update
cd /opt/edgemonitoringagent/src
sudo bash scripts/deploy-ubuntu.sh --tag v0.2.0
```

The script prompts for `SERVER_NAME` and `AGENT_API_KEY` and writes `/opt/edgemonitoringagent/agent.env` (root:root 0600).

Non-interactive (CI / automation):

```bash
sudo AGENT_API_KEY='xxxxxxxxxxxxxxxx' \
  bash scripts/deploy-ubuntu.sh \
  --tag v0.2.0 \
  --server-name "Spacehost Web" \
  --non-interactive
```

### What the deploy script does for security

| Flag | Purpose |
|---|---|
| `--read-only` | Container root filesystem is immutable |
| `--tmpfs /tmp` | Only `/tmp` is writable (heartbeat file) |
| `--cap-drop=ALL` | Drops every Linux capability |
| `--security-opt=no-new-privileges:true` | Disallows privilege escalation |
| `--pids-limit`, `--memory`, `--cpus` | Hard resource caps |
| `--group-add $DOCKER_GID` | Grants Docker socket access without root |

The Dockerfile itself runs as UID `10001` (`agent`), drops dev dependencies, and uses `tini` as PID 1 for proper signal handling.

### A note on the Docker socket

Mounting `/var/run/docker.sock` grants the container **full control over the host Docker daemon**. The `:ro` suffix is *not* effective security here — it only prevents replacing the socket file; commands sent through the socket still write. If you need stricter isolation, front the socket with [`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy) and set `DOCKER_SOCKET_PATH` to point at the proxy instead.

## Deploy — native systemd (for non-Docker hosts like CyberPanel)

```bash
git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git \
  /opt/edgemonitoringagent/src
cd /opt/edgemonitoringagent/src
sudo bash scripts/deploy-cyberpanel.sh --tag v0.2.0
```

This installs Node.js 22, creates a dedicated `edgeagent` system user, builds from source, and installs a hardened systemd unit with `ProtectSystem=strict`, `NoNewPrivileges=true`, `SystemCallFilter=@system-service`, a narrow `CapabilityBoundingSet`, and a dedicated `RuntimeDirectory`.

Inspect / operate:

```bash
journalctl -u edgemonitoringagent -f     # tail logs
systemctl status edgemonitoringagent      # quick status
systemctl restart edgemonitoringagent     # restart (picks up env changes)
systemd-analyze security edgemonitoringagent   # optional: security score
```

## Updating `agent.env`

Docker: a plain `docker restart` does *not* pick up env changes — the script recreates the container. To update manually:

```bash
sudo bash scripts/deploy-ubuntu.sh --tag <current-tag>
```

systemd: edit `/opt/edgemonitoringagent/agent.env`, then:

```bash
sudo systemctl restart edgemonitoringagent
```

## Upgrading

```bash
cd /opt/edgemonitoringagent/src
git fetch --tags
sudo bash scripts/deploy-ubuntu.sh --tag <new-tag>   # Docker
# or
sudo bash scripts/deploy-cyberpanel.sh --tag <new-tag>   # systemd
```

## Uninstall

Docker:

```bash
docker rm -f edgemonitoringagent
sudo rm -rf /opt/edgemonitoringagent
```

systemd:

```bash
sudo systemctl disable --now edgemonitoringagent
sudo rm -f /etc/systemd/system/edgemonitoringagent.service
sudo systemctl daemon-reload
sudo rm -rf /opt/edgemonitoringagent
sudo userdel edgeagent 2>/dev/null || true
```

## Troubleshooting

- **`AGENT_API_KEY must be at least 16 characters`** — the API issues keys of the correct length; copy without trimming.
- **`Docker socket not found`** — Docker isn't installed or the daemon isn't running.
- **Repeated `tick.failed` logs with `ECONNREFUSED` / `ETIMEDOUT`** — check `CENTRAL_API_URL` and outbound network to `monitoring.edge.ge:443`.
- **`Central API 401`** — rotate the agent key in the dashboard and redeploy.
- **Exponential backoff** — after consecutive failures the agent doubles its interval up to 5 minutes, then resumes the normal cadence once a tick succeeds.

## Develop

Requires Node.js 22+.

```bash
npm install
cp .env.example .env   # fill in values
npm run dev            # watch mode
npm run typecheck
npm run build
```
