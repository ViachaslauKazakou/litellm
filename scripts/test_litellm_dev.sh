#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$DOCKER_MOCK_LOG"

if [[ "${1:-}" == "info" ]]; then
  exit 0
fi

if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
  exit "${DOCKER_MOCK_NETWORK_MISSING:-0}"
fi

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi

if [[ " $* " == *" postgres-check "* ]]; then
  exit "${DOCKER_MOCK_PG_READY:-1}"
fi

exit 0
MOCK
chmod +x "$TMP_DIR/bin/docker"

export DOCKER_MOCK_LOG="$TMP_DIR/docker.log"
export LITELLM_DEV_ENV_FILE="$TMP_DIR/.env.litellm.dev"
export PATH="$TMP_DIR/bin:$PATH"

# A missing shared network blocks startup before the PostgreSQL probe.
export DOCKER_MOCK_NETWORK_MISSING=1
set +e
NETWORK_OUTPUT="$(bash "$ROOT_DIR/scripts/litellm-dev.sh" up 2>&1)"
NETWORK_STATUS=$?
set -e

if [[ "$NETWORK_STATUS" -eq 0 ]]; then
  printf 'FAIL: startup should fail when the shared network is missing.\n' >&2
  exit 1
fi
if [[ "$NETWORK_OUTPUT" != *"Общая Docker-сеть learn-service не найдена"* ]]; then
  printf 'FAIL: expected a clear shared-network warning.\n%s\n' "$NETWORK_OUTPUT" >&2
  exit 1
fi
if grep -q 'postgres-check\|up -d litellm\|litellm-db-init' "$DOCKER_MOCK_LOG"; then
  printf 'FAIL: PostgreSQL check or LiteLLM startup ran without the shared network.\n' >&2
  exit 1
fi
if [[ ! -s "$LITELLM_DEV_ENV_FILE" ]]; then
  printf 'FAIL: expected local env file with generated keys.\n' >&2
  exit 1
fi
printf 'PASS: shared network missing -> warning, no database check or LiteLLM start.\n'

# An unavailable PostgreSQL also blocks startup without creating a new server.
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_NETWORK_MISSING=0
set +e
UNAVAILABLE_OUTPUT="$(bash "$ROOT_DIR/scripts/litellm-dev.sh" up 2>&1)"
UNAVAILABLE_STATUS=$?
set -e

if [[ "$UNAVAILABLE_STATUS" -eq 0 ]]; then
  printf 'FAIL: startup should fail when PostgreSQL is unavailable.\n' >&2
  exit 1
fi
if [[ "$UNAVAILABLE_OUTPUT" != *"PostgreSQL недоступен"* ]]; then
  printf 'FAIL: expected a clear PostgreSQL warning.\n%s\n' "$UNAVAILABLE_OUTPUT" >&2
  exit 1
fi
if grep -q 'up -d litellm\|litellm-db-init' "$DOCKER_MOCK_LOG"; then
  printf 'FAIL: LiteLLM/database initialization ran despite unavailable PostgreSQL.\n' >&2
  exit 1
fi
printf 'PASS: PostgreSQL unavailable -> warning, no database init or LiteLLM start.\n'

# A reachable PostgreSQL permits database initialization followed by LiteLLM.
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_PG_READY=0
bash "$ROOT_DIR/scripts/litellm-dev.sh" up >/dev/null

if ! grep -q 'litellm-db-init' "$DOCKER_MOCK_LOG"; then
  printf 'FAIL: expected database initialization when PostgreSQL is available.\n' >&2
  exit 1
fi
if ! grep -q 'up -d litellm' "$DOCKER_MOCK_LOG"; then
  printf 'FAIL: expected LiteLLM to start when PostgreSQL is available.\n' >&2
  exit 1
fi
printf 'PASS: PostgreSQL available -> database initialized, LiteLLM started.\n'
