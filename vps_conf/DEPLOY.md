# LiteLLM production deploy на VPS

Деплой загружает `litellm-config-prod.yaml` и отдельный
`docker-compose.litellm-prod.yml`, затем пересоздаёт только контейнер LiteLLM.
Конфигурация ссылается на provider keys и `LITELLM_MASTER_KEY` через `os.environ`;
значения берутся из существующего `/opt/learn-service/.env.prod` на VPS и не
копируются в этот репозиторий или GitHub Actions.

> Этот workflow **не разворачивает LearnService целиком** и не пересоздаёт его
> PostgreSQL, Redis, приложение или worker. LiteLLM использует ту же внешнюю
> Docker-сеть `learn_service_prod_network` и тот же контейнер PostgreSQL
> `learn_postgres_prod` (DNS-имя `postgres`), что и основное приложение. Внутри
> этого PostgreSQL создаётся отдельная БД `litellm`. Compose-проект называется
> `learn-service`, но LiteLLM Compose-файл отдельный.

Перед production-деплоем проверьте, что на VPS в LearnService `.env.prod`
заданы переменные, на которые ссылается `litellm-config-prod.yaml`:
`LITELLM_MASTER_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`DEEPSEEK_API_KEY` и `DASHSCOPE_API_KEY`. Последняя нужна модели `qwen3.7-flash`
и отсутствует в текущем шаблоне LearnService; добавьте её в секрет/переменные
окружения LearnService и обновите серверный `.env.prod` отдельно. Секреты
провайдеров не храните в этом репозитории и не передавайте в LiteLLM deploy
workflow.

## Что произойдёт при деплое

1. На VPS загружаются `litellm-config-prod.yaml` и `docker-compose.litellm-prod.yml`.
2. Скрипт резервирует активные файлы и атомарно устанавливает новые.
3. Compose проверяется; `litellm-db-init` дожидается существующего PostgreSQL и
   создаёт только отдельную БД `litellm`, если её ещё нет.
4. Выполняется `docker compose up -d --force-recreate litellm`; остальные сервисы
   LearnService при этом не управляются и не перезапускаются.
5. Скрипт ждёт статуса Docker healthcheck `healthy`. При ошибке восстанавливает
   предыдущие конфиг и Compose-файл и пересоздаёт LiteLLM с ними.

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
| `VPS_HOST` | Да | IP-адрес или hostname VPS |
| `VPS_SSH_PRIVATE_KEY` | Да | Полное содержимое приватного ключа, включая `BEGIN/END OPENSSH PRIVATE KEY` |
| `VPS_SSH_USER` | Нет | SSH-пользователь; по умолчанию `root` |
| `VPS_SSH_PORT` | Нет | SSH-порт; по умолчанию `22` |
| `VPS_REMOTE_DIR` | Нет | Каталог LearnService на VPS; по умолчанию `/opt/learn-service` |

Runtime-секреты (`LITELLM_MASTER_KEY`, API keys провайдеров и пароль
PostgreSQL) в GitHub Secrets добавлять не нужно. LiteLLM читает их из уже
существующего `/opt/learn-service/.env.prod` непосредственно на VPS. Если
`VPS_HOST`/SSH-ключ уже есть как repository secrets в learn-service, другой
репозиторий не может прочитать repository secrets автоматически: создайте их и
здесь либо используйте organization secrets с ограниченным доступом к обоим
репозиториям. Общий YAML `VPS_SECRETS` этот workflow не использует.

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

`vps_conf/deploy.env` содержит локальные параметры и исключён из Git. Файл
`.env.prod` в корне этого репозитория для deploy-команды не используется: runtime
секреты читает LiteLLM из LearnService `.env.prod` на VPS.

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
остался `unhealthy`, проверьте переменные в `/opt/learn-service/.env.prod`, право
PostgreSQL-пользователя на создание БД и подключение `learn_postgres_prod` к
`learn_service_prod_network`.
