#!/usr/bin/env bash
# Смоук-тест code-server: healthz, вход по паролю, установленное C4-расширение.
# Требует уже запущенный контейнер web-ide (см. scripts/smoke.sh).
#
# Переменные:
#   PASSWORD  — обязательна, пароль code-server
#   BASE_URL  — по умолчанию http://127.0.0.1:8088
#   CONTAINER — по умолчанию web-ide
#   EXPECTED_EXT_VERSION — по умолчанию берётся из vscode-extensions/extensions.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:8088}"
CONTAINER="${CONTAINER:-web-ide}"
EXPECTED_EXT_VERSION="${EXPECTED_EXT_VERSION:-$(python3 -c "import json,sys; print(json.load(open('${ROOT}/vscode-extensions/extensions.json'))[0]['version'])")}"
COOKIES="$(mktemp)"

: "${PASSWORD:?PASSWORD is required}"

pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1" >&2
    docker logs "$CONTAINER" 2>&1 | tail -40 >&2 || true
    exit 1
}
check() { # check <описание> <условие...>
    local desc="$1"; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

echo "== code-server: ${BASE_URL}"

# 1. Статический healthz (не требует авторизации).
code=""
for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || true)"
    [ "$code" = "200" ] && break
    sleep 2
done
[ "$code" = "200" ] || fail "/healthz не вернул 200 (последний код: ${code})"
pass "/healthz = 200"

# 2. Без сессии корень редиректит на страницу логина.
location="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${BASE_URL}/")"
[ "${location%% *}" = "302" ] && pass "GET / без сессии = 302" || fail "GET / без сессии: ${location}"
[[ "${location}" == *"/login"* ]] && pass "редирект ведёт на /login" || fail "редирект ведёт не на /login: ${location}"

# 3. Неверный пароль не пускает.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'password=definitely-wrong' "${BASE_URL}/login")"
[ "$code" = "200" ] && pass "неверный пароль отвергнут" || fail "неверный пароль вернул ${code} (ожидался 200 — страница логина)"

# 4. Верный пароль выдаёт сессию.
code="$(curl -s -c "$COOKIES" -o /dev/null -w '%{http_code}' -X POST --data-urlencode "password=${PASSWORD}" "${BASE_URL}/login")"
[ "$code" = "302" ] && pass "POST /login с паролем = 302" || fail "POST /login с паролем вернул ${code}"
grep -q "code-server-session" "$COOKIES" && pass "выдана сессионная cookie" || fail "сессионная cookie не выдана"

# 5. С сессией отдаётся workbench.
wb="$(curl -sL -b "$COOKIES" -w '\n%{http_code}' "${BASE_URL}/?folder=/home/vscode/workspace")"
[ "$(printf '%s' "$wb" | tail -n1)" = "200" ] && pass "workbench с сессией = 200" || fail "workbench с сессией: $(printf '%s' "$wb" | tail -n1)"
printf '%s' "$wb" | grep -q "workbench" && pass "в ответе есть бандл workbench" || fail "в ответе нет бандла workbench"

# 6. Расширение установлено и нужной версии.
installed="$(docker exec "$CONTAINER" code-server --list-extensions --show-versions)"
printf '%s' "$installed" | grep -qx "vimpelcom.c4-varp@${EXPECTED_EXT_VERSION}" \
    && pass "установлено vimpelcom.c4-varp@${EXPECTED_EXT_VERSION}" \
    || fail "ожидалось vimpelcom.c4-varp@${EXPECTED_EXT_VERSION}, получено: ${installed:-<пусто>}"

# 7. Файлы расширения на месте и не помечены устаревшими.
ext_dir="/home/vscode/.local/share/code-server/extensions"
docker exec "$CONTAINER" test -f "${ext_dir}/vimpelcom.c4-varp-${EXPECTED_EXT_VERSION}-universal/dist/extension.js" \
    && pass "файлы расширения на месте" || fail "нет dist/extension.js у расширения"
docker exec "$CONTAINER" test ! -f "${ext_dir}/.obsolete" \
    && pass "нет .obsolete" || fail "расширение помечено устаревшим (.obsolete)"

# 8. Автообновление расширений отключено в настройках.
docker exec "$CONTAINER" grep -q '"extensions.autoCheckUpdates": false' /home/vscode/.local/share/code-server/User/settings.json \
    && pass "extensions.autoCheckUpdates=false" || fail "не отключена проверка обновлений расширений"

# 9. В логах нет обращений к маркетплейсу/ошибок обновления.
if docker logs "$CONTAINER" 2>&1 | grep -qiE "error while fetching extensions|marketplace|gallery|ENOTFOUND|ECONNREFUSED"; then
    fail "в логах есть ошибки обращения к маркетплейсу/сети"
fi
pass "в логах нет обращений к маркетплейсу"

rm -f "$COOKIES"
echo "== HTTP-смоук пройден"
