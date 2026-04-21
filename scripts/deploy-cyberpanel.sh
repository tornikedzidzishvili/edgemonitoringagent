#!/usr/bin/env bash
set -euo pipefail

# Edge Monitoring Agent — native systemd deploy (no Docker)
# Used on CyberPanel / non-Docker hosts. Creates a dedicated non-login user,
# installs Node.js 22, builds from source, and runs under a hardened systemd unit.

TAG=""
AGENT_USER="edgeagent"
INSTALL_DIR="/opt/edgemonitoringagent"
REPO_DIR="/opt/edgemonitoringagent/src"
ENV_FILE="/opt/edgemonitoringagent/agent.env"
SERVICE_NAME="edgemonitoringagent"
NODE_MAJOR="22"

CENTRAL_API_URL_DEFAULT="https://monitoring.edge.ge/api"
REPORT_INTERVAL_SECONDS_DEFAULT="30"

SERVER_NAME_ARG=""
AGENT_API_KEY_ARG=""
CENTRAL_API_URL_ARG=""
REPORT_INTERVAL_ARG=""
NON_INTERACTIVE="0"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/deploy-cyberpanel.sh --tag <git-tag> [options]

Required:
  --tag <git-tag>              Git tag to checkout (e.g. v0.2.0)

Options:
  --server-name <name>         Server display name (skip prompt)
  --api-key <key>              Agent API key (skip prompt). Prefer AGENT_API_KEY env var.
  --central-api-url <url>      Central API base URL (default: https://monitoring.edge.ge/api)
  --interval <seconds>         Report interval in seconds (default: 30)
  --repo-dir <path>            Repo directory (default: /opt/edgemonitoringagent/src)
  --env-file <path>            Env file path (default: /opt/edgemonitoringagent/agent.env)
  --service <name>             systemd service name (default: edgemonitoringagent)
  --non-interactive            Fail instead of prompting if required values missing
  -h, --help                   Show this help

Environment variable alternatives:
  AGENT_API_KEY, SERVER_NAME, CENTRAL_API_URL, REPORT_INTERVAL_SECONDS
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              TAG="${2:-}"; shift 2 ;;
    --server-name)      SERVER_NAME_ARG="${2:-}"; shift 2 ;;
    --api-key)          AGENT_API_KEY_ARG="${2:-}"; shift 2 ;;
    --central-api-url)  CENTRAL_API_URL_ARG="${2:-}"; shift 2 ;;
    --interval)         REPORT_INTERVAL_ARG="${2:-}"; shift 2 ;;
    --repo-dir)         REPO_DIR="${2:-}"; shift 2 ;;
    --env-file)         ENV_FILE="${2:-}"; shift 2 ;;
    --service)          SERVICE_NAME="${2:-}"; shift 2 ;;
    --non-interactive)  NON_INTERACTIVE="1"; shift 1 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "ERROR: --tag is required (example: --tag v0.2.0)" >&2
  exit 2
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: please run as root (use sudo)" >&2
  exit 1
fi

# Install Node.js NODE_MAJOR if missing or too old
install_nodejs() {
  if command -v node >/dev/null 2>&1; then
    local current
    current="$(node -v | sed 's/^v//' | cut -d. -f1)"
    if [[ "$current" -ge "$NODE_MAJOR" ]]; then
      echo "Node.js $(node -v) already installed"
      return 0
    fi
  fi

  echo "Installing Node.js ${NODE_MAJOR}.x ..."
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  curl --fail --silent --show-error --location \
       --max-time 120 \
       "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$tmp"
  bash "$tmp"
  apt-get install -y nodejs
  echo "Node.js $(node -v) installed"
}

install_nodejs

# Create dedicated non-login system user if missing
if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$AGENT_USER"
fi

install -d -m 755 "$INSTALL_DIR"

SERVER_NAME="${SERVER_NAME_ARG:-${SERVER_NAME:-}}"
AGENT_API_KEY="${AGENT_API_KEY_ARG:-${AGENT_API_KEY:-}}"
CENTRAL_API_URL="${CENTRAL_API_URL_ARG:-${CENTRAL_API_URL:-$CENTRAL_API_URL_DEFAULT}}"
REPORT_INTERVAL_SECONDS="${REPORT_INTERVAL_ARG:-${REPORT_INTERVAL_SECONDS:-$REPORT_INTERVAL_SECONDS_DEFAULT}}"

prompt_required() {
  local label="$1" var_name="$2" secret="${3:-0}"
  if [[ -n "${!var_name}" ]]; then return 0; fi
  if [[ "$NON_INTERACTIVE" == "1" ]]; then
    echo "ERROR: $var_name is required (set via flag or $var_name env var)" >&2
    exit 1
  fi
  if [[ "$secret" == "1" ]]; then
    printf '%s: ' "$label"; IFS= read -r -s value; echo
  else
    printf '%s: ' "$label"; IFS= read -r value
  fi
  if [[ -z "$value" ]]; then
    echo "ERROR: $label cannot be empty" >&2
    exit 1
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_required 'Server name (e.g. "CyberPanel SSH")' SERVER_NAME 0
prompt_required 'Agent API key'                        AGENT_API_KEY 1

if [[ ${#AGENT_API_KEY} -lt 16 ]]; then
  echo "ERROR: AGENT_API_KEY must be at least 16 characters" >&2
  exit 1
fi
if [[ ! "$REPORT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --interval must be a positive integer" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: repo not found at $REPO_DIR" >&2
  echo "Clone it first:" >&2
  echo "  git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git $REPO_DIR" >&2
  exit 1
fi

cd "$REPO_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: $REPO_DIR has local changes; refusing to overwrite." >&2
  exit 1
fi

git fetch --tags --prune origin >/dev/null
git checkout "$TAG"

echo "Installing dependencies ..."
if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
  npm ci
else
  npm install
fi

echo "Building ..."
npm run build

# Shrink runtime to production deps only
npm prune --omit=dev >/dev/null 2>&1 || true

# Make the built agent readable by the service user without granting write perms
chown -R root:"$AGENT_USER" "$REPO_DIR"
find "$REPO_DIR" -type d -exec chmod 750 {} +
find "$REPO_DIR" -type f -exec chmod 640 {} +

# Write env file as root:agent 0640 so only root can edit, service can read
umask 027
cat >"$ENV_FILE" <<EOF
CENTRAL_API_URL=$CENTRAL_API_URL
SERVER_NAME=$SERVER_NAME
AGENT_API_KEY=$AGENT_API_KEY
REPORT_INTERVAL_SECONDS=$REPORT_INTERVAL_SECONDS
AGENT_HEARTBEAT_PATH=/run/$SERVICE_NAME/heartbeat
EOF
chown root:"$AGENT_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"

NODE_BIN="$(command -v node)"

# Hardened systemd unit — see systemd.exec(5) & systemd.service(5)
cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Edge Monitoring Agent
Documentation=https://github.com/tornikedzidzishvili/edgemonitoringagent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$AGENT_USER
Group=$AGENT_USER
WorkingDirectory=$REPO_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$NODE_BIN --enable-source-maps $REPO_DIR/dist/index.js
Restart=always
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=10

# Runtime / logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME
RuntimeDirectory=$SERVICE_NAME
RuntimeDirectoryMode=0750

# Resource limits
LimitNOFILE=4096
MemoryMax=512M
TasksMax=256

# --- Security hardening ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
PrivateTmp=true
PrivateDevices=true
PrivateMounts=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
RemoveIPC=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
IPAddressDeny=
UMask=0077
# The agent needs to write its heartbeat file only.
ReadWritePaths=/run/$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"

echo
echo "OK: $SERVICE_NAME is running"
systemctl status "$SERVICE_NAME" --no-pager -l || true
echo
echo "Tail logs:   journalctl -u $SERVICE_NAME -f"
echo "Restart:     systemctl restart $SERVICE_NAME"
echo "Update:      sudo bash scripts/deploy-cyberpanel.sh --tag <new-tag>"
