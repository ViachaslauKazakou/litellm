# LiteLLM — настройка, изменения и production-деплой

Репозиторий содержит конфигурации LiteLLM для разработки и production. Production
LiteLLM работает как сервис существующего LearnService на VPS. Деплой из этого
репозитория берёт значения из GitHub Secret `LITELLM_CONFIG`, формирует отдельный
LiteLLM env-файл, загружает его вместе с `litellm-config-prod.yaml` и
`docker-compose.litellm-prod.yml`, затем пересоздаёт только сервис `litellm`; он
не разворачивает LearnService целиком и не перезапускает его PostgreSQL, Redis,
приложение или worker.

## Содержание

- [Как устроен деплой](#как-устроен-деплой)
- [Какие env-файлы за что отвечают](#какие-env-файлы-за-что-отвечают)
- [Первичная настройка VPS](#первичная-настройка-vps)
- [Вариант 1 — GitHub Actions](#вариант-1--деплой-через-github-actions)
- [Вариант 2 — локальный Makefile](#вариант-2--деплой-из-консоли-через-makefile)
- [Рабочий цикл изменения и деплоя](#рабочий-цикл-изменения-и-деплоя)
- [Проверка результата и диагностика](#проверка-результата-и-диагностика)
- [Откат](#откат)

## Как устроен деплой

На VPS уже должна работать production-инфраструктура LearnService. Деплой LiteLLM:

1. Разбирает GitHub Secret `LITELLM_CONFIG` и формирует приватный env-файл только
   с LiteLLM/provider/Postgres-переменными. `VPS_HOST` и `SSH_USER` берутся из
   того же YAML.
2. Передаёт на сервер production-конфиг, LiteLLM Compose-файл и env-файл;
   сохраняет предыдущие файлы и атомарно устанавливает новые.
3. Проверяет Compose-конфигурацию и выполняет
   `docker compose up -d --force-recreate litellm`.
4. Ждёт, пока healthcheck контейнера LiteLLM не перейдёт в состояние `healthy`.
5. Если обновление завершается ошибкой, восстанавливает предыдущие конфиг,
   Compose и env-файл, затем пересоздаёт LiteLLM с прежней конфигурацией.

Workflow не передаёт LearnService `.env.prod` и не перезаписывает его. Отдельный
сгенерированный файл хранится на VPS как
`/opt/learn-service/.env.litellm.prod` с правами `0600`.

Для деплоя необходимы на сервере:

- Docker и Docker Compose;
- каталог LearnService, обычно `/opt/learn-service`;
- запущенный LearnService PostgreSQL (`learn_postgres_prod`) в общей сети
  `learn_service_prod_network`;
- SSH-доступ и возможность выполнять `sudo docker compose` без запроса пароля.

> Этот LiteLLM-деплой не устанавливает Docker и не создаёт первичную
> инфраструктуру. Подготовьте production LearnService отдельно.

## Какие env-файлы за что отвечают

Не смешивайте следующие файлы — они относятся к разным средам и содержат разные
настройки.

| Файл | Где находится | Для чего нужен | Секреты |
| --- | --- | --- | --- |
| `.env.litellm.dev` | Локально, корень этого репозитория | Настройки LiteLLM для разработки: подключение к локальной/общей PostgreSQL, локальные master/salt keys и параметры сети. Создаётся автоматически при первом `make litellm-dev-up`. | Не коммитить; уже исключён из Git. |
| `LITELLM_CONFIG.yml` | Локально, корень репозитория | Полный YAML с VPS-параметрами и env-секретами; источник для локальной генерации и содержимое GitHub Secret `LITELLM_CONFIG`. | Игнорируется Git. Не коммитить и ротировать, если значения раскрыты. |
| `LITELLM_CONFIG` | GitHub → Secrets and variables → Actions | Полное содержимое локального `LITELLM_CONFIG.yml`; workflow извлекает `VPS_HOST`/`SSH_USER` и разрешённые runtime-ключи LiteLLM. | GitHub Secret. Остальные app/SMTP/Google значения не передаются LiteLLM-контейнеру. |
| `vps_conf/deploy.env` | Локально, в этом репозитории | SSH-ключ/порт/remote-dir для локального `make deploy-prod`; VPS host/user можно взять из этого файла для ручного запуска. | Игнорируется Git; приватный ключ храните отдельно в `~/.ssh`. |
| `vps_conf/.env.litellm.prod` | Локально, генерируется из `LITELLM_CONFIG.yml` | Временный runtime-файл для локального SSH-деплоя; содержит только LiteLLM/provider/Postgres переменные. | Игнорируется Git, права `0600`. |
| `/opt/learn-service/.env.litellm.prod` | На VPS | Runtime env LiteLLM, доставленный workflow; Compose загружает его только сервисам LiteLLM/bootstrap. | Права `0600`; обновляется при успешном деплое с GitHub Secret. |
| `/opt/learn-service/.env.prod` | На VPS, LearnService | Env основного приложения; LiteLLM deploy его не читает и не изменяет. | Остаётся под управлением LearnService. |

Генератор строит `LITELLM_DATABASE_URL` из `POSTGRES_USER`/`POSTGRES_PASSWORD`
и percent-encode credentials перед подключением к `postgres:5432/litellm`.

В production-конфиге (`litellm-config-prod.yaml`) используются переменные:

- `LITELLM_MASTER_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `DEEPSEEK_API_KEY`
- `DASHSCOPE_API_KEY` — используется моделью `qwen3.7-flash`

Все значения для этих переменных берутся из `LITELLM_CONFIG.yml` и передаются
через GitHub Secret `LITELLM_CONFIG`. Не записывайте provider keys в
`litellm-config-prod.yaml`, Git или workflow YAML.

Локальная конфигурация и инструкции по разработке описаны также в
[`LITELLM_LOCAL_DEV.md`](LITELLM_LOCAL_DEV.md). Детали VPS-скрипта и его
поведения — в [`vps_conf/DEPLOY.md`](vps_conf/DEPLOY.md).

## Первичная настройка VPS

### 1. Проверить SSH-доступ

Для отдельного deploy-ключа создайте пару ключей на рабочей машине:

```sh
ssh-keygen -t ed25519 -C "litellm-vps-deploy" \
  -f ~/.ssh/litellm_deploy_key -N ""
chmod 600 ~/.ssh/litellm_deploy_key
```

Добавьте **публичную** часть на VPS и проверьте соединение:

```sh
ssh-copy-id -i ~/.ssh/litellm_deploy_key.pub root@<VPS_HOST>
ssh -i ~/.ssh/litellm_deploy_key root@<VPS_HOST> 'echo SSH_OK'
```

В примерах используется `root`. Предпочтительно использовать отдельного
deploy-пользователя с доступом к Docker через `sudo`; в GitHub/local настройках
тогда укажите его в `VPS_SSH_USER`/`VPS_USER`.

### 2. Проверить LearnService на сервере

Убедитесь, что deployment-каталог, общая сеть и основной Postgres на месте
(Compose и LiteLLM env-файл установит deploy workflow):

```sh
ssh root@<VPS_HOST> \
  'sudo docker network inspect learn_service_prod_network >/dev/null && \
   sudo docker inspect learn_postgres_prod --format "{{.State.Status}}"'
```

Production env для LiteLLM создаётся из GitHub Secret `LITELLM_CONFIG` при каждом
деплое; вручную создавать `/opt/learn-service/.env.litellm.prod` не нужно.

## Вариант 1 — деплой через GitHub Actions

### Шаг 1. Добавить GitHub Secrets

В GitHub откройте страницу репозитория и перейдите:

**Settings → Secrets and variables → Actions → New repository secret**

Создайте следующие repository secrets:

| Secret | Обязателен | Что положить |
| --- | --- | --- |
| `LITELLM_CONFIG` | Да | Полное содержимое локального `LITELLM_CONFIG.yml` (YAML со значениями). Из него workflow читает `VPS_HOST`/`SSH_USER` и генерирует LiteLLM env. |
| `VPS_SSH_PRIVATE_KEY` | Да | Полный текст приватного SSH-ключа, включая строки `BEGIN OPENSSH PRIVATE KEY` и `END OPENSSH PRIVATE KEY`. Добавляйте файл без суффикса `.pub`. |
| `VPS_SSH_PORT` | Нет | SSH-порт; если не задан, используется `22`. |
| `VPS_REMOTE_DIR` | Нет | Корень LearnService на сервере; если не задан, используется `/opt/learn-service`. |

Для добавления приватного ключа можно вывести его локально и скопировать целиком:

```sh
cat ~/.ssh/litellm_deploy_key
```

Содержимое `LITELLM_CONFIG.yml` храните именно в GitHub Secret `LITELLM_CONFIG`, а
не в переменных workflow или git. `VPS_HOST` и `SSH_USER` читаются из него;
`VPS_SSH_PRIVATE_KEY` остаётся отдельным секретом. Workflow формирует env-файл
только из `LITELLM_MASTER_KEY`, provider keys, `POSTGRES_USER`/`POSTGRES_PASSWORD`
и необязательных LiteLLM UI/salt-настроек. Остальные app/SMTP/Google значения из
YAML не попадают в контейнер. LearnService `.env.prod` не читается и не
перезаписывается.

### Шаг 2. (Необязательно) Настроить Telegram

В том же разделе добавьте:

| Secret | Назначение |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | Токен бота, который отправляет уведомления. |
| `TELEGRAM_CHAT_ID` | ID чата или канала для уведомлений. |
| `TELEGRAM_THREAD_ID` | Необязательно: ID темы форума. |

Если `TELEGRAM_BOT_TOKEN` или `TELEGRAM_CHAT_ID` отсутствует, деплой работает,
уведомление пропускается. Проверить уведомление вручную можно через **Actions →
LiteLLM VPS Telegram Notifications → Run workflow**.

### Шаг 3. Запустить GitHub workflow

Workflow называется **Deploy LiteLLM to VPS**.

- **Ручной деплой:** откройте **Actions → Deploy LiteLLM to VPS → Run workflow**.
  Выберите ветку и запустите workflow. `workflow_dispatch` доступен, когда файл
  workflow уже находится в default branch репозитория.
- **Автодеплой:** push в `main` запускает workflow, если изменён
  `litellm-config-prod.yaml`, `docker-compose.litellm-prod.yml`, deploy-скрипт,
  Makefile, `vps_conf/**` или сам файл `.github/workflows/vps-deploy.yml`.

Изменение README или локального dev-конфига само по себе production-деплой не
запускает.

### Шаг 4. Проверить результат

Откройте запуск workflow в **Actions**. Успешный запуск означает, что скрипт
подключился к VPS, обновил production-конфиг, Compose и выделенный runtime env
LiteLLM и дождался статуса Docker healthcheck `healthy`.
При наличии Telegram secrets придёт отдельное сообщение о результате.

## Вариант 2 — деплой из консоли через Makefile

Локально нужны `make`, `bash`, `ssh` и `scp` (на macOS/Linux обычно уже доступны).
Docker на рабочей машине для production-деплоя не нужен.

### Шаг 1. Проверить локальный YAML и SSH-доступ

Команда `make vps-deploy` берёт `VPS_HOST`, `SSH_USER` и runtime-секреты из
игнорируемого `LITELLM_CONFIG.yml`; создавать `vps_conf/deploy.env` для неё не
нужно. Убедитесь, что локальный YAML заполнен реальными значениями, а SSH-ключ
доступен. Для подключения можно передать параметры прямо команде, например:

```sh
make vps-deploy VPS_PORT=22 VPS_SSH_KEY=~/.ssh/litellm_deploy_key
```

Если `VPS_SSH_KEY` не указан или ключ по умолчанию отсутствует, deploy script
проверяет `~/.ssh/id_ed25519`, затем `~/.ssh/id_rsa`; также можно использовать
уже загруженный в `ssh-agent` ключ.

`vps_conf/deploy.env` нужен только для низкоуровневого `make deploy-prod` или
прямого вызова `scripts/deploy_litellm.sh`; параметры, явно переданные Make,
имеют приоритет над ним. Не храните там provider keys, `LITELLM_MASTER_KEY`,
`POSTGRES_PASSWORD` или другие runtime-секреты.

Создайте отдельный локальный env-файл LiteLLM из того же YAML (для GitHub Actions
это выполняется автоматически из секрета `LITELLM_CONFIG`). Для локального
деплоя команда `make vps-deploy` создаёт его сама; отдельная команда нужна, если
вы хотите проверить или подготовить env заранее:

```sh
ruby scripts/generate_litellm_env.rb \
  --input LITELLM_CONFIG.yml \
  --output vps_conf/.env.litellm.prod
chmod 600 vps_conf/.env.litellm.prod
```

Генератор не печатает секреты и включает только нужные LiteLLM/provider/Postgres
переменные. Env-файл игнорируется Git; deploy script загружает его на VPS как
`/opt/learn-service/.env.litellm.prod`.

Секретные файлы исключены из Git. Проверьте это перед деплоем:

```sh
git check-ignore -v vps_conf/deploy.env
git check-ignore -v LITELLM_CONFIG.yml
git check-ignore -v vps_conf/.env.litellm.prod
```

### Шаг 2. Запустить деплой

Из корня репозитория запустите локальный production-деплой:

```sh
make vps-deploy
```

Команда читает `VPS_HOST` и `SSH_USER` из игнорируемого `LITELLM_CONFIG.yml`,
генерирует отдельный env-файл с правами `0600`, затем загружает файлы на VPS,
пересоздаёт только `litellm` и проверяет healthcheck. Для SSH-порта, ключа и
каталога можно переопределить `VPS_PORT`, `VPS_SSH_KEY` и `VPS_REMOTE_DIR`.

Если env-файл уже подготовлен вручную, можно использовать низкоуровневую команду
`make deploy-prod`; она не генерирует env автоматически.

Также можно переопределить настройки разовым вызовом, не меняя `deploy.env`:

```sh
VPS_HOST=203.0.113.10 \
VPS_USER=deploy \
VPS_SSH_KEY=~/.ssh/litellm_deploy_key \
make deploy-prod
```

Или вызвать скрипт напрямую с параметрами:

```sh
bash scripts/deploy_litellm.sh \
  --host <VPS_HOST> \
  --user root \
  --port 22 \
  --ssh-key ~/.ssh/litellm_deploy_key \
  --remote-dir /opt/learn-service
```

Приоритет настроек: параметры скрипта → экспортированные переменные окружения →
`vps_conf/deploy.env` → значения по умолчанию.

### Подключиться к VPS и посмотреть логи LiteLLM

Команды обслуживания используют Make-переменные (`VPS_HOST`, `VPS_USER`,
`VPS_PORT`, `VPS_SSH_KEY`). По умолчанию host/user соответствуют production
настройкам; `vps_conf/deploy.env` эти Make-цели не читают:

```sh
make vps-ssh             # открыть интерактивную SSH-сессию
make vps-logs-litellm    # следить за production-логами LiteLLM
```

`make vps-logs` — короткий alias для `make vps-logs-litellm`. Остановить просмотр
логов можно через `Ctrl-C`; это не останавливает и не перезапускает контейнер.
Для разового подключения к другому серверу можно переопределить параметры:

```sh
make vps-ssh VPS_HOST=203.0.113.10 VPS_USER=deploy VPS_PORT=2222 VPS_SSH_KEY=~/.ssh/litellm_deploy_key
make vps-logs VPS_HOST=203.0.113.10 VPS_USER=deploy VPS_PORT=2222 VPS_SSH_KEY=~/.ssh/litellm_deploy_key
```

Для обеих команд нужен тот же SSH-доступ, который описан в разделе
[первичной настройки VPS](#первичная-настройка-vps). Команда просмотра логов
использует отдельный `docker-compose.litellm-prod.yml` и
`.env.litellm.prod` на VPS.

## Рабочий цикл изменения и деплоя

Рекомендуемый порядок при изменении списка моделей или параметров LiteLLM:

1. **Уточните, где должно применяться изменение.**
   - Локальная разработка: `litellm-config.yaml`.
   - Production: `litellm-config-prod.yaml`.
2. **Проверьте runtime-переменные.** Если новая модель требует API key, сначала
   добавьте его в локальный `LITELLM_CONFIG.yml` и обновите GitHub Secret
   `LITELLM_CONFIG`. Значения не пишите в model config или Git; в
   `litellm-config-prod.yaml` используйте ссылки `os.environ/KEY_NAME`.
3. **Проверьте diff и YAML до деплоя.** Например, если Ruby установлен:

   ```sh
   git diff --check
   ruby -e 'require "yaml"; YAML.load_file("litellm-config-prod.yaml"); puts "YAML OK"'
   git diff -- litellm-config-prod.yaml
   ```

   Убедитесь, что в diff нет API-ключей, паролей и приватных ключей.
4. **Проверьте локальную разработку**, если изменялся dev-конфиг:

   ```sh
   make litellm-dev-up
   make litellm-dev-status
   make litellm-dev-logs
   ```

   Успешная локальная проверка не заменяет production healthcheck.
5. **Подготовьте production-изменение** в отдельной ветке и отправьте его через
   pull request. Проверьте финальный diff до merge в `main`.
6. **Разверните production одним из двух способов:** GitHub Actions (автоматически
   после push в `main` или вручную) либо локально командой `make deploy-prod`.
7. **Проверьте результат** в логе workflow/терминале и убедитесь, что LiteLLM
   healthy. При необходимости проверьте API/UI с корректным клиентским ключом.

Для подробного описания локальной базы, Docker-сети и dev env см.
[`LITELLM_LOCAL_DEV.md`](LITELLM_LOCAL_DEV.md).

## Проверка результата и диагностика

Получить состояние production-контейнера:

```sh
ssh root@<VPS_HOST> \
  'sudo docker inspect --format "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}" learn_litellm_prod'
```

Посмотреть последние логи:

```sh
ssh root@<VPS_HOST> \
  'sudo docker logs --tail 100 learn_litellm_prod'
```

Проверить сервис через Compose на VPS:

```sh
ssh root@<VPS_HOST> \
  'cd /opt/learn-service && sudo docker compose \
    --project-name learn-service \
    --file docker-compose.litellm-prod.yml \
    --env-file .env.litellm.prod ps litellm'
```

Если healthcheck не прошёл, проверьте:

1. Все ли необходимые ключи присутствуют в GitHub Secret `LITELLM_CONFIG` и
   установлены ли права `0600` на `/opt/learn-service/.env.litellm.prod`.
2. Есть ли у LiteLLM доступ к PostgreSQL и к нужной Docker-сети.
3. Логи контейнера (`docker logs`) и результат Actions/job.
4. Не был ли недавно обновлён LiteLLM-конфиг параллельным деплоем LearnService.

Deploy-скрипт ожидает healthcheck `healthy` и может ждать до 10 минут. Он не
проверяет доступность каждого внешнего AI-провайдера отдельным тестовым запросом.

## Откат

Если новый конфиг не проходит Compose-команду или healthcheck, deploy-скрипт
автоматически восстанавливает предыдущую копию и возвращает ошибочный статус.

Если деплой завершился успешно, но позже нужно вернуть предыдущую версию:

1. Восстановите прежний `litellm-config-prod.yaml` (например, revert соответствующего
   Git-коммита или выберите нужную версию файла).
2. Повторно запустите **Deploy LiteLLM to VPS** в Actions либо выполните
   `make deploy-prod`.

База данных не откатывается: workflow создаёт отдельную БД `litellm` в
существующем контейнере PostgreSQL и не изменяет данные БД LearnService.
