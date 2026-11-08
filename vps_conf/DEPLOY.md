# LiteLLM production deploy на VPS

Деплой загружает `litellm-config-prod.yaml` и отдельный
`docker-compose.litellm-prod.yml` вместе с приватным env-файлом,
сгенерированным из GitHub Secret `LITELLM_CONFIG`, затем пересоздаёт только
контейнер LiteLLM. Основной LearnService `.env.prod` не читается и не изменяется.

> Этот workflow **не разворачивает LearnService целиком** и не пересоздаёт его
> PostgreSQL, Redis, приложение или worker. LiteLLM использует ту же внешнюю
> Docker-сеть `learn_service_prod_network` и тот же контейнер PostgreSQL
> `learn_postgres_prod` (DNS-имя `postgres`), что и основное приложение. Внутри
> этого PostgreSQL создаётся отдельная БД `litellm`. Compose-проект называется
> `learn-service`, но LiteLLM Compose-файл отдельный.

В локальном игнорируемом `LITELLM_CONFIG.yml` или GitHub Secret
`LITELLM_CONFIG` должны быть заданы `VPS_HOST`, `LITELLM_MASTER_KEY`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`, а также provider keys для моделей из
`litellm-config-prod.yaml`: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`. `SSH_USER` необязателен (default `root`).
См. [`LITELLM_CONFIG.example.yml`](../LITELLM_CONFIG.example.yml).

Генератор передаёт в LiteLLM-контейнер только нужные runtime-переменные, а не
весь YAML (в нём также могут быть app/SMTP/Google секреты). Он percent-encode-ит
DB credentials и формирует URL к отдельной БД `litellm` внутри того же PostgreSQL
контейнера `learn_postgres_prod`. Runtime env хранится на VPS в
`/opt/learn-service/.env.litellm.prod` с правами `0600`.

## Что произойдёт при деплое

1. Workflow безопасно разбирает YAML-secret `LITELLM_CONFIG` и создаёт ограниченный
   LiteLLM env-файл; значения не выводятся в лог.
2. На VPS загружаются `litellm-config-prod.yaml`, `docker-compose.litellm-prod.yml`
   и `.env.litellm.prod`.
3. Скрипт резервирует активные файлы и атомарно устанавливает новые; env получает
   права `0600`.
4. Compose проверяется; `litellm-db-init` дожидается существующего PostgreSQL и
   создаёт только отдельную БД `litellm`, если её ещё нет.
5. Выполняется `docker compose up -d --force-recreate litellm`; остальные сервисы
   LearnService при этом не управляются и не перезапускаются.
6. Скрипт ждёт статуса Docker healthcheck `healthy`. При ошибке восстанавливает
   предыдущие конфиг, Compose и env-файл и пересоздаёт LiteLLM с ними.

## Вариант 1: деплой через GitHub Actions

### 1. Подготовить доступ к VPS

Если отдельного deploy-ключа ещё нет:

```sh
ssh-keygen -t ed25519 -C "github-actions-litellm-deploy" \
  -f ~/.ssh/litellm_deploy_key -N ""
ssh-copy-id -i ~/.ssh/litellm_deploy_key.pub root@<VPS_HOST>
ssh -i ~/.ssh/litellm_deploy_key root@<VPS_HOST> 'echo SSH_OK'
```

Deploy-пользователю нужны SSH-доступ и возможность выполнять `sudo docker
compose` без интерактивного запроса пароля. Не сохраняйте приватный ключ в Git.

### 2. Добавить GitHub Secrets

В репозитории откройте **Settings → Secrets and variables → Actions → New
repository secret** и добавьте:

| Secret | Обязательный | Значение |
| --- | --- | --- |
| `LITELLM_CONFIG` | Да | Полное содержимое локального `LITELLM_CONFIG.yml` в YAML-формате; `VPS_HOST` и `SSH_USER` тоже берутся из него |
| `VPS_SSH_PRIVATE_KEY` | Да | Полное содержимое приватного ключа, включая `BEGIN/END OPENSSH PRIVATE KEY` |
| `VPS_SSH_PORT` | Нет | SSH-порт; по умолчанию `22` |
| `VPS_REMOTE_DIR` | Нет | Каталог LearnService на VPS; по умолчанию `/opt/learn-service` |

`LITELLM_CONFIG.yml` — источник runtime-секретов. Скопируйте его целиком в
GitHub Secret `LITELLM_CONFIG`; не кладите YAML в обычные Actions variables.
Workflow строит временный env-файл только с необходимыми LiteLLM/provider/Postgres
ключами, загружает его как `/opt/learn-service/.env.litellm.prod` с правами `0600`
и удаляет локальную временную копию после job. Остальные app/SMTP/Google значения
из YAML не передаются контейнеру. `VPS_SSH_PRIVATE_KEY` добавляется отдельным
GitHub Secret; `VPS_HOST` и `SSH_USER` из дополнительных secrets не требуются.

Для Telegram-уведомлений (необязательно) добавьте `TELEGRAM_BOT_TOKEN` и
`TELEGRAM_CHAT_ID`; `TELEGRAM_THREAD_ID` — необязательный ID темы форума.
Если Telegram secrets не заданы, деплой продолжит работать, а шаг уведомления
будет пропущен.

### 3. Запустить workflow

- Автоматически: push в `main`, меняющий `litellm-config-prod.yaml`,
  `docker-compose.litellm-prod.yml`, deploy-скрипт или связанные deployment-файлы.
- Вручную: **Actions → Deploy LiteLLM to VPS → Run workflow**.

Результат проверяется healthcheck контейнера `litellm`. Уведомление в Telegram
отправляется отдельным workflow после завершения деплоя.

## Вариант 2: запуск из консоли через Makefile

На локальной машине нужны `ssh`, `scp`, `bash` и `make`; deploy-ключ должен быть
доступен локально. Подготовьте конфигурацию один раз:

```sh
cp vps_conf/deploy.env.example vps_conf/deploy.env
```

Укажите `VPS_HOST`, `VPS_USER`, `VPS_SSH_PORT` и `VPS_REMOTE_DIR`. По умолчанию
скрипт использует `~/.ssh/id_ed25519`; альтернативный ключ задаётся в
`VPS_SSH_KEY` (например, `~/.ssh/litellm_deploy_key`). Затем запустите:

```sh
make deploy-prod
```

Все параметры также можно переопределить переменными окружения, например:

```sh
VPS_HOST=203.0.113.10 VPS_USER=deploy VPS_SSH_KEY=~/.ssh/litellm_deploy_key \
  make deploy-prod
```

`vps_conf/deploy.env` содержит локальные SSH-параметры и исключён из Git. Для
локального деплоя сгенерируйте env из игнорируемого `LITELLM_CONFIG.yml`:

```sh
ruby scripts/generate_litellm_env.rb \
  --input LITELLM_CONFIG.yml \
  --output vps_conf/.env.litellm.prod
chmod 600 vps_conf/.env.litellm.prod
```

Затем выполните `make deploy-prod`. Генератор не печатает значения. Основной
LearnService `/opt/learn-service/.env.prod` этот workflow не использует.

Те же настройки `vps_conf/deploy.env` используются для доступа к серверу и логам:

```sh
make vps-ssh
make vps-logs-litellm
```

`make vps-logs` — короткий alias; остановите слежение через `Ctrl-C`.

## Проверка и восстановление

Скрипт сам ждёт healthcheck до 10 минут и при неудаче восстанавливает конфиг и
Compose-файл LiteLLM. Для ручной диагностики:

```sh
ssh root@<VPS_HOST> \
  'sudo docker ps --filter name=learn_litellm_prod; sudo docker logs --tail 100 learn_litellm_prod'
```

Healthcheck Compose проверяет `/health/liveness` внутри контейнера. Если сервис
остался `unhealthy`, проверьте наличие `/opt/learn-service/.env.litellm.prod`,
право PostgreSQL-пользователя на создание БД и подключение `learn_postgres_prod`
к `learn_service_prod_network`.
