#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.litellm-dev.yml"
ENV_FILE="${LITELLM_DEV_ENV_FILE:-$ROOT_DIR/.env.litellm.dev}"
PROJECT_NAME="litellm-local-dev"
ACTION="${1:-up}"

if ! command -v docker >/dev/null 2>&1; then
  printf '❌ Docker не найден. Установите и запустите Docker Desktop.\n' >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  printf '❌ Не найден Docker Compose (docker compose / docker-compose).\n' >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  printf '❌ Docker daemon не запущен. Запустите Docker Desktop и повторите команду.\n' >&2
  exit 1
fi

compose() {
  "${COMPOSE[@]}" \
    --project-name "$PROJECT_NAME" \
    --project-directory "$ROOT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(32))'
  else
    printf '❌ Для генерации ключей нужен openssl или python3.\n' >&2
    return 1
  fi
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi

  local master_key salt_key
  master_key="sk-$(generate_secret)"
  salt_key="sk-$(generate_secret)"

  (umask 077
    cat > "$ENV_FILE" <<EOF
# Локальные параметры отдельного LiteLLM; файл содержит секреты и не коммитится.
LEARN_SERVICE_NETWORK=learn-service_ai_network_dev
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=docker
POSTGRES_PASSWORD=docker
LITELLM_DB_NAME=litellm_standalone_dev
LITELLM_MASTER_KEY=$master_key
LITELLM_SALT_KEY=$salt_key
EOF
  )
  printf '🔐 Создан локальный env-файл: %s (ключи сгенерированы автоматически).\n' "$ENV_FILE"
}

case "$ACTION" in
  up)
    ensure_env_file

    NETWORK_NAME="$(awk -F= '$1 == "LEARN_SERVICE_NETWORK" { print $2; exit }' "$ENV_FILE")"
    NETWORK_NAME="${LEARN_SERVICE_NETWORK:-${NETWORK_NAME:-learn-service_ai_network_dev}}"
    if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
      printf '\n⚠️  Общая Docker-сеть learn-service не найдена: %s\n' "$NETWORK_NAME" >&2
      printf 'Сначала запустите learn-service/PostgreSQL, проверьте имя сети в .env.litellm.dev и повторите запуск.\n' >&2
      exit 1
    fi

    if ! compose --profile tools run --rm --no-deps postgres-check; then
      printf '\n⚠️  PostgreSQL недоступен по параметрам из %s.\n' "$ENV_FILE" >&2
      printf 'LiteLLM не запущен; отдельный PostgreSQL подниматься не будет, чтобы не конфликтовать со старым сервисом.\n' >&2
      printf 'Проверьте POSTGRES_HOST/POSTGRES_PORT и подключение PostgreSQL к общей сети %s.\n' "$NETWORK_NAME" >&2
      exit 1
    fi

    if ! compose run --rm --no-deps litellm-db-init; then
      printf '\n❌ Не удалось подготовить отдельную БД LiteLLM в существующем PostgreSQL.\n' >&2
      printf 'Проверьте POSTGRES_USER/PASSWORD и право CREATEDB у пользователя.\n' >&2
      exit 1
    fi

    compose up -d litellm --remove-orphans
    printf '\n✅ Отдельный LiteLLM запущен: http://localhost:4000/ui\n'
    ;;
  down)
    [[ -f "$ENV_FILE" ]] || { printf 'Локальный env-файл не найден: %s\n' "$ENV_FILE" >&2; exit 1; }
    compose down
    printf '🛑 LiteLLM остановлен. PostgreSQL и его данные не затронуты.\n'
    ;;
  logs)
    [[ -f "$ENV_FILE" ]] || { printf 'Локальный env-файл не найден: %s\n' "$ENV_FILE" >&2; exit 1; }
    compose logs -f litellm
    ;;
  status)
    [[ -f "$ENV_FILE" ]] || { printf 'Локальный env-файл не найден: %s\n' "$ENV_FILE" >&2; exit 1; }
    compose ps
    ;;
  restart)
    [[ -f "$ENV_FILE" ]] || { printf 'Локальный env-файл не найден: %s\n' "$ENV_FILE" >&2; exit 1; }
    compose restart litellm
    ;;
  *)
    printf 'Использование: %s {up|down|logs|status|restart}\n' "$0" >&2
    exit 2
    ;;
esac
