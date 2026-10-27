# LiteLLM для локальной разработки

Этот вариант запускает отдельный LiteLLM Proxy на `http://localhost:4000` и
подключается к общей Docker-сети `learn-service`. PostgreSQL берётся из уже
запущенного `learn-service` по адресу `postgres:5432`; второй контейнер
PostgreSQL и отдельная Docker-сеть не создаются. В существующем сервере
автоматически создаётся отдельная база `litellm_standalone_dev`; данные приложения
`learn-service` не используются.

Сервисы `learn-service`, подключённые к этой же сети, обращаются к proxy по
прежнему адресу `http://litellm:4000`. Контейнер сохраняет прежнее имя
`litellm_dev`; с хоста для ручной проверки используется `http://localhost:4000`.
Новый proxy загружает model aliases из локального `litellm-config.yaml`.

## Запуск

```sh
make litellm-dev-up
```

При первом запуске скрипт создаст `.env.litellm.dev` с локальными параметрами
общей сети (`learn-service_ai_network_dev`), PostgreSQL (сервис `postgres`,
пользователь `docker`) и случайными
`LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY`. Секретный файл исключён из Git.
Откройте `http://localhost:4000/ui`; для входа используйте значение
`LITELLM_MASTER_KEY` из `.env.litellm.dev`. Для переноса provider keys из
запущенного старого proxy выполните `make litellm-dev-import-env`; секреты будут
скопированы в локальный env-файл без вывода значений. После этого перезапустите
новый proxy командой `make litellm-dev-up`. После последующих изменений
`litellm-config.yaml` применяйте конфиг командой `make litellm-dev-restart`.

Чтобы LearnService использовал standalone proxy под прежним адресом
`http://litellm:4000`, синхронизируйте master key и пересоздайте только app и
worker:

```sh
make litellm-dev-sync-app-key
```

Команда обновляет все дубли `LITELLM_MASTER_KEY` в `learn-service/.env`,
выставляет ему права `0600` и не запускает/не перезапускает Postgres или старый
LiteLLM.

Запуск сначала проверяет наличие общей сети, затем доступность PostgreSQL. Если
одна из проверок не проходит, LiteLLM не запускается и новый Postgres не
создаётся. Если имя сети learn-service отличается, укажите его в
`LEARN_SERVICE_NETWORK` в `.env.litellm.dev`. При необходимости также измените
`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER` и `POSTGRES_PASSWORD`.
Пользователь PostgreSQL должен иметь право `CREATEDB`; пароль в `DATABASE_URL`
должен быть URL-безопасным.

## Управление

```sh
make litellm-dev-status
make litellm-dev-logs
make litellm-dev-down
```

Остановка LiteLLM не останавливает PostgreSQL и не удаляет базу `litellm`.
Для удаления созданной БД это нужно сделать отдельно в PostgreSQL.
