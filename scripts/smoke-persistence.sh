#!/usr/bin/env bash
# Проверяет механизм сохранения обновлённого расширения через монтаж
# ./vscode-extensions -> /home/vscode/.local/share/code-server/extensions.
#
# Сценарий:
#   1. каталог расширений смонтирован read-write с хоста;
#   2. «обновляем» расширение внутри контейнера (новая версия в смонтированном каталоге);
#   3. новая версия появилась на хосте;
#   4. после перезапуска контейнера используется именно она, а не запечённая в образе.
#
# Папка vscode-extensions после теста восстанавливается из бэкапа.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONTAINER="${CONTAINER:-web-ide}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8088}"
EXT_DIR="/home/vscode/.local/share/code-server/extensions"
HOST_EXT_DIR="${ROOT}/vscode-extensions"
FAKE_VERSION="${FAKE_VERSION:-9.9.9}"
PASSWORD="${PASSWORD:-}"

: "${PASSWORD:?PASSWORD is required}"

BASE_VERSION="$(python3 -c "import json; print(json.load(open('${HOST_EXT_DIR}/extensions.json'))[0]['version'])")"
BACKUP_DIR="$(mktemp -d)"
MAX_WAIT="${MAX_WAIT:-120}"

pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1" >&2
    docker logs "$CONTAINER" 2>&1 | tail -30 >&2 || true
    exit 1
}

cleanup() {
    local status=$?
    restore_folder
    rm -rf "$BACKUP_DIR"
    exit "$status"
}

restore_folder() {
    [ -n "${RESTORED:-}" ] && return 0
    if [ -f "${BACKUP_DIR}/backup.tar" ]; then
        rm -rf "$HOST_EXT_DIR"
        tar -C "$ROOT" -xf "${BACKUP_DIR}/backup.tar"
    fi
    RESTORED=1
}

trap cleanup EXIT

wait_healthy() {
    local code=""
    for _ in $(seq 1 "$MAX_WAIT"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || true)"
        [ "$code" = "200" ] && return 0
        sleep 2
    done
    return 1
}

echo "== Персистентность расширений: ${BASE_VERSION} -> ${FAKE_VERSION}"

tar -C "$ROOT" -cf "${BACKUP_DIR}/backup.tar" vscode-extensions
BACKUP_SUM="$(cd "$ROOT" && find vscode-extensions -type f -exec md5sum {} + | sort | md5sum)"

# 1. Каталог расширений — это rw-монтаж с хоста.
docker exec "$CONTAINER" sh -c "echo probe > '${EXT_DIR}/.mount-probe'" \
    || fail "не удалось записать в ${EXT_DIR}"
[ -f "${HOST_EXT_DIR}/.mount-probe" ] || fail "файл из контейнера не появился на хосте — каталог расширений не смонтирован"
rm -f "${HOST_EXT_DIR}/.mount-probe"
pass "каталог расширений смонтирован read-write с хоста"

# 2. Эмулируем обновление расширения внутри контейнера: новая версия в смонтированном каталоге.
docker exec -i "$CONTAINER" python3 - "$BASE_VERSION" "$FAKE_VERSION" <<'PY'
import json, os, shutil, sys, time

base, fake = sys.argv[1], sys.argv[2]
ext_dir = "/home/vscode/.local/share/code-server/extensions"
manifest = os.path.join(ext_dir, "extensions.json")
old_rel = f"vimpelcom.c4-varp-{base}-universal"
new_rel = f"vimpelcom.c4-varp-{fake}-universal"

shutil.rmtree(os.path.join(ext_dir, new_rel), ignore_errors=True)
shutil.copytree(os.path.join(ext_dir, old_rel), os.path.join(ext_dir, new_rel))

pkg_path = os.path.join(ext_dir, new_rel, "package.json")
with open(pkg_path) as fh:
    pkg = json.load(fh)
pkg["version"] = fake
with open(pkg_path, "w") as fh:
    json.dump(pkg, fh, indent=2)

with open(manifest) as fh:
    entries = json.load(fh)
entry = entries[0]
entry["version"] = fake
entry["relativeLocation"] = new_rel
for key in ("fsPath", "path"):
    entry["location"][key] = os.path.join(ext_dir, new_rel)
entry["location"]["external"] = "file://" + os.path.join(ext_dir, new_rel)
entry["metadata"]["installedTimestamp"] = int(time.time() * 1000)
entry["metadata"]["updated"] = True
with open(manifest, "w") as fh:
    json.dump(entries, fh)
print(f"installed fake version {fake} into {ext_dir}")
PY
pass "в контейнере установлена версия ${FAKE_VERSION}"

# 3. Обновление осело на хосте.
[ -d "${HOST_EXT_DIR}/vimpelcom.c4-varp-${FAKE_VERSION}-universal" ] \
    || fail "версия ${FAKE_VERSION} не появилась в ${HOST_EXT_DIR}"
pass "новая версия сохранилась на хосте"

# 4. После перезапуска контейнера используется обновлённая версия, а не запечённая в образе.
docker restart "$CONTAINER" >/dev/null 2>&1 || fail "не удалось перезапустить контейнер ${CONTAINER}"
wait_healthy || fail "code-server не поднялся после перезапуска"

installed="$(docker exec "$CONTAINER" code-server --list-extensions --show-versions)"
printf '%s' "$installed" | grep -qx "vimpelcom.c4-varp@${FAKE_VERSION}" \
    || fail "после перезапуска версия ${FAKE_VERSION} не активна, список: ${installed}"
pass "после перезапуска активна версия ${FAKE_VERSION}"

docker logs "$CONTAINER" 2>&1 | tail -50 | grep -q "уже содержит расширения, пропускаем копирование" \
    || fail "entrypoint не увидел смонтированные расширения (перезаписал их запечёнными?)"
pass "entrypoint не перезаписал смонтированные расширения"

# 5. Расширение всё ещё видно и работает после перезапуска.
for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || true)"
    [ "$code" = "200" ] && break
    sleep 1
done
[ "$code" = "200" ] || fail "healthz не 200 после перезапуска"
pass "/healthz = 200 после перезапуска"

# 6. Восстановление исходного состояния папки.
restore_folder
restored_sum="$(cd "$ROOT" && find vscode-extensions -type f -exec md5sum {} + | sort | md5sum)"
[ "$restored_sum" = "$BACKUP_SUM" ] || fail "папка расширений не восстановлена (md5 не совпадает)"
pass "исходная папка расширений восстановлена"

echo "== Проверка персистентности пройдена"
