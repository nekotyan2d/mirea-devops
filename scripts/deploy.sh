#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                       # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY=""
if [[ "${1:-}" == "--dry-run" ]]; then DRY="--dry-run"; fi

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: файл site/index.html не найден" >&2
    exit 1
fi
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    echo "Ошибка: в репозитории есть незафиксированные изменения" >&2
    exit 1
fi

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
rsync -az --delete --chmod=D755,F644 $DRY \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "$DRY" ]]; then
    echo "Пробный запуск завершён, сервер не изменён"
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} и завершение с корректным кодом возврата
if ! curl -fsS --max-time 10 --cacert "$CA_CERT" -o /dev/null "$SITE_URL"; then
    echo "Ошибка: ресурс ${SITE_URL} недоступен" >&2
    exit 1
fi
echo "Доставлен коммит $(git -C "$ROOT" rev-parse --short HEAD)"
