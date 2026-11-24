#!/usr/bin/env bash
# Полный смоук web IDE: поднимает docker compose, проверяет HTTP-слой и UI в браузере.
#
# Использование:
#   PASSWORD=my_secure_password ./scripts/smoke.sh              # собрать и прогнать
#   KEEP=1 PASSWORD=... ./scripts/smoke.sh                      # оставить контейнеры запущенными
#   SKIP_BUILD=1 PASSWORD=... ./scripts/smoke.sh                # без пересборки образа
#   SKIP_UI=1 PASSWORD=... ./scripts/smoke.sh                   # только HTTP-проверки
#
# Для UI-части нужен Chrome/Chromium (CHROME_PATH) либо уже запущенный Chrome (CDP_URL).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PASSWORD:?PASSWORD is required}"
export PASSWORD
export BASE_URL="${BASE_URL:-http://127.0.0.1:8088}"
export SCREENSHOT_DIR="${SCREENSHOT_DIR:-${ROOT}/logs}"

mkdir -p "$SCREENSHOT_DIR" workspace

# Файл для проверки активации расширения.
cat > workspace/smoke.dsl <<'EOF'
workspace "Smoke Workspace" "Smoke test workspace" {
    model {
        user = person "User"
        system = softwareSystem "System" {
            user -> system "Uses"
        }
    }
    views {
        systemContext system "Context" {
            include *
            autolayout lr
        }
    }
}
EOF

cleanup() {
    local status=$?
    docker compose logs --no-color > "$SCREENSHOT_DIR/compose.log.txt" 2>&1 || true
    if [ "${KEEP:-0}" != "1" ]; then
        docker compose down -v >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

echo "== Запуск web-ide"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    docker compose up -d
else
    docker compose up -d --build
fi

"${ROOT}/scripts/smoke-http.sh"

if [ "${SKIP_UI:-0}" = "1" ]; then
    echo "== UI-смоук пропущен (SKIP_UI=1)"
else
    if [ ! -d "${ROOT}/scripts/node_modules/puppeteer-core" ]; then
        echo "== Установка puppeteer-core"
        if [ -f "${ROOT}/scripts/package-lock.json" ]; then
            npm ci --prefix "${ROOT}/scripts" --no-audit --no-fund --loglevel=error
        else
            npm install --prefix "${ROOT}/scripts" --no-audit --no-fund --loglevel=error
        fi
    fi
    echo "== UI-смоук"
    node "${ROOT}/scripts/ui-smoke.mjs"
fi

if [ "${SKIP_PERSISTENCE:-0}" = "1" ]; then
    echo "== Проверка персистентности расширений пропущена (SKIP_PERSISTENCE=1)"
else
    "${ROOT}/scripts/smoke-persistence.sh"
fi
