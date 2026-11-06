# LiteLLM — настройка, изменения и production-деплой

Репозиторий содержит конфигурации LiteLLM для разработки и production. Production
LiteLLM работает как сервис существующего LearnService на VPS. Деплой из этого
репозитория загружает `litellm-config-prod.yaml` и отдельный
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

1. Передаёт на сервер production-конфиг и LiteLLM Compose-файл.
2. Сохраняет текущие файлы во временные резервные копии и атомарно устанавливает
   новые.
3. Проверяет Compose-конфигурацию и выполняет
   `docker compose up -d --force-recreate litellm`.
4. Ждёт, пока healthcheck контейнера LiteLLM не перейдёт в состояние `healthy`.
5. Если обновление завершается ошибкой, восстанавливает предыдущий конфиг и
   Compose-файл, затем пересоздаёт LiteLLM с прежней конфигурацией.

Docker image и runtime-секреты этим workflow не собираются и не загружаются.
Сервис читает provider keys и `LITELLM_MASTER_KEY` из `.env.prod` LearnService на
VPS.

Для деплоя необходимы на сервере:

- Docker и Docker Compose;
- каталог LearnService, обычно `/opt/learn-service`;
- production `.env.prod` LearnService с необходимыми LiteLLM и PostgreSQL
  переменными;
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
| `vps_conf/deploy.env` | Локально, в этом репозитории | Адрес VPS, SSH-пользователь/порт, путь LearnService и путь к локальному SSH-ключу для `make deploy-prod`. | Игнорируется Git; приватный ключ храните отдельно в `~/.ssh`. |
| `.env.prod` | На VPS в каталоге LearnService, обычно `/opt/learn-service/.env.prod` | Runtime-переменные LearnService и LiteLLM: общий Postgres login, LiteLLM master key и ключи AI-провайдеров. Production Compose LiteLLM читает этот файл непосредственно на VPS. | Не копировать в LiteLLM-репозиторий и не передавать в GitHub Actions. Ограничить права на VPS (`0600`). |
| `.env.prod` в корне этого репозитория | Локально, если такой файл есть | **Не используется** командами деплоя из этого README. Не путайте его с production-файлом LearnService на VPS. | Не коммитить. |

В production-конфиге (`litellm-config-prod.yaml`) используются переменные:

- `LITELLM_MASTER_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `DEEPSEEK_API_KEY`
- `DASHSCOPE_API_KEY` — используется моделью `qwen3.7-flash`

Все переменные, нужные включённым моделям, должны быть доступны контейнеру
LiteLLM из LearnService `.env.prod`. В текущем шаблоне LearnService нет
`DASHSCOPE_API_KEY`: если используется `qwen3.7-flash`, добавьте эту переменную в
настройки/секреты именно LearnService и обновите его серверный `.env.prod`.
Если провайдер не используется, удалите соответствующую модель из production
конфига. Не помещайте значения provider keys в YAML-конфиг, Git, GitHub workflow
или `vps_conf/deploy.env`.

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

Убедитесь, что deployment-каталог, production env, общая сеть и основной Postgres
на месте (LiteLLM Compose-файл установит сам deploy workflow):

```sh
ssh root@<VPS_HOST> \
  'test -f /opt/learn-service/.env.prod && \
   sudo docker network inspect learn_service_prod_network >/dev/null && \
   sudo docker inspect learn_postgres_prod --format "{{.State.Status}}"'
```

Проверьте, что `.env.prod` LearnService содержит все runtime-переменные для
моделей, включённых в `litellm-config-prod.yaml`.

## Вариант 1 — деплой через GitHub Actions

### Шаг 1. Добавить GitHub Secrets

В GitHub откройте страницу репозитория и перейдите:

**Settings → Secrets and variables → Actions → New repository secret**

Создайте следующие repository secrets:

| Secret | Обязателен | Что положить |
| --- | --- | --- |
| `VPS_HOST` | Да | IP-адрес или hostname VPS. |
| `VPS_SSH_PRIVATE_KEY` | Да | Полный текст приватного SSH-ключа, включая строки `BEGIN OPENSSH PRIVATE KEY` и `END OPENSSH PRIVATE KEY`. Добавляйте файл без суффикса `.pub`. |
| `VPS_SSH_USER` | Нет | SSH-пользователь; если не задан, используется `root`. |
| `VPS_SSH_PORT` | Нет | SSH-порт; если не задан, используется `22`. |
| `VPS_REMOTE_DIR` | Нет | Корень LearnService на сервере; если не задан, используется `/opt/learn-service`. |

Для добавления приватного ключа можно вывести его локально и скопировать целиком:

```sh
cat ~/.ssh/litellm_deploy_key
```

Добавляйте сюда только параметры SSH-доступа к VPS. Значения API-ключей,
`LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD` и содержимое LearnService `.env.prod` в
GitHub Actions **не добавляйте**: workflow их не читает и не загружает. Compose
на VPS использует существующий `/opt/learn-service/.env.prod`; LiteLLM получает
из него runtime-переменные, а одноразовый `litellm-db-init` подключается к уже
работающему LearnService PostgreSQL и создаёт в нём только отдельную БД `litellm`.

Если SSH secrets уже заведены как repository secrets в репозитории LearnService,
GitHub не предоставляет их другому репозиторию автоматически. Можно либо создать
такие же значения в Secrets этого репозитория, либо (если репозитории в одной
организации) использовать organization secrets с доступом только к обоим нужным
репозиториям. Общий YAML `VPS_SECRETS` не нужен: этот workflow ждёт отдельные
`VPS_HOST` и `VPS_SSH_PRIVATE_KEY`, а секреты приложения остаются на VPS.

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
подключился к VPS, обновил конфиг и дождался статуса Docker healthcheck `healthy`.
При наличии Telegram secrets придёт отдельное сообщение о результате.

## Вариант 2 — деплой из консоли через Makefile

Локально нужны `make`, `bash`, `ssh` и `scp` (на macOS/Linux обычно уже доступны).
Docker на рабочей машине для production-деплоя не нужен.

### Шаг 1. Создать локальный deploy env

Из корня репозитория выполните:

```sh
cp vps_conf/deploy.env.example vps_conf/deploy.env
chmod 600 vps_conf/deploy.env
```

Откройте `vps_conf/deploy.env` и заполните параметры:

```dotenv
VPS_HOST=your-vps-host-or-ip
VPS_USER=root
VPS_SSH_PORT=22
VPS_REMOTE_DIR=/opt/learn-service
VPS_SSH_KEY=~/.ssh/litellm_deploy_key
```

`VPS_SSH_KEY` необязателен: без него скрипт проверяет `~/.ssh/id_ed25519`, затем
`~/.ssh/id_rsa`. Если SSH-ключ уже доступен через `ssh-agent`, можно не задавать
`VPS_SSH_KEY`.

В `deploy.env` должны быть только параметры подключения. Не добавляйте туда
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`,
`LITELLM_MASTER_KEY` или другие runtime-секреты.

Файл `vps_conf/deploy.env` исключён из Git. После настройки убедитесь, что он не
попадает в изменения:

```sh
git check-ignore -v vps_conf/deploy.env
```

### Шаг 2. Запустить деплой

Из корня репозитория:

```sh
make deploy-prod
```

Скрипт проверит параметры, SSH-доступ и наличие локальных production-файлов,
загрузит конфиг и Compose, пересоздаст только `litellm` и проверит healthcheck.

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

Те же значения из `vps_conf/deploy.env` используются командами для обслуживания
сервера:

```sh
make vps-ssh             # открыть интерактивную SSH-сессию
make vps-logs-litellm    # следить за production-логами LiteLLM
```

`make vps-logs` — короткий alias для `make vps-logs-litellm`. Остановить просмотр
логов можно через `Ctrl-C`; это не останавливает и не перезапускает контейнер.
Для разового подключения к другому серверу можно переопределить параметры:

```sh
make vps-ssh VPS_HOST=203.0.113.10 VPS_USER=deploy VPS_SSH_KEY=~/.ssh/litellm_deploy_key
make vps-logs VPS_HOST=203.0.113.10 VPS_USER=deploy VPS_SSH_KEY=~/.ssh/litellm_deploy_key
```

Для обеих команд нужен тот же SSH-доступ, который описан в разделе
[первичной настройки VPS](#первичная-настройка-vps). Команда просмотра логов
использует отдельный `docker-compose.litellm-prod.yml` и общий LearnService
`.env.prod` на VPS.

## Рабочий цикл изменения и деплоя

Рекомендуемый порядок при изменении списка моделей или параметров LiteLLM:

1. **Уточните, где должно применяться изменение.**
   - Локальная разработка: `litellm-config.yaml`.
   - Production: `litellm-config-prod.yaml`.
2. **Проверьте runtime-переменные.** Если новая модель требует API key, сначала
   настройте его в LearnService `.env.prod` на VPS. Не записывайте значение ключа
   в конфиг. В production-конфиге используйте ссылки вида
   `os.environ/OPENAI_API_KEY`.
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
    --env-file .env.prod ps litellm'
```

Если healthcheck не прошёл, проверьте:

1. Все ли env-переменные, на которые ссылается конфиг, присутствуют в LearnService
   `.env.prod`.
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
