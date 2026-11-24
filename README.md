# beeatlas-vscode

Web IDE для BeeAtlas: [code-server](https://github.com/cdr/code-server) (VS Code в браузере) + расширение C4
(`vimpelcom.c4-varp`) для работы с Architecture As A Code и диаграммами Structurizr.

Расширение **вендорится в репозиторий** (`vscode-extensions/`, актуальная версия 2.1.3) и запекается в образ:
сборка и запуск не обращаются к маркетплейсу, поэтому IDE работает в закрытых сетях без доступа в интернет.
Автообновление расширений и проверка обновлений отключены (см. «Работа без доступа в интернет»).

Образ собирается на GitHub Actions и публикуется в GHCR:
`ghcr.io/tech-beeline/beeatlas-vscode:latest`.

## Состав

| Файл | Назначение |
|------|------------|
| `Dockerfile` | Ubuntu 24.04 + Node 20 + code-server + C4-расширение из `vscode-extensions/` |
| `entrypoint.sh` | Установка сертификатов из `/certs`, восстановление расширений, пароль, запуск code-server |
| `docker-compose.yml` | Локальный запуск (сборка из исходников или готовый образ) |
| `vscode-extensions/` | Вендоренное расширение `vimpelcom.c4-varp` 2.1.3 (ставится в образ и монтируется в контейнер) |

## Переменные окружения

| Переменная | Обязательна | По умолчанию | Описание |
|------------|-------------|--------------|----------|
| `PASSWORD` | **да** | — | Пароль для входа в web IDE. Без неё контейнер завершится с ошибкой |
| `WORKSPACE` | нет | `workspace` | Рабочая директория внутри `/home/vscode` |

Порт контейнера — `8080`. Пробрасывается на хост как `8088`.

## Локальный запуск

```bash
PASSWORD=my_secure_password docker compose up -d --build
```

Открыть <http://localhost:8088>, войти с паролем из `PASSWORD`.

Логи и остановка:

```bash
docker compose logs -f
docker compose down
```

Монтирования из `docker-compose.yml`:

- `./workspace` → `/home/vscode/workspace` — проекты;
- `./vscode-extensions` → `/home/vscode/.local/share/code-server/extensions` — предустановленное C4-расширение
  (если папка пуста, `entrypoint.sh` восстанавливает расширения из `extensions-save` внутри образа);
- `./certs` → `/certs:ro` — дополнительные `.crt`, которые добавляются в системное хранилище
  (нужно для самоподписанных сертификатов внутренних сервисов).

## Сборка образа

```bash
docker build -t ghcr.io/tech-beeline/beeatlas-vscode:latest .
```

## Работа без доступа в интернет

Расширение C4 поставляется в репозитории (`vscode-extensions/`) и копируется в образ — при сборке и запуске
маркетплейс не используется. Чтобы VS Code Server не пытался проверять обновления (в закрытой сети такие
запросы висят в таймаутах и блокируют работу в UI):

- в образ записывается `~/.local/share/code-server/User/settings.json` с
  `extensions.autoCheckUpdates: false`, `extensions.autoUpdate: false`, `extensions.ignoreRecommendations: true`,
  `update.mode: none` и `telemetry.telemetryLevel: off`;
- code-server запускается с `--disable-update-check --disable-telemetry`;
- в `vscode-extensions/extensions.json` расширение помечено как `pinned`.

Если папка `vscode-extensions` не смонтирована (или пустая), `entrypoint.sh` восстановит расширение
из `extensions-save` внутри образа — тоже без сети.

Папка `vscode-extensions` монтируется в контейнер **read-write**: версия расширения, обновлённая вручную
(например, через UI при наличии доступа в интернет), сохраняется на хосте и используется после перезапуска
контейнера. Автоматические проверки и установка обновлений при этом выключены.

### Обновление расширения

1. Скачать новый `.vsix` с Open VSX и установить его в чистую папку:
   ```bash
   mkdir -p /tmp/ext
   docker run --rm -u root -v /tmp/ext:/home/vscode/.local/share/code-server/extensions \
     --entrypoint code-server ghcr.io/tech-beeline/beeatlas-vscode:latest \
     --extensions-dir /home/vscode/.local/share/code-server/extensions \
     --install-extension vimpelcom.c4-varp@<версия>
   ```
2. Заменить содержимое `vscode-extensions/` на `/tmp/ext` (должны остаться `extensions.json` и папка
   `vimpelcom.c4-varp-<версия>-universal`).
3. Пересобрать образ.

## CI

- **Smoke test** (`.github/workflows/compose-smoke.yml`) — на PR: сборка, запуск через `docker compose`,
  HTTP-проверки и UI-проверка в настоящем браузере, логи и скриншоты в artifact.
- **Build and Publish Docker Image** (`.github/workflows/image.yml`) — на push в `main`, semver-теги и вручную:
  сборка `linux/amd64` + `linux/arm64` и пуш в `ghcr.io/<owner>/<repo>` с тегами `<git describe>` и `latest`.

## Смоук-тесты

```bash
PASSWORD=my_secure_password ./scripts/smoke.sh
```

Скрипт собирает образ, поднимает `docker compose` и проверяет:

| Слой | Проверки (`scripts/smoke-http.sh`) |
|------|-------------------------------------|
| HTTP | `/healthz` = 200; `/` без сессии редиректит на `/login`; неверный пароль отвергается; верный выдаёт `code-server-session`; с сессией отдаётся workbench |
| Расширение | `vimpelcom.c4-varp@<версия из extensions.json>` установлено, файлы на месте, нет `.obsolete`, `extensions.autoCheckUpdates=false`, в логах нет обращений к маркетплейсу |

| Слой | Проверки (`scripts/ui-smoke.mjs`, Chrome + puppeteer-core) |
|------|-------------------------------------------------------------|
| UI | логин через форму, загрузка workbench, расширение видно в панели Extensions, `smoke.dsl` открывается с языком **C4**, команды расширения доступны в палитре команд |

| Слой | Проверки (`scripts/smoke-persistence.sh`) |
|------|--------------------------------------------|
| Персистентность | каталог расширений — rw-монтаж с хоста; «обновлённая» версия (9.9.9) появилась на хосте; после перезапуска контейнера активна именно она, а не запечённая в образе; `entrypoint.sh` не перезаписал смонтированные расширения; исходная папка восстановлена (сверка md5) |

Опции: `KEEP=1` — оставить контейнеры запущенными, `SKIP_BUILD=1` — без пересборки,
`SKIP_UI=1` — только HTTP-часть, `SKIP_PERSISTENCE=1` — без проверки персистентности расширений,
`CHROME_PATH=/path/to/chrome` или `CDP_URL=http://127.0.0.1:9222`.
Логи и скриншоты складываются в `logs/`.

## Использование в инфраструктуре

В `beeatlas-fdm-infrastructure` сервис `web-ide` подключается готовым образом:

```yaml
  web-ide:
    image: ghcr.io/tech-beeline/beeatlas-vscode:latest
    container_name: web-ide
    ports:
      - "8088:8080"
    environment:
      - PASSWORD=my_secure_password
      - WORKSPACE=workspace
    volumes:
      - ./workspace:/home/vscode/workspace
      - ./web-ide/vscode-extensions:/home/vscode/.local/share/code-server/extensions
      - ./certs:/certs:ro
```
