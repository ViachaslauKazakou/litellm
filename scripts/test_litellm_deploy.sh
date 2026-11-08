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
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$MOCK_SSH_SCRIPT"
done
MOCK
cat > "$TMP_DIR/bin/scp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_SCP_LOG"
MOCK
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/scp"

export PATH="$TMP_DIR/bin:$PATH"
export MOCK_SSH_LOG="$TMP_DIR/ssh.log"
export MOCK_SSH_SCRIPT="$TMP_DIR/remote-script.sh"
export MOCK_SCP_LOG="$TMP_DIR/scp.log"
export DEPLOY_ENV_FILE=/dev/null
touch "$TMP_DIR/deploy-key"

cat > "$TMP_DIR/litellm-config.yml" <<'CONFIG'
VPS_HOST: deploy.example
SSH_USER: deploy
SECRET_KEY: must-not-be-forwarded
LITELLM_MASTER_KEY: "sk-test$master"
POSTGRES_USER: learn_user
POSTGRES_PASSWORD: "p@ss:'#$dollar"
OPENAI_API_KEY: openai-test
ANTHROPIC_API_KEY: anthropic-test
DEEPSEEK_API_KEY: deepseek-test
DASHSCOPE_API_KEY: dashscope-test
CONFIG
RUNTIME_ENV_FILE="$TMP_DIR/.env.litellm.prod"
GITHUB_OUTPUT_FILE="$TMP_DIR/github-output"
ruby "$ROOT_DIR/scripts/generate_litellm_env.rb" \
  --input "$TMP_DIR/litellm-config.yml" \
  --output "$RUNTIME_ENV_FILE" \
  --github-output "$GITHUB_OUTPUT_FILE" >/dev/null

if ! grep -Fq "LITELLM_MASTER_KEY='sk-test\$master'" "$RUNTIME_ENV_FILE" \
  || ! grep -Fq "LITELLM_DATABASE_URL='postgresql://learn_user:p%40ss%3A%27%23%24dollar@postgres:5432/litellm'" "$RUNTIME_ENV_FILE" \
  || grep -Fq 'SECRET_KEY' "$RUNTIME_ENV_FILE" \
  || grep -Fq 'sk-test' "$GITHUB_OUTPUT_FILE" \
  || ! grep -Fq 'vps_host=deploy.example' "$GITHUB_OUTPUT_FILE" \
  || [[ "$(ruby -e 'print File.stat(ARGV[0]).mode & 0777' "$RUNTIME_ENV_FILE")" != 384 ]]; then
  printf 'FAIL: generated env is not restricted, masked, or mode 0600.\n' >&2
  exit 1
fi
printf 'PASS: LITELLM_CONFIG generates restricted env and non-secret connection outputs.\n'

cat > "$TMP_DIR/non-string-secret.yml" <<'CONFIG'
VPS_HOST: deploy.example
LITELLM_MASTER_KEY: yes
POSTGRES_USER: learn_user
POSTGRES_PASSWORD: valid-password
OPENAI_API_KEY: openai-test
ANTHROPIC_API_KEY: anthropic-test
DEEPSEEK_API_KEY: deepseek-test
DASHSCOPE_API_KEY: dashscope-test
CONFIG
if ruby "$ROOT_DIR/scripts/generate_litellm_env.rb" \
  --input "$TMP_DIR/non-string-secret.yml" \
  --output "$TMP_DIR/invalid.env" >/dev/null 2>&1; then
  printf 'FAIL: a YAML boolean was silently accepted as a secret.\n' >&2
  exit 1
fi

cat > "$TMP_DIR/trailing-backslash.yml" <<'CONFIG'
VPS_HOST: deploy.example
LITELLM_MASTER_KEY: sk-test-master
POSTGRES_USER: learn_user
POSTGRES_PASSWORD: "ends\\"
OPENAI_API_KEY: openai-test
ANTHROPIC_API_KEY: anthropic-test
DEEPSEEK_API_KEY: deepseek-test
DASHSCOPE_API_KEY: dashscope-test
CONFIG
if ruby "$ROOT_DIR/scripts/generate_litellm_env.rb" \
  --input "$TMP_DIR/trailing-backslash.yml" \
  --output "$TMP_DIR/invalid.env" >/dev/null 2>&1; then
  printf 'FAIL: a secret ending with a backslash was silently changed.\n' >&2
  exit 1
fi
printf 'PASS: ambiguous YAML secrets are rejected instead of modified.\n'

cat > "$TMP_DIR/compose.yml" <<'COMPOSE'
services:
  test:
    image: python:3.12-bookworm
    env_file:
      - .env.litellm.prod
    environment:
      DATABASE_URL: "${LITELLM_DATABASE_URL:?missing}"
COMPOSE
docker compose --project-name litellm-env-test \
  --file "$TMP_DIR/compose.yml" \
  --env-file "$RUNTIME_ENV_FILE" \
  config --format json > "$TMP_DIR/compose-config.json"
ruby -rjson - "$TMP_DIR/compose-config.json" <<'RUBY'
  env = JSON.parse(File.read(ARGV.fetch(0))).fetch("services").fetch("test").fetch("environment")
  abort "database URL was not encoded" unless env["DATABASE_URL"] == "postgresql://learn_user:p%40ss%3A%27%23%24dollar@postgres:5432/litellm"
  abort "non-LiteLLM secret leaked into env" if env.key?("SECRET_KEY")
RUBY
docker compose --project-name litellm-env-test \
  --file "$TMP_DIR/compose.yml" \
  --env-file "$RUNTIME_ENV_FILE" \
  run --rm --no-deps --entrypoint python test -c \
  'import os; assert os.environ["LITELLM_MASTER_KEY"] == "sk-test$master"; assert os.environ["POSTGRES_PASSWORD"] == "p@ss:" + chr(39) + "#$dollar"'
cp "$ROOT_DIR/docker-compose.litellm-prod.yml" "$TMP_DIR/docker-compose.litellm-prod.yml"
docker compose --project-name litellm-prod-config-test \
  --file "$TMP_DIR/docker-compose.litellm-prod.yml" \
  --env-file "$RUNTIME_ENV_FILE" \
  config --quiet
docker compose --project-name litellm-env-test \
  --file "$TMP_DIR/compose.yml" \
  --env-file "$RUNTIME_ENV_FILE" \
  down --remove-orphans >/dev/null
printf 'PASS: Docker Compose preserves special characters and gets the generated DB URL.\n'

if VPS_HOST=mock.invalid VPS_SSH_PORT=65536 \
  bash "$ROOT_DIR/scripts/deploy_litellm.sh" --ssh-key "$TMP_DIR/deploy-key" \
  >/dev/null 2>&1; then
  printf 'FAIL: invalid SSH port was accepted.\n' >&2
  exit 1
fi
if [[ -s "$MOCK_SSH_LOG" || -s "$MOCK_SCP_LOG" ]]; then
  printf 'FAIL: an invalid SSH port reached ssh/scp.\n' >&2
  exit 1
fi
printf 'PASS: invalid SSH port is rejected before connecting.\n'

printf 'model_list: [\n' > "$TMP_DIR/invalid-litellm-config.yaml"
if bash "$ROOT_DIR/scripts/deploy_litellm.sh" \
  --host mock.invalid --user deploy --port 22 \
  --ssh-key "$TMP_DIR/deploy-key" \
  --config "$TMP_DIR/invalid-litellm-config.yaml" \
  --env-file "$RUNTIME_ENV_FILE" >/dev/null 2>&1; then
  printf 'FAIL: malformed LiteLLM YAML was accepted.\n' >&2
  exit 1
fi
if [[ -s "$MOCK_SSH_LOG" || -s "$MOCK_SCP_LOG" ]]; then
  printf 'FAIL: malformed LiteLLM YAML reached ssh/scp.\n' >&2
  exit 1
fi
printf 'PASS: malformed LiteLLM YAML is rejected before SSH/SCP.\n'

: > "$MOCK_SSH_LOG"
: > "$MOCK_SSH_SCRIPT"
: > "$MOCK_SCP_LOG"
bash "$ROOT_DIR/scripts/deploy_litellm.sh" \
  --host mock.invalid \
  --user deploy \
  --port 22 \
  --ssh-key "$TMP_DIR/deploy-key" \
  --remote-dir /opt/learn-service \
  --env-file "$RUNTIME_ENV_FILE" >/dev/null

if [[ "$(wc -l < "$MOCK_SCP_LOG" | tr -d ' ')" != 3 ]] \
  || ! grep -Fq "$ROOT_DIR/litellm-config-prod.yaml" "$MOCK_SCP_LOG" \
  || ! grep -Fq "$ROOT_DIR/docker-compose.litellm-prod.yml" "$MOCK_SCP_LOG" \
  || ! grep -Fq "$RUNTIME_ENV_FILE" "$MOCK_SCP_LOG"; then
  printf 'FAIL: deploy did not upload config, Compose, and generated runtime env.\n' >&2
  exit 1
fi
if ! grep -Fq 'compose config >/dev/null' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq 'compose up -d --force-recreate litellm' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq 'restoring previous LiteLLM files' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq '.env.litellm.prod' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq 'install -m 0600' "$MOCK_SSH_SCRIPT" \
  || ! grep -Fq 'sudo docker rm -f learn_litellm_prod' "$MOCK_SSH_SCRIPT" \
  || grep -Fq 'docker-compose.vps.prod.yml' "$MOCK_SSH_SCRIPT"; then
  printf 'FAIL: remote deploy is not validated, scoped, and rollback-capable.\n' >&2
  exit 1
fi
bash -n "$MOCK_SSH_SCRIPT"
printf 'PASS: deploy uploads config+Compose+env and scopes update to LiteLLM.\n'

: > "$MOCK_SSH_LOG"
: > "$MOCK_SSH_SCRIPT"
: > "$MOCK_SCP_LOG"
make -C "$ROOT_DIR" vps-deploy \
  LITELLM_CONFIG_FILE="$TMP_DIR/litellm-config.yml" \
  LITELLM_ENV_FILE="$TMP_DIR/.env.litellm.prod" \
  VPS_SSH_KEY="$TMP_DIR/deploy-key" \
  VPS_PORT=2222 \
  VPS_REMOTE_DIR=/opt/learn-service >/dev/null

if [[ "$(wc -l < "$MOCK_SCP_LOG" | tr -d ' ')" != 3 ]] \
  || ! grep -Fq 'deploy@deploy.example' "$MOCK_SSH_LOG" \
  || ! grep -Fq -- '-p 2222' "$MOCK_SSH_LOG" \
  || ! grep -Fq "$TMP_DIR/.env.litellm.prod" "$MOCK_SCP_LOG" \
  || [[ "$(ruby -e 'print File.stat(ARGV[0]).mode & 0777' "$TMP_DIR/.env.litellm.prod")" != 384 ]]; then
  printf 'FAIL: make vps-deploy did not generate a private env and deploy to YAML host/user.\n' >&2
  exit 1
fi
printf 'PASS: make vps-deploy generates env and deploys to YAML host/user.\n'

COMPOSE_FILE="$ROOT_DIR/docker-compose.litellm-prod.yml"
if ! grep -Fq 'PGHOST: postgres' "$COMPOSE_FILE" \
  || ! grep -Fq 'name: learn_service_prod_network' "$COMPOSE_FILE" \
  || ! grep -Fq 'external: true' "$COMPOSE_FILE" \
  || ! grep -Fq '.env.litellm.prod' "$COMPOSE_FILE" \
  || ! grep -Fq 'LITELLM_DATABASE_URL' "$COMPOSE_FILE" \
  || ! grep -Fq '\gexec' "$COMPOSE_FILE" \
  || grep -Eq '^  postgres:' "$COMPOSE_FILE"; then
  printf 'FAIL: production Compose must use the shared network and PostgreSQL.\n' >&2
  exit 1
fi
printf 'PASS: production Compose uses existing network/Postgres, not a new DB.\n'
