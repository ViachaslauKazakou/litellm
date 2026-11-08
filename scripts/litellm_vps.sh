#!/usr/bin/env bash
# Open an SSH session or follow LiteLLM production logs on the LearnService VPS.
#
# Usage:
#   bash scripts/litellm_vps.sh {ssh|logs}
#
# Connection settings are read from vps_conf/deploy.env and may be overridden
# with exported VPS_HOST, VPS_USER, VPS_SSH_PORT, VPS_SSH_KEY, VPS_REMOTE_DIR.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-$ROOT_DIR/vps_conf/deploy.env}"
ACTION="${1:-}"

case "$ACTION" in
  ssh|logs) ;;
  -h|--help)
    printf 'Usage: bash scripts/litellm_vps.sh {ssh|logs}\n'
    exit 0
    ;;
  *)
    printf '[error] expected action "ssh" or "logs".\n' >&2
    printf 'Usage: bash scripts/litellm_vps.sh {ssh|logs}\n' >&2
    exit 2
    ;;
esac

if [[ -f "$DEPLOY_ENV_FILE" ]]; then
  # Treat the file as a developer-owned shell env file. Exported shell values
  # take precedence over values stored in the file.
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

if [[ -z "$VPS_HOST" ]]; then
  printf '[error] VPS_HOST is required; set it in %s or pass VPS_HOST=... to make.\n' "$DEPLOY_ENV_FILE" >&2
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
if [[ ! "$VPS_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]]; then
  printf '[error] invalid SSH username.\n' >&2
  exit 1
fi
if [[ ! "$VPS_REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ || "$VPS_REMOTE_DIR" == *'..'* ]]; then
  printf '[error] unsafe remote directory: %s\n' "$VPS_REMOTE_DIR" >&2
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

SSH_OPTS=(-p "$VPS_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o ServerAliveInterval=30)
if [[ -n "$VPS_SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$VPS_SSH_KEY")
fi
SSH_TARGET="${VPS_USER}@${VPS_HOST}"

if [[ "$ACTION" == ssh ]]; then
  printf '[ssh] connecting to %s:%s\n' "$SSH_TARGET" "$VPS_SSH_PORT"
  exec ssh "${SSH_OPTS[@]}" "$SSH_TARGET"
fi

printf '[logs] following LiteLLM logs on %s:%s (Ctrl-C to stop following)\n' "$SSH_TARGET" "$VPS_SSH_PORT"
REMOTE_DIR_Q="$(printf '%q' "$VPS_REMOTE_DIR")"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "REMOTE_DIR=${REMOTE_DIR_Q} bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
cd "$REMOTE_DIR"
sudo docker compose \
  --project-name learn-service \
  --file "$REMOTE_DIR/docker-compose.litellm-prod.yml" \
  --env-file "$REMOTE_DIR/.env.litellm.prod" \
  logs --follow litellm
REMOTE_SCRIPT
