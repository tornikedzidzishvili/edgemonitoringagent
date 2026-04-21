#!/usr/bin/env bash
set -euo pipefail

# Edge Monitoring Agent — Docker deploy (Ubuntu/Debian)
# Only touches ONE container named $CONTAINER_NAME and ONE folder under $INSTALL_DIR.
# Does not prune images/volumes and does not affect other containers.

TAG=""
REPO_DIR="/opt/edgemonitoringagent/src"
INSTALL_DIR="/opt/edgemonitoringagent"
ENV_FILE="/opt/edgemonitoringagent/agent.env"
CONTAINER_NAME="edgemonitoringagent"
IMAGE_NAME="edgemonitoringagent"
DOCKER_SOCK="/var/run/docker.sock"

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
  sudo bash scripts/deploy-ubuntu.sh --tag <git-tag> [options]

Required:
  --tag <git-tag>              Git tag to checkout (e.g. v0.2.0)

Options:
  --server-name <name>         Server display name (skip prompt)
  --api-key <key>              Agent API key (skip prompt). Prefer AGENT_API_KEY env var.
  --central-api-url <url>      Central API base URL (default: https://monitoring.edge.ge/api)
  --interval <seconds>         Report interval in seconds (default: 30)
  --repo-dir <path>            Repo directory (default: /opt/edgemonitoringagent/src)
  --env-file <path>            Env file path (default: /opt/edgemonitoringagent/agent.env)
  --container <name>           Container name (default: edgemonitoringagent)
  --non-interactive            Fail instead of prompting if required values missing
  -h, --help                   Show this help

Environment variable alternatives (safer than --api-key on the CLI):
  AGENT_API_KEY, SERVER_NAME, CENTRAL_API_URL, REPORT_INTERVAL_SECONDS

Examples:
  sudo bash scripts/deploy-ubuntu.sh --tag v0.2.0
  sudo AGENT_API_KEY='xxxx' bash scripts/deploy-ubuntu.sh --tag v0.2.0 \\
       --server-name "Spacehost Web" --non-interactive
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
    --container)        CONTAINER_NAME="${2:-}"; shift 2 ;;
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
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }
command -v git    >/dev/null 2>&1 || { echo "ERROR: git not found"    >&2; exit 1; }

install -d -m 700 "$INSTALL_DIR"

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
    printf '%s: ' "$label"
    IFS= read -r -s value
    echo
  else
    printf '%s: ' "$label"
    IFS= read -r value
  fi
  if [[ -z "$value" ]]; then
    echo "ERROR: $label cannot be empty" >&2
    exit 1
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_required 'Server name (e.g. "Spacehost Web")' SERVER_NAME 0
prompt_required 'Agent API key'                        AGENT_API_KEY 1

if [[ ${#AGENT_API_KEY} -lt 16 ]]; then
  echo "ERROR: AGENT_API_KEY must be at least 16 characters" >&2
  exit 1
fi

if [[ ! "$REPORT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --interval must be a positive integer" >&2
  exit 1
fi

if [[ ! -S "$DOCKER_SOCK" ]]; then
  echo "ERROR: Docker socket not found at $DOCKER_SOCK" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: repo not found at $REPO_DIR" >&2
  echo "Clone it first:" >&2
  echo "  git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git $REPO_DIR" >&2
  exit 1
fi

# Write env file with tight perms (root:root 0600)
umask 077
cat >"$ENV_FILE" <<EOF
CENTRAL_API_URL=$CENTRAL_API_URL
SERVER_NAME=$SERVER_NAME
AGENT_API_KEY=$AGENT_API_KEY
REPORT_INTERVAL_SECONDS=$REPORT_INTERVAL_SECONDS
DOCKER_SOCKET_PATH=$DOCKER_SOCK
EOF
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

cd "$REPO_DIR"

# Preserve local changes by refusing a destructive checkout if present
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: $REPO_DIR has local changes; refusing to overwrite. Commit, stash, or clean them first." >&2
  exit 1
fi

git fetch --tags --prune origin >/dev/null
git checkout "$TAG"

IMAGE_TAG="${IMAGE_NAME}:${TAG}"

echo "Building image $IMAGE_TAG ..."
docker build -t "$IMAGE_TAG" .

# Discover the docker group gid on the host so we don't need --privileged or root in-container.
DOCKER_GID="$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo 0)"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges:true \
  --pids-limit 256 \
  --memory 512m \
  --cpus 1.0 \
  --group-add "$DOCKER_GID" \
  -v "$DOCKER_SOCK:$DOCKER_SOCK" \
  "$IMAGE_TAG" >/dev/null

echo
echo "OK: running $CONTAINER_NAME ($IMAGE_TAG)"
docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo
echo "Tail logs:   docker logs -f $CONTAINER_NAME"
echo "Restart:     docker restart $CONTAINER_NAME"
echo "Update:      sudo bash scripts/deploy-ubuntu.sh --tag <new-tag>"
