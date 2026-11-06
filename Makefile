.DEFAULT_GOAL := help
.PHONY: help litellm-dev-up litellm-dev-down litellm-dev-logs litellm-dev-status litellm-dev-restart litellm-dev-import-env litellm-dev-sync-app-key deploy-prod vps-ssh vps-logs vps-logs-litellm

LEARN_SERVICE_DIR ?= $(HOME)/Work/learn-service

help: ## Показать команды локального LiteLLM
	@printf 'Локальный LiteLLM (PostgreSQL должен быть уже запущен):\n'
	@printf '  make litellm-dev-up      Запустить на http://localhost:4000/ui\n'
	@printf '  make litellm-dev-status  Показать состояние контейнера\n'
	@printf '  make litellm-dev-logs    Смотреть логи\n'
	@printf '  make litellm-dev-restart Перечитать конфиг и перезапустить\n'
	@printf '  make litellm-dev-import-env  Перенести provider keys из старого litellm_dev\n'
	@printf '  make litellm-dev-sync-app-key  Синхронизировать master key с LearnService\n'
	@printf '  make litellm-dev-down    Остановить LiteLLM, не трогая PostgreSQL\n'
	@printf '  make deploy-prod         Развернуть production-конфиг LiteLLM на VPS\n'
	@printf '  make vps-ssh             Подключиться к VPS по SSH\n'
	@printf '  make vps-logs-litellm    Смотреть production-логи LiteLLM на VPS\n'

litellm-dev-up: ## Запустить отдельный локальный LiteLLM (порт 4000, имя litellm)
	@bash scripts/litellm-dev.sh up

litellm-dev-down: ## Остановить LiteLLM, не затрагивая PostgreSQL
	@bash scripts/litellm-dev.sh down

litellm-dev-logs: ## Смотреть логи LiteLLM
	@bash scripts/litellm-dev.sh logs

litellm-dev-status: ## Показать состояние LiteLLM
	@bash scripts/litellm-dev.sh status

restart: ## Перечитать config и перезапустить LiteLLM
	@bash scripts/litellm-dev.sh restart

litellm-dev-import-env: ## Импортировать нужные provider keys из текущего learn-service LiteLLM
	@python3 scripts/import_litellm_env.py

litellm-dev-sync-app-key: ## Синхронизировать master key в LearnService и пересоздать app/worker
	@python3 scripts/sync_learnservice_key.py "$(LEARN_SERVICE_DIR)"

deploy-prod: ## Развернуть production-конфиг LiteLLM через SSH на VPS
	@bash scripts/deploy_litellm.sh

ps: ## 📋 Список контейнеров с базовой информацией
	@echo "📋 Запущенные контейнеры:"
	@echo ""
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# 	docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}\t{{.Networks}}\t{{.Status}}"

# =====================================================
# 🖥️  VPS DEPLOYMENT (FastVPS / any Linux server)
# Конфигурация: vps_conf/
# Скрипты: vps_conf/scripts/deploy_vps_ssh.sh
# Docker Compose: docker-compose.vps.prod.yml
# =====================================================

VPS_DIR           := vps_conf
VPS_DEPLOY_SH     := $(VPS_DIR)/scripts/deploy_vps_ssh.sh
VPS_HEALTH_SH     := $(VPS_DIR)/scripts/check_health.sh
VPS_COMPOSE_FILE  := docker-compose.vps.prod.yml
VPS_REMOTE_DIR    := /opt/learn-service
VPS_ENV_GENERATOR := $(VPS_DIR)/scripts/generate_env.sh
VPS_ENV_TEMPLATE  ?= $(VPS_DIR)/.env.prod.example
VPS_SECRETS_FILE  ?= $(VPS_DIR)/VPS_SECRETS.yml

# Обязательный параметр: IP или hostname сервера
VPS_HOST          ?= 159.253.22.116
# Опциональные
VPS_USER          ?= root
VPS_PORT          ?= 22
VPS_SSH_KEY       ?= $(HOME)/.ssh/id_ed25519
VPS_DOMAIN        ?= learnservice.online
VPS_LE_EMAIL      ?= admin@learnservice.online
VPS_ENV_FILE      ?= $(VPS_DIR)/.env.prod

# Внутренний хелпер: проверить что VPS_HOST задан
_vps-require-host:
	@if [ -z "$(VPS_HOST)" ]; then \
		echo "$(RED)❌ Укажите IP сервера: make <target> VPS_HOST=159.253.22.116$(NC)"; \
		exit 1; \
	fi

# Внутренний хелпер: строка SSH opts для прямых команд
_VPS_SSH := ssh -p $(VPS_PORT) -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 $(if $(wildcard $(VPS_SSH_KEY)),-i $(VPS_SSH_KEY)) $(VPS_USER)@$(VPS_HOST)

vps-deploy: _vps-require-host generate_env ## 🚀 VPS: деплой на сервер (build app+worker, reload nginx, skip shared)
	@test -f $(VPS_ENV_FILE) || { echo "$(RED)❌ env файл не найден: $(VPS_ENV_FILE)$(NC)"; echo "запустите make generate_env"; exit 1; }
	bash $(VPS_DEPLOY_SH) \
		--host $(VPS_HOST) \
		--user $(VPS_USER) \
		--port $(VPS_PORT) \
		$(if $(wildcard $(VPS_SSH_KEY)),--ssh-key $(VPS_SSH_KEY)) \
		--env-file $(VPS_ENV_FILE) \
		$(if $(VPS_DOMAIN),--domain $(VPS_DOMAIN)) \
		$(if $(VPS_LE_EMAIL),--email $(VPS_LE_EMAIL))

vps-deploy-with-migrations: _vps-require-host generate_env ## 🚀 VPS: деплой + миграции БД
	@test -f $(VPS_ENV_FILE) || { echo "$(RED)❌ env файл не найден: $(VPS_ENV_FILE)$(NC)"; echo "запустите make generate_env"; exit 1; }
	bash $(VPS_DEPLOY_SH) \
		--host $(VPS_HOST) \
		--user $(VPS_USER) \
		--port $(VPS_PORT) \
		$(if $(wildcard $(VPS_SSH_KEY)),--ssh-key $(VPS_SSH_KEY)) \
		--env-file $(VPS_ENV_FILE) \
		$(if $(VPS_DOMAIN),--domain $(VPS_DOMAIN)) \
		$(if $(VPS_LE_EMAIL),--email $(VPS_LE_EMAIL)) \
		--run-migrations

vps-ssh: _vps-require-host ## 🔑 VPS: открыть SSH сессию к серверу
	$(_VPS_SSH)

vps-logs: _vps-require-host ## 📜 VPS: логи learn_app (следить в реальном времени)
	$(_VPS_SSH) "sudo docker compose \
	  -f $(VPS_REMOTE_DIR)/$(VPS_COMPOSE_FILE) \
	  --env-file $(VPS_REMOTE_DIR)/.env.prod \
	  --project-name learn-service logs -f learn_app"

vps-logs-worker: _vps-require-host ## 📜 VPS: логи worker
	$(_VPS_SSH) "sudo docker compose \
	  -f $(VPS_REMOTE_DIR)/$(VPS_COMPOSE_FILE) \
	  --env-file $(VPS_REMOTE_DIR)/.env.prod \
	  --project-name learn-service logs -f worker"

vps-logs-litellm: _vps-require-host ## 📜 VPS: логи litellm
	$(_VPS_SSH) "sudo docker compose \
	  -f $(VPS_REMOTE_DIR)/docker-compose.litellm-prod.yml \
	  --env-file $(VPS_REMOTE_DIR)/.env.prod \
	  --project-name learn-service logs -f litellm"

vps-ps: _vps-require-host ## 📋 VPS: состояние всех контейнеров на сервере
	$(_VPS_SSH) "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
	  | grep -E 'learn_|worker|NAMES' || true"

vps-mem: _vps-require-host ## 🧠 VPS: память сервера, диск и статистика контейнеров
	$(_VPS_SSH) "\
	  echo '=== SYSTEM MEMORY ===' && free -h && \
	  echo '' && echo '=== DISK FREE SPACE ===' && df -h / /var/lib/docker && \
	  echo '' && echo '=== DOCKER CONTAINERS (CPU / MEM) ===' && \
	  sudo docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' && \
	  echo '' && echo '=== /proc/meminfo ===' && \
	  grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo"

vps-health: _vps-require-host ## ❤️  VPS: health check (контейнеры + HTTP /nginx-health)
	bash $(VPS_HEALTH_SH) --host $(VPS_HOST) --user $(VPS_USER) --port $(VPS_PORT) \
	  $(if $(wildcard $(VPS_SSH_KEY)),--ssh-key $(VPS_SSH_KEY))

vps-migrations: _vps-require-host ## 🗄️  VPS: пересобрать migrations image и применить Alembic
	$(_VPS_SSH) "cd $(VPS_REMOTE_DIR) && sudo docker compose \
	  -f $(VPS_COMPOSE_FILE) \
	  --env-file .env.prod \
	  --project-name learn-service build migrations && \
	  sudo docker compose \
	  -f $(VPS_COMPOSE_FILE) \
	  --env-file .env.prod \
	  --project-name learn-service run --rm migrations"

vps-down: _vps-require-host ## ⏹  VPS: остановить все контейнеры (без удаления данных)
	$(_VPS_SSH) "sudo docker compose \
	  -f $(VPS_REMOTE_DIR)/$(VPS_COMPOSE_FILE) \
	  --env-file $(VPS_REMOTE_DIR)/.env.prod \
	  --project-name learn-service down"

vps-restart: _vps-require-host ## 🔄 VPS: перезапустить app + worker (без деплоя)
	$(_VPS_SSH) "sudo docker compose \
	  -f $(VPS_REMOTE_DIR)/$(VPS_COMPOSE_FILE) \
	  --env-file $(VPS_REMOTE_DIR)/.env.prod \
	  --project-name learn-service restart learn_app worker"
