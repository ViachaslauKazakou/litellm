.DEFAULT_GOAL := help
.PHONY: help litellm-dev-up litellm-dev-down litellm-dev-logs litellm-dev-status litellm-dev-restart litellm-dev-import-env litellm-dev-sync-app-key

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

litellm-dev-up: ## Запустить отдельный локальный LiteLLM (порт 4000, имя litellm)
	@bash scripts/litellm-dev.sh up

litellm-dev-down: ## Остановить LiteLLM, не затрагивая PostgreSQL
	@bash scripts/litellm-dev.sh down

litellm-dev-logs: ## Смотреть логи LiteLLM
	@bash scripts/litellm-dev.sh logs

litellm-dev-status: ## Показать состояние LiteLLM
	@bash scripts/litellm-dev.sh status

litellm-dev-restart: ## Перечитать config и перезапустить LiteLLM
	@bash scripts/litellm-dev.sh restart

litellm-dev-import-env: ## Импортировать нужные provider keys из текущего learn-service LiteLLM
	@python3 scripts/import_litellm_env.py

litellm-dev-sync-app-key: ## Синхронизировать master key в LearnService и пересоздать app/worker
	@python3 scripts/sync_learnservice_key.py "$(LEARN_SERVICE_DIR)"

ps: ## 📋 Список контейнеров с базовой информацией
	@echo "📋 Запущенные контейнеры:"
	@echo ""
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
# 	docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}\t{{.Networks}}\t{{.Status}}"
