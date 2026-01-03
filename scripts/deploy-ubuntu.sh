#!/usr/bin/env bash
set -euo pipefail

TAG=""
REPO_DIR="/opt/edgemonitoringagent/src"
INSTALL_DIR="/opt/edgemonitoringagent"
ENV_FILE="/opt/edgemonitoringagent/agent.env"
CONTAINER_NAME="edgemonitoringagent"
IMAGE_NAME="edgemonitoringagent"
DOCKER_SOCK="/var/run/docker.sock"

CENTRAL_API_URL="https://monitoring.edge.ge/api"
REPORT_INTERVAL_SECONDS_DEFAULT="30"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/deploy-ubuntu.sh --tag <git-tag>

Options:
  --tag <git-tag>          Git tag to checkout (recommended), e.g. v0.1.1
  --repo-dir <path>        Repo directory (default: /opt/edgemonitoringagent/src)
  --env-file <path>        Env file path to write (default: /opt/edgemonitoringagent/agent.env)
  --container <name>       Container name (default: edgemonitoringagent)

Behavior:
  - Builds the Docker image from the repo
  - Recreates ONLY the agent container (no prune, no changes to other containers)
  - Requires Docker; prompts for SERVER_NAME + AGENT_API_KEY and writes the env file
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
    --container)
      CONTAINER_NAME="${2:-}"; shift 2 ;;
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

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }

install -d -m 700 "$INSTALL_DIR"

SERVER_NAME=""
AGENT_API_KEY=""
REPORT_INTERVAL_SECONDS="$REPORT_INTERVAL_SECONDS_DEFAULT"

printf 'Server name (e.g. "Spacehost Web"): '
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
DOCKER_SOCKET_PATH=$DOCKER_SOCK
EOF

chmod 600 "$ENV_FILE" || true

if [[ ! -S "$DOCKER_SOCK" ]]; then
  echo "ERROR: Docker socket not found at $DOCKER_SOCK" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: repo not found at $REPO_DIR" >&2
  echo "Clone it first, e.g.:" >&2
  echo "  git clone https://github.com/tornikedzidzishvili/edgemonitoringagent.git $REPO_DIR" >&2
  exit 1
fi

cd "$REPO_DIR"

git fetch --tags origin >/dev/null 2>&1 || true

git checkout -f "$TAG"

IMAGE_TAG="${IMAGE_NAME}:${TAG}"

docker build -t "$IMAGE_TAG" .

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -v "$DOCKER_SOCK:$DOCKER_SOCK" \
  "$IMAGE_TAG" >/dev/null

echo "OK: running $CONTAINER_NAME ($IMAGE_TAG)"
docker ps --filter "name=$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
