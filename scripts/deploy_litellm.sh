#!/usr/bin/env bash
# Upload the production LiteLLM config/Compose file and recreate only LiteLLM.
#
# Local usage:
#   bash scripts/deploy_litellm.sh [options]
#   make deploy-prod
#
# Options:
#   --host <host>          VPS host (or VPS_HOST in vps_conf/deploy.env)
#   --user <user>          SSH user (default: root)
#   --port <port>          SSH port (default: 22)
#   --ssh-key <path>       SSH identity file (optional)
#   --remote-dir <path>    LearnService dir (default: /opt/learn-service)
#   --config <path>        LiteLLM production config (default: repo config)
#   --env-file <path>      Generated LiteLLM env (default: vps_conf/.env.litellm.prod)
#   -h, --help             Show this help

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-$ROOT_DIR/vps_conf/deploy.env}"

if [[ -f "$DEPLOY_ENV_FILE" ]]; then
  # This is a developer-owned shell env file, not a YAML/GitHub secret document.
  VPS_HOST_FROM_ENV="${VPS_HOST-}"
  VPS_USER_FROM_ENV="${VPS_USER-}"
  VPS_SSH_PORT_FROM_ENV="${VPS_SSH_PORT-}"
  VPS_SSH_KEY_FROM_ENV="${VPS_SSH_KEY-}"
  VPS_REMOTE_DIR_FROM_ENV="${VPS_REMOTE_DIR-}"
  VPS_HOST_WAS_EXPORTED="${VPS_HOST+x}"
  VPS_USER_WAS_EXPORTED="${VPS_USER+x}"
  VPS_SSH_PORT_WAS_EXPORTED="${VPS_SSH_PORT+x}"
  VPS_SSH_KEY_WAS_EXPORTED="${VPS_SSH_KEY+x}"
  VPS_REMOTE_DIR_WAS_EXPORTED="${VPS_REMOTE_DIR+x}"
  set -a
  # shellcheck disable=SC1090
  source "$DEPLOY_ENV_FILE"
  set +a
  if [[ "$VPS_HOST_WAS_EXPORTED" == x ]]; then VPS_HOST="$VPS_HOST_FROM_ENV"; fi
  if [[ "$VPS_USER_WAS_EXPORTED" == x ]]; then VPS_USER="$VPS_USER_FROM_ENV"; fi
  if [[ "$VPS_SSH_PORT_WAS_EXPORTED" == x ]]; then VPS_SSH_PORT="$VPS_SSH_PORT_FROM_ENV"; fi
  if [[ "$VPS_SSH_KEY_WAS_EXPORTED" == x ]]; then VPS_SSH_KEY="$VPS_SSH_KEY_FROM_ENV"; fi
  if [[ "$VPS_REMOTE_DIR_WAS_EXPORTED" == x ]]; then VPS_REMOTE_DIR="$VPS_REMOTE_DIR_FROM_ENV"; fi
fi

VPS_HOST="${VPS_HOST:-}"
VPS_USER="${VPS_USER:-root}"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_SSH_KEY="${VPS_SSH_KEY:-}"
VPS_REMOTE_DIR="${VPS_REMOTE_DIR:-/opt/learn-service}"
CONFIG_FILE="$ROOT_DIR/litellm-config-prod.yaml"
COMPOSE_SOURCE="$ROOT_DIR/docker-compose.litellm-prod.yml"
LITELLM_ENV_FILE="${LITELLM_ENV_FILE:-$ROOT_DIR/vps_conf/.env.litellm.prod}"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_value() {
  local option="$1"
  if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
    printf '[error] %s requires a value.\n' "$option" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       require_value "$@"; VPS_HOST="$2"; shift 2 ;;
    --user)       require_value "$@"; VPS_USER="$2"; shift 2 ;;
    --port)       require_value "$@"; VPS_SSH_PORT="$2"; shift 2 ;;
    --ssh-key)    require_value "$@"; VPS_SSH_KEY="$2"; shift 2 ;;
    --remote-dir) require_value "$@"; VPS_REMOTE_DIR="$2"; shift 2 ;;
    --config)     require_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
    --env-file)   require_value "$@"; LITELLM_ENV_FILE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf '[error] unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$VPS_HOST" ]]; then
  printf '[error] VPS_HOST is required; set it in %s or pass --host.\n' "$DEPLOY_ENV_FILE" >&2
  exit 1
fi
if [[ ! -r "$CONFIG_FILE" ]]; then
  printf '[error] production config is not readable: %s\n' "$CONFIG_FILE" >&2
  exit 1
fi
if ! ruby -ryaml -e '
  config = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], permitted_symbols: [], aliases: false)
  abort unless config.is_a?(Hash) && config["model_list"].is_a?(Array) && !config["model_list"].empty?
' "$CONFIG_FILE" >/dev/null 2>&1; then
  printf '[error] production LiteLLM config is invalid YAML or has no model_list.\n' >&2
  exit 1
fi
if [[ ! -r "$COMPOSE_SOURCE" ]]; then
  printf '[error] production Compose file is not readable: %s\n' "$COMPOSE_SOURCE" >&2
  exit 1
fi
if [[ ! -r "$LITELLM_ENV_FILE" ]]; then
  printf '[error] generated LiteLLM env file is not readable: %s\n' "$LITELLM_ENV_FILE" >&2
  printf '[error] generate it from LITELLM_CONFIG.yml or pass --env-file.\n' >&2
  exit 1
fi
if [[ ! "$VPS_SSH_PORT" =~ ^[0-9]{1,5}$ ]]; then
  printf '[error] SSH port must be between 1 and 65535.\n' >&2
  exit 1
fi
SSH_PORT_NUMBER=$((10#$VPS_SSH_PORT))
if (( SSH_PORT_NUMBER < 1 || SSH_PORT_NUMBER > 65535 )); then
  printf '[error] SSH port must be between 1 and 65535.\n' >&2
  exit 1
fi
if [[ ! "$VPS_REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ || "$VPS_REMOTE_DIR" == *'..'* ]]; then
  printf '[error] unsafe remote directory: %s\n' "$VPS_REMOTE_DIR" >&2
  exit 1
fi
if [[ ! "$VPS_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]]; then
  printf '[error] invalid SSH username.\n' >&2
  exit 1
fi

if [[ -n "$VPS_SSH_KEY" ]]; then
  VPS_SSH_KEY="${VPS_SSH_KEY/#\~/$HOME}"
elif [[ -f "$HOME/.ssh/id_ed25519" ]]; then
  VPS_SSH_KEY="$HOME/.ssh/id_ed25519"
elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
  VPS_SSH_KEY="$HOME/.ssh/id_rsa"
fi
if [[ -n "$VPS_SSH_KEY" && ! -r "$VPS_SSH_KEY" ]]; then
  printf '[error] SSH key is not readable: %s\n' "$VPS_SSH_KEY" >&2
  exit 1
fi

SSH_OPTS=(-p "$VPS_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o ServerAliveInterval=30)
SCP_OPTS=(-P "$VPS_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30)
if [[ -n "$VPS_SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$VPS_SSH_KEY" -o IdentitiesOnly=yes)
  SCP_OPTS+=(-i "$VPS_SSH_KEY" -o IdentitiesOnly=yes)
fi

SSH_TARGET="${VPS_USER}@${VPS_HOST}"
RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
UPLOAD_NAME="litellm-config-prod-${RELEASE_ID}.yaml"
COMPOSE_UPLOAD_NAME="docker-compose.litellm-prod-${RELEASE_ID}.yml"
ENV_UPLOAD_NAME="litellm-env-${RELEASE_ID}.env"

printf '[deploy] target: %s:%s\n' "$SSH_TARGET" "$VPS_SSH_PORT"
printf '[deploy] remote dir: %s\n' "$VPS_REMOTE_DIR"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true
scp "${SCP_OPTS[@]}" "$CONFIG_FILE" "${SSH_TARGET}:/tmp/${UPLOAD_NAME}"
scp "${SCP_OPTS[@]}" "$COMPOSE_SOURCE" "${SSH_TARGET}:/tmp/${COMPOSE_UPLOAD_NAME}"
scp "${SCP_OPTS[@]}" "$LITELLM_ENV_FILE" "${SSH_TARGET}:/tmp/${ENV_UPLOAD_NAME}"

REMOTE_DIR_Q="$(printf '%q' "$VPS_REMOTE_DIR")"
UPLOAD_NAME_Q="$(printf '%q' "$UPLOAD_NAME")"
COMPOSE_UPLOAD_NAME_Q="$(printf '%q' "$COMPOSE_UPLOAD_NAME")"
ENV_UPLOAD_NAME_Q="$(printf '%q' "$ENV_UPLOAD_NAME")"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "REMOTE_DIR=${REMOTE_DIR_Q} UPLOAD_NAME=${UPLOAD_NAME_Q} COMPOSE_UPLOAD_NAME=${COMPOSE_UPLOAD_NAME_Q} ENV_UPLOAD_NAME=${ENV_UPLOAD_NAME_Q} bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

COMPOSE_FILE="${REMOTE_DIR}/docker-compose.litellm-prod.yml"
ENV_FILE="${REMOTE_DIR}/.env.litellm.prod"
CONFIG_FILE="${REMOTE_DIR}/litellm-config-prod.yaml"
UPLOAD_FILE="/tmp/${UPLOAD_NAME}"
COMPOSE_UPLOAD_FILE="/tmp/${COMPOSE_UPLOAD_NAME}"
ENV_UPLOAD_FILE="/tmp/${ENV_UPLOAD_NAME}"
CONFIG_STAGE="${REMOTE_DIR}/.litellm-config-prod.${UPLOAD_NAME}.new"
CONFIG_BACKUP="${REMOTE_DIR}/.litellm-config-prod.${UPLOAD_NAME}.backup"
COMPOSE_STAGE="${REMOTE_DIR}/.docker-compose.litellm-prod.${COMPOSE_UPLOAD_NAME}.new"
COMPOSE_BACKUP="${REMOTE_DIR}/.docker-compose.litellm-prod.${COMPOSE_UPLOAD_NAME}.backup"
ENV_STAGE="${REMOTE_DIR}/.env.litellm.prod.${ENV_UPLOAD_NAME}.new"
ENV_BACKUP="${REMOTE_DIR}/.env.litellm.prod.${ENV_UPLOAD_NAME}.backup"
ROLLBACK_NEEDED=false
HAD_CONFIG=false
HAD_COMPOSE=false
HAD_ENV=false

compose() {
  cd "$REMOTE_DIR"
  sudo docker compose \
    --project-name learn-service \
    --file "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

finish() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 && "$ROLLBACK_NEEDED" == true ]]; then
    echo "[remote] deploy failed; restoring previous LiteLLM files..." >&2
    if [[ "$HAD_CONFIG" == true ]]; then
      sudo install -m 0644 "$CONFIG_BACKUP" "$CONFIG_FILE" || true
    else
      sudo rm -f "$CONFIG_FILE" || true
    fi
    if [[ "$HAD_COMPOSE" == true ]]; then
      sudo install -m 0644 "$COMPOSE_BACKUP" "$COMPOSE_FILE" || true
    else
      sudo rm -f "$COMPOSE_FILE" || true
    fi
    if [[ "$HAD_ENV" == true ]]; then
      sudo install -m 0600 "$ENV_BACKUP" "$ENV_FILE" || true
    else
      sudo rm -f "$ENV_FILE" || true
    fi
    if [[ "$HAD_CONFIG" == true && "$HAD_COMPOSE" == true && "$HAD_ENV" == true ]]; then
      compose up -d --no-deps --force-recreate litellm || true
      compose logs --tail 80 litellm || true
    else
      # A first-deploy failure has nothing safe to roll back to. Remove only
      # the failed proxy container; never stop the shared PostgreSQL container.
      sudo docker rm -f learn_litellm_prod || true
    fi
  fi
  sudo rm -f "$UPLOAD_FILE" "$COMPOSE_UPLOAD_FILE" "$ENV_UPLOAD_FILE" \
    "$CONFIG_STAGE" "$CONFIG_BACKUP" "$COMPOSE_STAGE" "$COMPOSE_BACKUP" \
    "$ENV_STAGE" "$ENV_BACKUP" || true
  exit "$exit_code"
}
trap finish EXIT

if [[ ! -d "$REMOTE_DIR" || "$REMOTE_DIR" == / || "$REMOTE_DIR" == /opt ]]; then
  echo "[error] unsafe or missing deployment directory: $REMOTE_DIR" >&2
  exit 1
fi
if [[ ! -s "$UPLOAD_FILE" ]]; then
  echo "[error] uploaded production config is missing or empty" >&2
  exit 1
fi
if [[ ! -s "$COMPOSE_UPLOAD_FILE" ]]; then
  echo "[error] uploaded LiteLLM Compose file is missing or empty" >&2
  exit 1
fi
if [[ ! -s "$ENV_UPLOAD_FILE" ]]; then
  echo "[error] uploaded LiteLLM env file is missing or empty" >&2
  exit 1
fi

if sudo test -f "$CONFIG_FILE"; then
  HAD_CONFIG=true
  sudo cp -p "$CONFIG_FILE" "$CONFIG_BACKUP"
fi
if sudo test -f "$COMPOSE_FILE"; then
  HAD_COMPOSE=true
  sudo cp -p "$COMPOSE_FILE" "$COMPOSE_BACKUP"
fi
if sudo test -f "$ENV_FILE"; then
  HAD_ENV=true
  sudo cp -p "$ENV_FILE" "$ENV_BACKUP"
fi

ROLLBACK_NEEDED=true
sudo install -m 0644 "$UPLOAD_FILE" "$CONFIG_STAGE"
sudo mv -f "$CONFIG_STAGE" "$CONFIG_FILE"
sudo install -m 0644 "$COMPOSE_UPLOAD_FILE" "$COMPOSE_STAGE"
sudo mv -f "$COMPOSE_STAGE" "$COMPOSE_FILE"
sudo install -m 0600 "$ENV_UPLOAD_FILE" "$ENV_STAGE"
sudo mv -f "$ENV_STAGE" "$ENV_FILE"

echo "[remote] validating Compose and starting only LiteLLM..."
compose config >/dev/null
compose up -d --force-recreate litellm

CONTAINER_ID="$(compose ps --quiet litellm | head -n 1)"
if [[ -z "$CONTAINER_ID" ]]; then
  echo "[error] Compose did not return a LiteLLM container ID" >&2
  exit 1
fi

HEALTHY=false
for attempt in $(seq 1 40); do
  STATUS="$(sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_ID" 2>/dev/null || true)"
  echo "[remote] health check ${attempt}/40: ${STATUS:-missing}"
  if [[ "$STATUS" == healthy ]]; then
    HEALTHY=true
    break
  fi
  if [[ "$STATUS" == exited || "$STATUS" == dead || "$STATUS" == unhealthy ]]; then
    break
  fi
  sleep 15
done

if [[ "$HEALTHY" != true ]]; then
  sudo docker logs --tail 100 "$CONTAINER_ID" 2>&1 || true
  echo "[error] LiteLLM did not become healthy; rolling back" >&2
  exit 1
fi

ROLLBACK_NEEDED=false
echo "[remote] LiteLLM is healthy; deployment succeeded."
REMOTE_SCRIPT

printf '[deploy] ✅ LiteLLM production config deployed successfully.\n'
