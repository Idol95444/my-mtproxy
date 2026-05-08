#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# manage.sh — установщик и менеджер MTProto-прокси с TUI (whiptail)
# Использование: sudo bash manage.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE=""
SSH_PORT="22"
BT="MTProto Proxy Manager"

# ============ HELPERS ============

ensure_root() {
    [[ $EUID -eq 0 ]] || { echo "Запусти от root: sudo bash manage.sh"; exit 1; }
}

ensure_deps() {
    local need=()
    command -v whiptail >/dev/null 2>&1 || need+=(whiptail)
    command -v ss >/dev/null 2>&1 || need+=(iproute2)
    command -v xxd >/dev/null 2>&1 || need+=(xxd)
    command -v dig >/dev/null 2>&1 || need+=(dnsutils)
    command -v less >/dev/null 2>&1 || need+=(less)
    if [[ ${#need[@]} -gt 0 ]]; then
        echo "Устанавливаю зависимости: ${need[*]}"
        apt update >/dev/null 2>&1
        apt install -y "${need[@]}" >/dev/null 2>&1
    fi
}

detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE="docker-compose"
    else
        COMPOSE=""
    fi
}

detect_ssh_port() {
    local port
    port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT="${port:-22}"
}

# ============ WHIPTAIL WRAPPERS ============

w_msg() {
    whiptail --backtitle "$BT" --title "$1" --msgbox "$2" "${3:-12}" "${4:-70}"
}

w_yesno() {
    whiptail --backtitle "$BT" --title "$1" --yesno "$2" "${3:-10}" "${4:-70}"
}

w_input() {
    whiptail --backtitle "$BT" --title "$1" --inputbox "$2" 10 70 "${3:-}" 3>&1 1>&2 2>&3
}

w_menu() {
    local title="$1" prompt="$2"
    shift 2
    whiptail --backtitle "$BT" --title "$title" --menu "$prompt" 20 70 10 "$@" 3>&1 1>&2 2>&3
}

w_scroll() {
    # Показать файл с прокруткой через less
    clear
    echo "=== $1 ==="
    echo "(нажми q для выхода)"
    echo ""
    sleep 1
    less -R "$2"
}

# ============ DEPLOY MODULE ============

mod_deploy() {
    local DOMAIN BASE_SECRET AD_TAG existing_domain="" existing_secret="" existing_tag=""

    if [[ -f .env ]]; then
        # shellcheck source=/dev/null
        source .env
        existing_domain="${DOMAIN:-}"
        existing_secret="${BASE_SECRET:-}"
        existing_tag="${AD_TAG:-}"
    fi

    DOMAIN=$(w_input "Установка прокси (1/3)" "Введи домен (с A-записью на этот VPS):" "$existing_domain") || return
    [[ -z "$DOMAIN" ]] && { w_msg "Ошибка" "DOMAIN не может быть пустым"; return; }

    BASE_SECRET=$(w_input "Установка прокси (2/3)" "Базовый секрет (32 hex-символа).\nОставь пустым — сгенерирую автоматически." "$existing_secret") || return

    if [[ -z "$BASE_SECRET" ]]; then
        BASE_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        w_msg "Сгенерирован секрет" "Базовый секрет:\n\n${BASE_SECRET}\n\nСохрани — пригодится для @MTProxybot." 12
    elif ! [[ "$BASE_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        w_msg "Ошибка" "BASE_SECRET должен быть ровно 32 hex-символа (0-9, a-f)"
        return
    fi

    AD_TAG=$(w_input "Установка прокси (3/3)" "AD_TAG (необязательно).\nПолучи его в @MTProxybot через /newproxy.\nМожно пропустить и добавить позже." "$existing_tag") || return

    # DNS-проверка
    local resolved
    resolved=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
    if [[ -z "$resolved" ]]; then
        w_yesno "DNS" "Домен ${DOMAIN} не резолвится.\n\nA-запись точно настроена?\nПродолжить всё равно?" || return
    fi

    # Сохраняем .env
    cat > .env <<EOF
DOMAIN=$DOMAIN
BASE_SECRET=$BASE_SECRET
AD_TAG=${AD_TAG:-}
EOF
    chmod 600 .env

    # Установка с прогрессом
    (
        echo "5"; echo "# Обновляю apt..."
        apt update >/dev/null 2>&1 || true

        echo "15"; echo "# Устанавливаю Docker (если нужно)..."
        if ! command -v docker &>/dev/null; then
            apt install -y docker.io git curl >/dev/null 2>&1
            systemctl enable --now docker >/dev/null 2>&1
        fi
        if docker compose version &>/dev/null; then :;
        elif docker-compose version &>/dev/null; then :;
        else
            apt install -y docker-compose-v2 >/dev/null 2>&1 || apt install -y docker-compose >/dev/null 2>&1
        fi

        echo "35"; echo "# Клонирую alexbers/mtprotoproxy..."
        if [[ -d src/.git ]]; then
            git -C src pull >/dev/null 2>&1
        else
            rm -rf src
            git clone -b stable https://github.com/alexbers/mtprotoproxy.git src >/dev/null 2>&1
        fi

        echo "50"; echo "# Генерирую конфиги..."
        sed "s/__DOMAIN__/$DOMAIN/g" Caddyfile.template > Caddyfile
        if [[ -n "$AD_TAG" ]]; then
            sed -e "s/__DOMAIN__/$DOMAIN/g" \
                -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                -e "s/# AD_TAG = \"__AD_TAG__\"/AD_TAG = \"$AD_TAG\"/g" \
                config.py.template > config.py
        else
            sed -e "s/__DOMAIN__/$DOMAIN/g" \
                -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                config.py.template > config.py
        fi
        chmod 600 config.py

        echo "65"; echo "# Запускаю Caddy (получение LE-сертификата)..."
        detect_compose
        $COMPOSE up -d caddy >/dev/null 2>&1
        sleep 15

        echo "85"; echo "# Запускаю alexbers..."
        $COMPOSE up -d --build alexbers >/dev/null 2>&1
        sleep 5

        echo "100"; echo "# Готово!"
        sleep 1
    ) | whiptail --backtitle "$BT" --title "Установка" --gauge "Запускаю..." 8 70 0

    # Финальная ссылка
    local hex_domain link
    hex_domain=$(echo -n "$DOMAIN" | xxd -ps | tr -d '\n')
    link="https://t.me/proxy?server=${DOMAIN}&port=853&secret=ee${BASE_SECRET}${hex_domain}"

    w_msg "Установка завершена" "FakeTLS-ссылка:\n\n${link}\n\n\
Что осталось вручную в Telegram:\n\
1. @MTProxybot → /newproxy\n\
2. Введи: ${DOMAIN}:853\n\
3. Введи секрет: ${BASE_SECRET}\n\
4. Сохрани AD_TAG из ответа бота\n\
5. /myproxies → выбери прокси → Set promoted channel → @канал\n\
6. Вернись в это меню → Установить прокси, впиши AD_TAG" 22
}

# ============ SECURITY MODULE ============

mod_security() {
    detect_ssh_port

    w_yesno "Безопасность" "Запустить настройку безопасности?\n\n\
SSH-порт обнаружен: ${SSH_PORT}\n\n\
Будет:\n\
- Просканированы открытые порты\n\
- Про каждый незнакомый порт спросим\n\
- Настроен файрвол ufw\n\
- Установлен fail2ban\n\
- Включены автообновления\n\
- Применены sysctl-настройки" 18 || return

    # Сканируем порты
    local listening_ports=()
    while IFS= read -r line; do
        local port
        port=$(echo "$line" | awk '{print $4}' | awk -F: '{print $NF}')
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && listening_ports+=("$port")
    done < <(ss -tln 2>/dev/null | tail -n +2)

    local unique_ports
    unique_ports=$(printf '%s\n' "${listening_ports[@]}" | sort -un)

    # Whitelist
    local whitelist=("$SSH_PORT" 80 443 853)
    is_whitelisted() {
        local p="$1"
        for wp in "${whitelist[@]}"; do
            [[ "$p" == "$wp" ]] && return 0
        done
        return 1
    }

    # Спрашиваем про каждый незнакомый порт
    local extra_open=()
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        if ! is_whitelisted "$port"; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1)
            [[ -z "$proc" ]] && proc="(неизвестно)"
            if whiptail --backtitle "$BT" --title "Незнакомый порт" \
                --yesno "Порт ${port} сейчас слушается процессом:\n\n${proc}\n\nОставить открытым в файрволе?\n\n(Нет — порт будет закрыт извне)" 13 70; then
                extra_open+=("$port")
            fi
        fi
    done <<< "$unique_ports"

    # Применяем настройки
    (
        echo "5"; echo "# Устанавливаю ufw..."
        apt install -y ufw >/dev/null 2>&1

        echo "15"; echo "# Сбрасываю старые правила..."
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1

        echo "25"; echo "# Открываю SSH (${SSH_PORT})..."
        ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1

        echo "35"; echo "# Открываю порты прокси..."
        ufw allow 80/tcp comment "Caddy HTTP" >/dev/null 2>&1
        ufw allow 443/tcp comment "Caddy HTTPS" >/dev/null 2>&1
        ufw allow 853/tcp comment "MTProto" >/dev/null 2>&1

        for port in "${extra_open[@]}"; do
            ufw allow "${port}/tcp" comment "user-allowed" >/dev/null 2>&1
        done

        echo "45"; echo "# Активирую файрвол..."
        ufw --force enable >/dev/null 2>&1

        echo "55"; echo "# Устанавливаю fail2ban..."
        apt install -y fail2ban >/dev/null 2>&1
        cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF
        systemctl enable fail2ban >/dev/null 2>&1
        systemctl restart fail2ban >/dev/null 2>&1

        echo "75"; echo "# Настраиваю автообновления..."
        apt install -y unattended-upgrades >/dev/null 2>&1
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker.io";
};
EOF
        systemctl enable unattended-upgrades >/dev/null 2>&1
        systemctl restart unattended-upgrades >/dev/null 2>&1

        echo "90"; echo "# Применяю sysctl..."
        cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
        sysctl --system >/dev/null 2>&1

        echo "100"; echo "# Готово!"
        sleep 1
    ) | whiptail --backtitle "$BT" --title "Настройка безопасности" --gauge "Применяю..." 8 70 0

    # Сводка
    local extra_str=""
    if [[ ${#extra_open[@]} -gt 0 ]]; then
        extra_str="Дополнительно открыто: ${extra_open[*]}\n"
    else
        extra_str="Дополнительные порты: нет\n"
    fi

    w_msg "Безопасность настроена" "Открытые порты:\n\
  SSH:     ${SSH_PORT}\n\
  HTTP:    80\n\
  HTTPS:   443\n\
  MTProto: 853\n\
${extra_str}\n\
fail2ban: бан 1 час после 3 попыток\n\
Автообновления: security-патчи, рестарт 04:00\n\
sysctl: защита от спуфинга, SYN-flood, MITM" 20
}

# ============ MANAGEMENT MODULE ============

mod_manage() {
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        w_msg "Ошибка" "Docker не установлен. Сначала установи прокси."
        return
    fi

    while true; do
        local choice
        choice=$(w_menu "Управление прокси" "Выбери действие:" \
            1 "Статус контейнеров" \
            2 "Логи alexbers (50 строк)" \
            3 "Логи Caddy (30 строк)" \
            4 "Перезапустить alexbers" \
            5 "Перезапустить всё" \
            6 "Остановить всё" \
            7 "Запустить всё" \
            8 "Назад") || return

        case $choice in
            1) $COMPOSE ps > /tmp/mgr.txt 2>&1; w_scroll "Статус контейнеров" /tmp/mgr.txt; rm -f /tmp/mgr.txt;;
            2) $COMPOSE logs --tail 50 alexbers > /tmp/mgr.txt 2>&1; w_scroll "Логи alexbers" /tmp/mgr.txt; rm -f /tmp/mgr.txt;;
            3) $COMPOSE logs --tail 30 caddy > /tmp/mgr.txt 2>&1; w_scroll "Логи Caddy" /tmp/mgr.txt; rm -f /tmp/mgr.txt;;
            4) $COMPOSE restart alexbers >/dev/null 2>&1; w_msg "Готово" "alexbers перезапущен";;
            5) $COMPOSE restart >/dev/null 2>&1; w_msg "Готово" "Всё перезапущено";;
            6) $COMPOSE down >/dev/null 2>&1; w_msg "Готово" "Всё остановлено";;
            7) $COMPOSE up -d >/dev/null 2>&1; w_msg "Готово" "Всё запущено";;
            8|"") return;;
        esac
    done
}

# ============ UNINSTALL MODULE ============

mod_uninstall() {
    w_yesno "Удаление" "Удалить ВСЁ?\n\n\
- Контейнеры и volumes\n\
- LE-сертификат (caddy_data)\n\
- Сгенерированные конфиги (Caddyfile, config.py)\n\
- .env\n\
- src/ (исходник alexbers)\n\n\
Шаблоны и manage.sh останутся.\n\n\
Продолжить?" 16 || return

    detect_compose
    if [[ -n "$COMPOSE" ]]; then
        $COMPOSE down -v >/dev/null 2>&1 || true
    fi
    rm -f Caddyfile config.py .env
    rm -rf src

    w_msg "Готово" "Прокси удалён.\n\nДля повторной установки — пункт 'Установить прокси'."
}

# ============ UPDATE MODULE ============

mod_update() {
    if [[ ! -d .git ]]; then
        w_msg "Ошибка" "Папка не является git-репозиторием.\n\nСкрипт обновляется только при клонировании через git."
        return
    fi

    w_yesno "Обновление" "Обновить скрипт из GitHub?\n\nЛокальные изменения скрипта могут быть перезаписаны.\nКонфиги (.env, config.py, Caddyfile) не трогаются." 12 || return

    (
        echo "20"; echo "# Получаю изменения с GitHub..."
        git fetch origin >/dev/null 2>&1

        echo "60"; echo "# Применяю обновление..."
        git reset --hard origin/main >/dev/null 2>&1

        echo "100"; echo "# Готово!"
        sleep 1
    ) | whiptail --backtitle "$BT" --title "Обновление" --gauge "Обновляю..." 8 70 0

    local current_commit
    current_commit=$(git log -1 --oneline 2>/dev/null || echo "?")

    w_msg "Обновлено" "Скрипт обновлён до последней версии.\n\nТекущий коммит:\n${current_commit}\n\nПерезапусти manage.sh чтобы изменения применились."
    clear
    exit 0
}

# ============ MAIN MENU ============

main_menu() {
    while true; do
        local choice
        choice=$(w_menu "MTProto Proxy Manager" "Выбери действие:" \
            1 "Установить прокси" \
            2 "Настроить безопасность VPS" \
            3 "Управление прокси" \
            4 "Обновить скрипт из git" \
            5 "Удалить всё" \
            6 "Выход") || { clear; exit 0; }

        case $choice in
            1) mod_deploy ;;
            2) mod_security ;;
            3) mod_manage ;;
            4) mod_update ;;
            5) mod_uninstall ;;
            6|"") clear; exit 0 ;;
        esac
    done
}

# ============ ENTRY ============

ensure_root
ensure_deps
main_menu
