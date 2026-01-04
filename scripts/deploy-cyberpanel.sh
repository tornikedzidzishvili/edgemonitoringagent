#!/usr/bin/env bash
set -euo pipefail

TAG=""
REPO_DIR="/home/cyberpanel/edgemonitoringagent/src"
INSTALL_DIR="/home/cyberpanel/edgemonitoringagent"
ENV_FILE="/home/cyberpanel/edgemonitoringagent/agent.env"
SERVICE_NAME="cyberpanel-monitoring-agent"

CENTRAL_API_URL="https://monitoring.edge.ge/api"
REPORT_INTERVAL_SECONDS_DEFAULT="30"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/deploy-cyberpanel.sh --tag <git-tag>

Options:
  --tag <git-tag>          Git tag to checkout (recommended), e.g. v0.1.1
  --repo-dir <path>        Repo directory (default: /home/cyberpanel/edgemonitoringagent/src)
  --env-file <path>        Env file path to write (default: /home/cyberpanel/edgemonitoringagent/agent.env)
  --service <name>         Systemd service name (default: cyberpanel-monitoring-agent)

Behavior:
  - Installs Node.js 20 if not present
  - Builds the agent from source
  - Runs as a native systemd service (no Docker required)
  - Prompts for SERVER_NAME + AGENT_API_KEY and writes the env file
  - Uses CENTRAL_API_URL=https://monitoring.edge.ge/api
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"; shift 2 ;;
    --repo-dir)
      REPO_DIR="${2:-}"; shift 2 ;;
    --env-file)
      ENV_FILE="${2:-}"; shift 2 ;;
    --service)
      SERVICE_NAME="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "ERROR: --tag is required (example: --tag v0.1.1)" >&2
  exit 2
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: please run as root (use sudo)" >&2
  exit 1
fi

# Install Node.js 20 if not present or version is too old
install_nodejs() {
  if command -v node >/dev/null 2>&1; then
    NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
    if [[ "$NODE_VERSION" -ge 20 ]]; then
      echo "Node.js $(node -v) already installed"
      return 0
    fi
  fi

  echo "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  echo "Node.js $(node -v) installed"
}

install_nodejs

install -d -m 755 "$INSTALL_DIR"

SERVER_NAME=""
AGENT_API_KEY=""
REPORT_INTERVAL_SECONDS="$REPORT_INTERVAL_SECONDS_DEFAULT"

printf 'Server name (e.g. "CyberPanel SSH"): '
IFS= read -r SERVER_NAME
if [[ -z "$SERVER_NAME" ]]; then
  echo "ERROR: server name cannot be empty" >&2
  exit 1
fi

printf 'Agent API key: '
IFS= read -r -s AGENT_API_KEY
echo
if [[ -z "$AGENT_API_KEY" ]]; then
  echo "ERROR: agent API key cannot be empty" >&2
  exit 1
fi

printf 'Report interval seconds [%s]: ' "$REPORT_INTERVAL_SECONDS_DEFAULT"
IFS= read -r interval_input
if [[ -n "$interval_input" ]]; then
  REPORT_INTERVAL_SECONDS="$interval_input"
fi

umask 077
cat >"$ENV_FILE" <<EOF
CENTRAL_API_URL=$CENTRAL_API_URL
SERVER_NAME=$SERVER_NAME
AGENT_API_KEY=$AGENT_API_KEY
REPORT_INTERVAL_SECONDS=$REPORT_INTERVAL_SECONDS
EOF

chmod 600 "$ENV_FILE"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: repo not found at $REPO_DIR" >&2
  echo "Clone it first, e.g.:" >&2
  echo "  git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git $REPO_DIR" >&2
  exit 1
fi

cd "$REPO_DIR"

git fetch --tags origin >/dev/null 2>&1 || true
git checkout -f "$TAG"

echo "Installing dependencies..."
if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
  npm ci
else
  npm install
fi

echo "Building..."
npm run build

# Optional: keep runtime smaller by removing dev deps after building.
npm prune --omit=dev >/dev/null 2>&1 || true

# Create systemd service
cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=CyberPanel Edge Monitoring Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo ""
echo "OK: $SERVICE_NAME is running"
systemctl status "$SERVICE_NAME" --no-pager -l
