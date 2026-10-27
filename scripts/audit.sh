#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
port="$(sudo sshd -T | awk '/^port/{print $2}')"
check "Порт SSH отличен от 22" "yes" "$([[ "$port" != "22" ]] && echo yes || echo no)"
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика входящего трафика: deny" "deny" \
    "$(sudo ufw status verbose | grep Default | sed -E 's/.*: ([a-z]+) \(incoming\).*/\1/')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Сертификат действителен не менее ${CERT_MIN_DAYS} дн." "0" \
    "$(openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in /etc/ssl/certs/devops.crt >/dev/null; echo $?)"
check "Нет файлов с записью для всех, права ключа 600" "0 600" \
    "$(find /var/www/devops-site -perm -o+w | wc -l) $(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
check "Порты 5000 и 5432 слушаются только на 127.0.0.1" "0" \
    "$(ss -tln | awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/' | wc -l)"
check "Права файла ~/app/.env равны 600" "600" "$(stat -c '%a' ~/app/.env)"

echo "[6] Контрольная работа № 2"
KR2_DIR=~/kr2
check "Контейнер redis в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose --project-directory "$KR2_DIR" ps -q redis)" 2>/dev/null)"
check "Порт 8001 опубликован только на 127.0.0.1" "127.0.0.1:8001" \
    "$(docker compose --project-directory "$KR2_DIR" port app 8001 2>/dev/null)"
check "Права файла ~/kr2/.env равны 600" "600" "$(stat -c '%a' "$KR2_DIR/.env")"
check "Сертификат kr2.crt действителен не менее 30 дн." "0" \
    "$(openssl x509 -checkend $((30 * 86400)) -noout -in /etc/ssl/certs/kr2.crt >/dev/null; echo $?)"
check "Ресурс kr2 активирован в sites-enabled" "yes" \
    "$([[ -L /etc/nginx/sites-enabled/kr2 ]] && echo yes || echo no)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
