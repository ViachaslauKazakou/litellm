#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_SSH_LOG"
if [[ "${MOCK_CAPTURE_STDIN:-0}" == 1 ]]; then
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$MOCK_SSH_SCRIPT"
  done
fi
MOCK
chmod +x "$TMP_DIR/bin/ssh"

export PATH="$TMP_DIR/bin:$PATH"
export MOCK_SSH_LOG="$TMP_DIR/ssh.log"
export MOCK_SSH_SCRIPT="$TMP_DIR/remote-script.sh"
export DEPLOY_ENV_FILE=/dev/null

if VPS_HOST=mock.invalid VPS_SSH_PORT=0 bash "$ROOT_DIR/scripts/litellm_vps.sh" ssh >/dev/null 2>&1; then
  printf 'FAIL: invalid SSH port was accepted.\n' >&2
  exit 1
fi
printf 'PASS: invalid SSH port is rejected before connecting.\n'

# The environment takes precedence over values loaded from the local deploy file.
cat > "$TMP_DIR/deploy.env" <<'ENV'
VPS_HOST=file.example
VPS_USER=file-user
VPS_SSH_PORT=22
VPS_REMOTE_DIR=/opt/learn-service
ENV
DEPLOY_ENV_FILE="$TMP_DIR/deploy.env" \
VPS_HOST=override.example \
VPS_USER=override-user \
VPS_SSH_PORT=2222 \
  bash "$ROOT_DIR/scripts/litellm_vps.sh" ssh >/dev/null

if ! grep -Fq -- '-p 2222' "$MOCK_SSH_LOG" || ! grep -Fq 'override-user@override.example' "$MOCK_SSH_LOG"; then
  printf 'FAIL: SSH target/options do not use the environment overrides.\n' >&2
  exit 1
fi
printf 'PASS: SSH command reads deploy settings and honors environment overrides.\n'

: > "$MOCK_SSH_LOG"
: > "$MOCK_SSH_SCRIPT"
MOCK_CAPTURE_STDIN=1 \
DEPLOY_ENV_FILE=/dev/null \
VPS_HOST=mock.invalid \
VPS_USER=tester \
VPS_SSH_PORT=2200 \
VPS_REMOTE_DIR=/opt/learn-service \
  bash "$ROOT_DIR/scripts/litellm_vps.sh" logs >/dev/null

if ! grep -Fq 'tester@mock.invalid' "$MOCK_SSH_LOG" \
  || ! grep -Fq 'logs --follow litellm' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq 'docker-compose.litellm-prod.yml' "$MOCK_SSH_SCRIPT" \
  || grep -Fq 'docker-compose.vps.prod.yml' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq -- '--env-file "$REMOTE_DIR/.env.litellm.prod"' "$MOCK_SSH_SCRIPT"; then
  printf 'FAIL: remote log command does not target the LearnService LiteLLM service.\n' >&2
  exit 1
fi
printf 'PASS: log command follows LiteLLM using dedicated Compose/runtime env.\n'
