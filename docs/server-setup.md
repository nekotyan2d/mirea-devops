# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины

- Гипервизор: VMware Workstation, ОС: Ubuntu Server 24.04 LTS (64-bit)
- Оперативная память: 4 ГБ, процессор: 2 ядра, диск: 20 ГБ (LVM, корневой раздел 9,8 ГБ)
- Имя узла: `devops-vm`, FQDN: `devops-vm.devops.local`
  (`hostnamectl set-hostname devops-vm`, в `/etc/hosts` строка `127.0.1.1 devops-vm.devops.local devops-vm`)
- Дополнительно установлены пакеты: `ufw`, `rsync`, `rsyslog` (нужен для `/var/log/ufw.log` и `auth.log`)

## 2. Сетевые интерфейсы

| Интерфейс | Тип адаптера | Адрес | Назначение |
|-----------|--------------|-------|------------|
| ens33 | NAT (vmnet8) | 192.168.50.128/24 (DHCP) | выход в Интернет, пакеты |
| ens37 | Host-only (vmnet1) | 192.168.73.128/24 (DHCP) | доступ с хоста: `devops.local`, веб-сервер |

Второй интерфейс включён файлом `/etc/netplan/60-hostonly.yaml` (`ens37: dhcp4: true`), применено `netplan apply`.
На хосте в `C:\Windows\System32\drivers\etc\hosts` добавлена запись `192.168.73.128   devops.local`.

## 3. Правило проброса портов

Virtual Network Editor → vmnet8 → NAT Settings → Port Forwarding:
порт хоста `2222` (TCP) → `192.168.50.128:2222` (описание `ssh`).
Подключение с хоста: `ssh devops` (`127.0.0.1:2222`).

## 4. Учётные записи

| Пользователь | Группы | Аутентификация |
|--------------|--------|----------------|
| serv1 | sudo (создан при установке ОС) | по паролю локально; по SSH запрещён (`AllowUsers`) |
| devops | sudo, users | по ключу ed25519 (`~/.ssh/devops_vm` на хосте) |

Создание: `adduser --disabled-password devops`, `usermod -aG sudo devops`.
Ключ: `/home/devops/.ssh/authorized_keys` (права 600), каталог `.ssh` — 700.
Для автоматизации задано `sudo` без пароля: `/etc/sudoers.d/99-devops` (`devops ALL=(ALL) NOPASSWD:ALL`).

## 5. Служба SSH

- Файл конфигурации: `/etc/ssh/sshd_config.d/99-hardening.conf` (основной `sshd_config` не изменялся, копия — `sshd_config.backup`)
- Директивы: `Port 2222`, `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`,
  `PermitEmptyPasswords no`, `MaxAuthTries 3`, `LoginGraceTime 30`, `AllowUsers devops`,
  `X11Forwarding no`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`
- Активация по сокету отключена: `systemctl disable --now ssh.socket`, `systemctl enable --now ssh.service`
- Проверка: `sudo sshd -t`, действующие значения — `sudo sshd -T`, порт — `sudo ss -tlnp | grep sshd`

## 6. Правила межсетевого экрана

Политики: `default deny incoming`, `default allow outgoing`; журналирование `ufw logging medium`.

| Правило | Назначение |
|---------|------------|
| `limit 2222/tcp` | SSH с ограничением частоты (6 соединений за 30 с) |
| `allow 80/tcp` | HTTP |
| `allow 443/tcp` | HTTPS |

Порядок: разрешающие правила добавлены до `ufw enable`.

## 7. Снимки состояния

| Наименование | Момент создания |
|--------------|-----------------|
| 01-clean-install | после установки ОС, до настройки |
| 02-keys-configured | после создания пользователя devops и настройки ключей |
| 03-ssh-hardened | после усиления SSH, настройки UFW и имени узла |
| 04-nginx-https | после настройки Nginx и перевода ресурса на HTTPS |
| 05-docker-compose | после запуска проекта «приложение + СУБД» в Docker Compose |

## 8. Веб-сервер

- Пакет: `nginx` (apt, версия 1.24.0 из репозитория Ubuntu)
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, активирована ссылкой в `sites-enabled/`; стандартный ресурс `default` отключён (удалена ссылка)
- Блок 1: `listen 80`, `server_name devops.local`, `return 301 https://$host$request_uri`; блок 2: `listen 443 ssl`, `ssl_protocols TLSv1.2 TLSv1.3`, `try_files $uri $uri/ =404`, `error_page 404 /404.html`
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, права `755` (каталог) и `644` (файлы); содержимое доставляется `scripts/deploy.sh` (`rsync --delete --chmod=D755,F644`)
- Сертификат: `/etc/ssl/certs/devops.crt` (644, владелец root); закрытый ключ: `/etc/ssl/private/devops.key` (600, владелец root)
- Команда формирования: `openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"`; срок действия – 365 дней (самоподписанный, SAN `DNS:devops.local`)
- Журналы: `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log`
- Применение конфигурации: `sudo nginx -t && sudo systemctl reload nginx`

## 9. Контейнеризация

- Docker Engine 28.5.1 установлен из официального репозитория Docker (пакеты `docker-ce`, `docker-compose-plugin` 2.40.3); пакет `docker.io` не используется
- Участники группы `docker`: `devops` (членство даёт права, фактически равные `root`)
- Проект на сервере: `/home/devops/app` (доставка `rsync -avz --delete --exclude=.env --chmod=D755,F644 app/ devops:app/`)
- Файл `.env`: `/home/devops/app/.env`, права `600`, владелец `devops`; в репозиторий не включается (`.gitignore`), шаблон – `app/.env.example`
- Публикуемые порты: `127.0.0.1:5000` -> 5000 (приложение); порт СУБД 5432 не публикуется, приложение обращается к `db` через сеть проекта `app_backend`
- Именованные тома: `app_db_data` (`/var/lib/postgresql/data`)
- Обратный прокси: в блоке HTTPS файла `/etc/nginx/sites-available/devops-site` добавлен `location /app/` с `proxy_pass http://127.0.0.1:5000/` и заголовками `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`; статический ресурс сохранён

