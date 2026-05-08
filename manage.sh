#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# manage.sh — установщик и менеджер MTProto-прокси
# Использование: sudo bash manage.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"

# ============ COLORS ============

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'
    C_CYN=$'\033[36m'
    C_DIM=$'\033[2m'
    C_BLD=$'\033[1m'
    C_RST=$'\033[0m'
else
    C_RED="" C_GRN="" C_YLW="" C_BLU="" C_CYN="" C_DIM="" C_BLD="" C_RST=""
fi

# ============ GLOBALS ============

COMPOSE=""
SSH_PORT="22"

# ============ HELPERS ============

require_root() {
    [[ $EUID -eq 0 ]] || {
        printf '%sЗапусти от root: sudo bash manage.sh%s\n' "$C_RED" "$C_RST"
        exit 1
    }
}

ensure_deps() {
    local need=()
    command -v ss >/dev/null 2>&1 || need+=(iproute2)
    command -v xxd >/dev/null 2>&1 || need+=(xxd)
    command -v dig >/dev/null 2>&1 || need+=(dnsutils)
    command -v git >/dev/null 2>&1 || need+=(git)
    if [[ ${#need[@]} -gt 0 ]]; then
        printf '%sУстанавливаю зависимости: %s%s\n' "$C_DIM" "${need[*]}" "$C_RST"
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

pause() {
    printf '\n%s[Enter — назад в меню]%s ' "$C_DIM" "$C_RST"
    read -r _ </dev/tty || true
}

confirm() {
    local prompt="${1:-Продолжить?}"
    local default="${2:-N}"
    local hint="[y/N]"
    [[ "$default" == "Y" ]] && hint="[Y/n]"
    printf '%s %s: ' "$prompt" "$hint"
    local ans
    read -r ans </dev/tty
    if [[ "$default" == "Y" ]]; then
        [[ "$ans" != "n" && "$ans" != "N" ]]
    else
        [[ "$ans" == "y" || "$ans" == "Y" ]]
    fi
}

prompt_value() {
    local label="$1" default="${2:-}" input
    if [[ -n "$default" ]]; then
        printf '       %s [%s]: ' "$label" "$default" >&2
    else
        printf '       %s: ' "$label" >&2
    fi
    read -r input </dev/tty
    printf '%s' "${input:-$default}"
}

ok_inline() {
    printf '%s✓ %s%s\n' "$C_GRN" "$1" "$C_RST"
}

fail_inline() {
    printf '%s✗ %s%s\n' "$C_RED" "$1" "$C_RST"
}

step() {
    printf '%s[%s]%s %s\n' "$C_CYN" "$1" "$C_RST" "$2"
}

# Проверка домена: правильный ли IP, пропагировал ли DNS, свободен ли порт 80
# Возвращает 0 если всё ОК, 1 если есть критичные ошибки.
# Печатает предупреждения но не валит на них (warnings не блокируют).
check_dns_health() {
    local domain="$1"
    local errors=0 warnings=0

    printf '\n%sПроверка DNS и доступности:%s\n' "$C_BLD" "$C_RST"

    # 1. Публичный IP этого сервера
    local server_ip
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null)
    server_ip=$(echo -n "$server_ip" | tr -d '[:space:]')
    if [[ -z "$server_ip" ]]; then
        printf '  %s✗ Не удалось определить публичный IP сервера%s\n' "$C_RED" "$C_RST"
        errors=$((errors+1))
    else
        printf '  %s✓%s Публичный IP этого VPS: %s%s%s\n' "$C_GRN" "$C_RST" "$C_BLD" "$server_ip" "$C_RST"
    fi

    # 2. A-записи через локальный резолвер
    local resolved_ips
    resolved_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
    if [[ -z "$resolved_ips" ]]; then
        printf '  %s✗%s Домен %s не резолвится — A-запись не настроена или не пропагировала\n' \
            "$C_RED" "$C_RST" "$domain"
        return 1
    fi

    local ip_count
    ip_count=$(echo "$resolved_ips" | wc -l | tr -d ' ')
    if (( ip_count > 1 )); then
        printf '  %s✗%s У домена несколько A-записей:\n' "$C_RED" "$C_RST"
        echo "$resolved_ips" | sed "s/^/      /"
        printf '      %sLet'"'"'s Encrypt проверяет ВСЕ A-записи.%s\n' "$C_YLW" "$C_RST"
        printf '      %sЕсли хоть одна не отвечает — cert не выпустится.%s\n' "$C_YLW" "$C_RST"
        printf '      %sОставь только одну запись на этот VPS.%s\n' "$C_YLW" "$C_RST"
        errors=$((errors+1))
    else
        printf '  %s✓%s A-запись (локальный DNS): %s\n' "$C_GRN" "$C_RST" "$resolved_ips"
    fi

    # 3. Совпадает ли A-запись с IP сервера
    if [[ -n "$server_ip" ]]; then
        if echo "$resolved_ips" | grep -qx "$server_ip"; then
            printf '  %s✓%s Домен указывает на этот сервер\n' "$C_GRN" "$C_RST"
        else
            printf '  %s✗%s Ни одна A-запись не указывает на этот сервер!\n' "$C_RED" "$C_RST"
            printf '      VPS: %s\n' "$server_ip"
            printf '      DNS: %s\n' "$(echo "$resolved_ips" | tr '\n' ' ')"
            errors=$((errors+1))
        fi
    fi

    # 4. Внешние DNS (Cloudflare и Google) — пропагация
    local cf_ip google_ip
    cf_ip=$(dig @1.1.1.1 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    google_ip=$(dig @8.8.8.8 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)

    if [[ -z "$cf_ip" ]]; then
        printf '  %s⚠%s Cloudflare DNS (1.1.1.1) пока не видит домен — DNS не пропагировал\n' \
            "$C_YLW" "$C_RST"
        warnings=$((warnings+1))
    elif [[ -n "$server_ip" && "$cf_ip" != "$server_ip" ]]; then
        printf '  %s⚠%s Cloudflare DNS видит другой IP: %s\n' "$C_YLW" "$C_RST" "$cf_ip"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Cloudflare DNS видит: %s\n' "$C_GRN" "$C_RST" "$cf_ip"
    fi

    if [[ -z "$google_ip" ]]; then
        printf '  %s⚠%s Google DNS (8.8.8.8) пока не видит домен\n' "$C_YLW" "$C_RST"
        warnings=$((warnings+1))
    elif [[ -n "$server_ip" && "$google_ip" != "$server_ip" ]]; then
        printf '  %s⚠%s Google DNS видит другой IP: %s\n' "$C_YLW" "$C_RST" "$google_ip"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Google DNS видит: %s\n' "$C_GRN" "$C_RST" "$google_ip"
    fi

    # 5. Порт 80 свободен (нужен Caddy для ACME-challenge)
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':80$'; then
        local port_user
        port_user=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1)
        printf '  %s⚠%s Порт 80 уже занят: %s\n' "$C_YLW" "$C_RST" "${port_user:-неизвестный процесс}"
        printf '      Если это не Caddy от прошлой попытки — может помешать LE.\n'
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Порт 80 свободен\n' "$C_GRN" "$C_RST"
    fi

    # 6. Порт 443 свободен (нужен Caddy для TLS)
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':443$'; then
        local port_user
        port_user=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/ {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1)
        printf '  %s⚠%s Порт 443 уже занят: %s\n' "$C_YLW" "$C_RST" "${port_user:-неизвестный процесс}"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Порт 443 свободен\n' "$C_GRN" "$C_RST"
    fi

    # Итог
    printf '\n'
    if (( errors > 0 )); then
        printf '  %sНайдено критичных ошибок: %d%s\n' "$C_RED" "$errors" "$C_RST"
        printf '  %sLet'"'"'s Encrypt с такими настройками cert НЕ выпустит.%s\n' "$C_RED" "$C_RST"
        return 1
    fi
    if (( warnings > 0 )); then
        printf '  %sПредупреждений: %d (не блокирует, но обрати внимание)%s\n' "$C_YLW" "$warnings" "$C_RST"
    else
        printf '  %sВсе проверки пройдены%s\n' "$C_GRN" "$C_RST"
    fi
    return 0
}

# ============ SCREEN ============

print_header() {
    clear
    cat <<HEADER
${C_CYN}${C_BLD}╔══════════════════════════════════════════════════════════╗
║          MTProto Proxy Manager — control panel           ║
╚══════════════════════════════════════════════════════════╝${C_RST}
HEADER
}

print_status() {
    detect_compose

    local domain="${C_DIM}не установлен${C_RST}"
    local proxy_state="${C_DIM}не запущен${C_RST}"
    local caddy_state="${C_DIM}не запущен${C_RST}"
    local ad_tag_state="${C_DIM}нет${C_RST}"
    local ufw_state="${C_DIM}не настроен${C_RST}"

    if [[ -f .env ]]; then
        local DOMAIN="" AD_TAG=""
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        [[ -n "${DOMAIN:-}" ]] && domain="$DOMAIN"
        [[ -n "${AD_TAG:-}" ]] && ad_tag_state="${C_GRN}настроен${C_RST}"
    fi

    if [[ -n "$COMPOSE" && -f docker-compose.yml ]]; then
        if $COMPOSE ps --status running 2>/dev/null | grep -q "mtproto-final"; then
            proxy_state="${C_GRN}запущен${C_RST}"
        else
            proxy_state="${C_YLW}остановлен${C_RST}"
        fi
        if $COMPOSE ps --status running 2>/dev/null | grep -q "mtproxy-caddy"; then
            caddy_state="${C_GRN}запущен${C_RST}"
        else
            caddy_state="${C_YLW}остановлен${C_RST}"
        fi
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw_state="${C_GRN}активен${C_RST}"
        else
            ufw_state="${C_YLW}неактивен${C_RST}"
        fi
    fi

    cat <<STATUS

  ${C_BLD}Домен:${C_RST}      ${domain}
  ${C_BLD}alexbers:${C_RST}   ${proxy_state}    ${C_DIM}(порт 853)${C_RST}
  ${C_BLD}Caddy:${C_RST}      ${caddy_state}    ${C_DIM}(порт 80, 443)${C_RST}
  ${C_BLD}AD_TAG:${C_RST}     ${ad_tag_state}
  ${C_BLD}Файрвол:${C_RST}    ${ufw_state}

STATUS
}

print_menu() {
    cat <<MENU
${C_BLD}═══ УСТАНОВКА ═══${C_RST}
  ${C_CYN}1)${C_RST} Установить прокси            ${C_DIM}(домен, секрет, AD_TAG)${C_RST}
  ${C_CYN}2)${C_RST} Настроить безопасность VPS   ${C_DIM}(ufw, fail2ban, sysctl)${C_RST}

${C_BLD}═══ УПРАВЛЕНИЕ ═══${C_RST}
  ${C_CYN}3)${C_RST} Статус контейнеров
  ${C_CYN}4)${C_RST} Логи alexbers                ${C_DIM}(live, Ctrl+C — выход)${C_RST}
  ${C_CYN}5)${C_RST} Логи Caddy                   ${C_DIM}(live, Ctrl+C — выход)${C_RST}
  ${C_CYN}6)${C_RST} Перезапустить прокси
  ${C_CYN}7)${C_RST} Остановить всё
  ${C_CYN}8)${C_RST} Запустить всё
  ${C_CYN}9)${C_RST} Показать ссылку для пользователей

${C_BLD}═══ ОБСЛУЖИВАНИЕ ═══${C_RST}
  ${C_CYN}10)${C_RST} Обновить скрипт из git
  ${C_CYN}11)${C_RST} Удалить прокси

  ${C_DIM}0) Выход${C_RST}

MENU
}

# ============ ACTIONS: DEPLOY ============

action_deploy() {
    print_header
    printf '%s═══ Установка прокси ═══%s\n\n' "$C_BLD" "$C_RST"

    local DOMAIN="" BASE_SECRET="" AD_TAG=""
    if [[ -f .env ]]; then
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
    fi

    step "1/3" "Домен (с A-записью на этот VPS)"
    DOMAIN=$(prompt_value "Введи домен" "$DOMAIN")
    if [[ -z "$DOMAIN" ]]; then
        fail_inline "DOMAIN не может быть пустым"
        pause; return
    fi
    printf '\n'

    step "2/3" "Базовый секрет (32 hex-символа, пусто — сгенерирую)"
    BASE_SECRET=$(prompt_value "Секрет" "$BASE_SECRET")
    if [[ -z "$BASE_SECRET" ]]; then
        BASE_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        ok_inline "Сгенерирован: ${BASE_SECRET}"
    elif ! [[ "$BASE_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        fail_inline "BASE_SECRET должен быть 32 hex-символа (0-9, a-f)"
        pause; return
    fi
    printf '\n'

    step "3/3" "AD_TAG (необязательно, можно вписать позже)"
    printf '       Получи в @MTProxybot через /newproxy\n'
    AD_TAG=$(prompt_value "AD_TAG" "$AD_TAG")
    printf '\n'

    # Развёрнутая проверка DNS, IP, портов
    if ! check_dns_health "$DOMAIN"; then
        printf '\n'
        if ! confirm "Продолжить несмотря на ошибки?" N; then
            return
        fi
    fi

    printf '\n%sИтого:%s\n' "$C_BLD" "$C_RST"
    printf '  Домен:    %s\n' "$DOMAIN"
    printf '  Секрет:   %s\n' "$BASE_SECRET"
    printf '  AD_TAG:   %s\n\n' "${AD_TAG:-(пусто)}"

    if ! confirm "Запустить установку?" Y; then
        return
    fi

    # Сохраняем .env
    cat > .env <<EOF
DOMAIN=$DOMAIN
BASE_SECRET=$BASE_SECRET
AD_TAG=${AD_TAG:-}
EOF
    chmod 600 .env

    printf '\n%sУстановка:%s\n' "$C_BLD" "$C_RST"

    printf '  Обновляю apt... '
    apt update >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    if ! command -v docker &>/dev/null; then
        printf '  Устанавливаю Docker... '
        apt install -y docker.io git curl >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '  Docker: %sуже установлен%s\n' "$C_DIM" "$C_RST"
    fi

    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        printf '  Устанавливаю docker-compose... '
        apt install -y docker-compose-v2 >/dev/null 2>&1 || apt install -y docker-compose >/dev/null 2>&1
        detect_compose
        printf '%sok%s (%s)\n' "$C_GRN" "$C_RST" "$COMPOSE"
    else
        printf '  Compose: %s%s%s\n' "$C_DIM" "$COMPOSE" "$C_RST"
    fi

    if [[ -d src/.git ]]; then
        printf '  Обновляю alexbers/mtprotoproxy... '
        git -C src pull >/dev/null 2>&1
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '  Клонирую alexbers/mtprotoproxy... '
        rm -rf src
        git clone -b stable https://github.com/alexbers/mtprotoproxy.git src >/dev/null 2>&1
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    fi

    printf '  Генерирую конфиги... '
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
    chmod 644 config.py
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Запускаю Caddy (получение LE-сертификата)'
    $COMPOSE up -d caddy >/dev/null 2>&1
    local i=0
    while (( i < 20 )); do
        sleep 1
        i=$((i+1))
        printf '.'
    done
    printf ' %sok%s\n' "$C_GRN" "$C_RST"

    printf '  Запускаю alexbers... '
    $COMPOSE up -d --build alexbers >/dev/null 2>&1
    sleep 5
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    local hex_domain link
    hex_domain=$(echo -n "$DOMAIN" | xxd -ps | tr -d '\n')
    link="https://t.me/proxy?server=${DOMAIN}&port=853&secret=ee${BASE_SECRET}${hex_domain}"

    printf '\n%s═══ Готово ═══%s\n\n' "$C_GRN$C_BLD" "$C_RST"
    printf '%sFakeTLS-ссылка:%s\n%s\n\n' "$C_BLD" "$C_RST" "$link"

    printf '%sЧто осталось вручную:%s\n' "$C_BLD" "$C_RST"
    printf '  1. @MTProxybot → /newproxy\n'
    printf '  2. Введи: %s:853\n' "$DOMAIN"
    printf '  3. Введи секрет: %s\n' "$BASE_SECRET"
    printf '  4. Сохрани AD_TAG из ответа бота\n'
    printf '  5. /myproxies → выбери прокси → Set promoted channel → @канал\n'
    printf '  6. Вернись сюда → Установить прокси, впиши AD_TAG\n'

    pause
}

# ============ ACTIONS: SECURITY ============

action_security() {
    print_header
    printf '%s═══ Настройка безопасности ═══%s\n\n' "$C_BLD" "$C_RST"

    detect_ssh_port

    printf 'SSH-порт обнаружен: %s%s%s\n\n' "$C_BLD" "$SSH_PORT" "$C_RST"
    printf 'Будет:\n'
    printf '  • просканированы открытые порты\n'
    printf '  • про каждый незнакомый порт спросим\n'
    printf '  • настроен файрвол ufw\n'
    printf '  • установлен fail2ban\n'
    printf '  • включены автообновления безопасности\n'
    printf '  • применены sysctl-настройки\n\n'

    if ! confirm "Запустить?" Y; then
        return
    fi

    printf '\n%sСканирую открытые порты...%s\n' "$C_DIM" "$C_RST"
    local listening_ports=()
    while IFS= read -r line; do
        local port
        port=$(echo "$line" | awk '{print $4}' | awk -F: '{print $NF}')
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && listening_ports+=("$port")
    done < <(ss -tln 2>/dev/null | tail -n +2)

    local unique_ports
    unique_ports=$(printf '%s\n' "${listening_ports[@]}" | sort -un)

    local whitelist=("$SSH_PORT" 80 443 853)
    is_whitelisted() {
        local p="$1"
        for wp in "${whitelist[@]}"; do
            [[ "$p" == "$wp" ]] && return 0
        done
        return 1
    }

    local extra_open=()
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        if ! is_whitelisted "$port"; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1)
            [[ -z "$proc" ]] && proc="(неизвестно)"
            printf '\n%sПорт %s%s слушается процессом:\n' "$C_YLW" "$port" "$C_RST"
            printf '  %s\n' "$proc"
            if confirm "Оставить открытым в файрволе?" N; then
                extra_open+=("$port")
            fi
        fi
    done <<< "$unique_ports"

    printf '\n%sПрименяю настройки:%s\n' "$C_BLD" "$C_RST"

    printf '  Устанавливаю ufw... '
    apt install -y ufw >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Сбрасываю старые правила... '
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Открываю порты: '
    ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1
    ufw allow 80/tcp comment "Caddy HTTP" >/dev/null 2>&1
    ufw allow 443/tcp comment "Caddy HTTPS" >/dev/null 2>&1
    ufw allow 853/tcp comment "MTProto" >/dev/null 2>&1
    for port in "${extra_open[@]}"; do
        ufw allow "${port}/tcp" comment "user-allowed" >/dev/null 2>&1
    done
    printf '%s%s 80 443 853%s' "$C_CYN" "$SSH_PORT" "$C_RST"
    if [[ ${#extra_open[@]} -gt 0 ]]; then
        printf ' %s+ %s%s' "$C_CYN" "${extra_open[*]}" "$C_RST"
    fi
    printf ' %sok%s\n' "$C_GRN" "$C_RST"

    printf '  Активирую файрвол... '
    ufw --force enable >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Устанавливаю fail2ban... '
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
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Настраиваю автообновления... '
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
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Применяю sysctl-настройки... '
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
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '\n%s═══ Готово ═══%s\n' "$C_GRN$C_BLD" "$C_RST"
    pause
}

# ============ ACTIONS: MANAGEMENT ============

action_status() {
    print_header
    printf '%s═══ Статус контейнеров ═══%s\n\n' "$C_BLD" "$C_RST"
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        fail_inline "Docker не установлен"
    else
        $COMPOSE ps 2>&1 || true
    fi
    pause
}

action_logs_alexbers() {
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        print_header
        fail_inline "Docker не установлен"
        pause; return
    fi
    print_header
    printf '%s═══ Логи alexbers (live, Ctrl+C — выход) ═══%s\n\n' "$C_BLD" "$C_RST"
    trap 'true' INT
    $COMPOSE logs --tail 50 -f alexbers || true
    trap - INT
    pause
}

action_logs_caddy() {
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        print_header
        fail_inline "Docker не установлен"
        pause; return
    fi
    print_header
    printf '%s═══ Логи Caddy (live, Ctrl+C — выход) ═══%s\n\n' "$C_BLD" "$C_RST"
    trap 'true' INT
    $COMPOSE logs --tail 30 -f caddy || true
    trap - INT
    pause
}

action_restart() {
    print_header
    printf '%s═══ Перезапуск ═══%s\n\n' "$C_BLD" "$C_RST"
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        fail_inline "Docker не установлен"
        pause; return
    fi
    printf 'Перезапускаю контейнеры... '
    $COMPOSE restart >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"
    pause
}

action_stop() {
    print_header
    printf '%s═══ Остановка ═══%s\n\n' "$C_BLD" "$C_RST"
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        fail_inline "Docker не установлен"
        pause; return
    fi
    printf 'Останавливаю всё... '
    $COMPOSE down >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"
    pause
}

action_start() {
    print_header
    printf '%s═══ Запуск ═══%s\n\n' "$C_BLD" "$C_RST"
    detect_compose
    if [[ -z "$COMPOSE" ]]; then
        fail_inline "Docker не установлен"
        pause; return
    fi
    printf 'Запускаю всё... '
    $COMPOSE up -d >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"
    pause
}

action_show_link() {
    print_header
    printf '%s═══ FakeTLS-ссылка для пользователей ═══%s\n\n' "$C_BLD" "$C_RST"
    if [[ ! -f .env ]]; then
        fail_inline ".env не найден. Сначала установи прокси."
        pause; return
    fi

    local DOMAIN="" BASE_SECRET=""
    # shellcheck source=/dev/null
    source .env

    if [[ -z "$DOMAIN" || -z "$BASE_SECRET" ]]; then
        fail_inline "В .env нет DOMAIN или BASE_SECRET"
        pause; return
    fi

    local hex_domain link
    hex_domain=$(echo -n "$DOMAIN" | xxd -ps | tr -d '\n')
    link="https://t.me/proxy?server=${DOMAIN}&port=853&secret=ee${BASE_SECRET}${hex_domain}"

    printf '%s%s%s\n\n' "$C_BLD" "$link" "$C_RST"
    printf '%sРаздавай только эту, FakeTLS-форму (она с префиксом ee).%s\n' "$C_DIM" "$C_RST"
    pause
}

# ============ ACTIONS: SELF-UPDATE ============

action_self_update() {
    print_header
    printf '%s═══ Обновление скрипта ═══%s\n\n' "$C_BLD" "$C_RST"

    if [[ ! -d "${SCRIPT_DIR}/.git" ]]; then
        fail_inline "${SCRIPT_DIR} не git-репо. Self-update недоступен."
        pause; return
    fi

    if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]]; then
        fail_inline "В ${SCRIPT_DIR} есть локальные изменения"
        printf '%sСначала: git -C %s status%s\n' "$C_DIM" "$SCRIPT_DIR" "$C_RST"
        pause; return
    fi

    local before after
    before=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

    printf 'Получаю изменения... '
    if ! git -C "$SCRIPT_DIR" pull --ff-only --quiet 2>/dev/null; then
        printf '%sошибка%s\n' "$C_RED" "$C_RST"
        fail_inline "git pull --ff-only failed"
        pause; return
    fi
    after=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    if [[ "$before" == "$after" ]]; then
        ok_inline "Уже на последней версии: ${after:0:12}"
        pause; return
    fi

    ok_inline "Обновлено: ${before:0:12} → ${after:0:12}"

    local changed
    changed=$(git -C "$SCRIPT_DIR" diff --name-only "$before" "$after")

    printf '\n%sИзменённые файлы:%s\n' "$C_BLD" "$C_RST"
    printf '%s\n' "$changed" | sed 's/^/  /'

    if printf '%s' "$changed" | grep -qE '^(docker-compose\.yml|Caddyfile\.template|config\.py\.template)$'; then
        printf '\n%sИзменились шаблоны или compose.%s\n' "$C_YLW" "$C_RST"
        if confirm "Перегенерировать конфиги и перезапустить контейнеры?" N; then
            detect_compose
            if [[ -n "$COMPOSE" && -f .env ]]; then
                local DOMAIN="" BASE_SECRET="" AD_TAG=""
                # shellcheck source=/dev/null
                source .env
                sed "s/__DOMAIN__/$DOMAIN/g" Caddyfile.template > Caddyfile
                if [[ -n "${AD_TAG:-}" ]]; then
                    sed -e "s/__DOMAIN__/$DOMAIN/g" \
                        -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                        -e "s/# AD_TAG = \"__AD_TAG__\"/AD_TAG = \"$AD_TAG\"/g" \
                        config.py.template > config.py
                else
                    sed -e "s/__DOMAIN__/$DOMAIN/g" \
                        -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                        config.py.template > config.py
                fi
                chmod 644 config.py
                $COMPOSE up -d --build >/dev/null 2>&1
                ok_inline "Контейнеры перезапущены"
            fi
        fi
    fi

    if printf '%s' "$changed" | grep -qE '^manage\.sh$'; then
        printf '\n%sСам manage.sh обновился — перезапусти скрипт чтобы изменения применились.%s\n' "$C_YLW" "$C_RST"
        pause
        clear
        exit 0
    fi

    pause
}

# ============ ACTIONS: UNINSTALL ============

action_uninstall() {
    print_header
    printf '%s═══ ПОЛНОЕ УДАЛЕНИЕ ═══%s\n\n' "$C_RED$C_BLD" "$C_RST"
    printf 'Будет:\n'
    printf '  • остановлены контейнеры\n'
    printf '  • удалён Docker volume %scaddy_data%s (LE-сертификат!)\n' "$C_RED" "$C_RST"
    printf '  • удалены сгенерированные конфиги (Caddyfile, config.py)\n'
    printf '  • удалён .env\n'
    printf '  • удалена папка src/ (исходник alexbers)\n\n'
    printf '%sScript-файлы и шаблоны останутся.%s\n' "$C_DIM" "$C_RST"
    printf '%sUFW и fail2ban НЕ откатываются.%s\n\n' "$C_YLW" "$C_RST"

    if ! confirm "Точно удалить?" N; then
        return
    fi

    detect_compose
    if [[ -n "$COMPOSE" ]]; then
        printf 'Останавливаю контейнеры и удаляю volumes... '
        $COMPOSE down -v >/dev/null 2>&1 || true
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    fi

    printf 'Удаляю файлы... '
    rm -f Caddyfile config.py .env
    rm -rf src
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '\n%s═══ Удалено ═══%s\n' "$C_GRN$C_BLD" "$C_RST"
    pause
}

# ============ MAIN ============

main() {
    require_root
    ensure_deps

    while true; do
        print_header
        print_status
        print_menu
        printf '%sВыбор:%s ' "$C_BLD" "$C_RST"
        local choice
        read -r choice </dev/tty || { clear; exit 0; }
        case "$choice" in
            1)  action_deploy ;;
            2)  action_security ;;
            3)  action_status ;;
            4)  action_logs_alexbers ;;
            5)  action_logs_caddy ;;
            6)  action_restart ;;
            7)  action_stop ;;
            8)  action_start ;;
            9)  action_show_link ;;
            10) action_self_update ;;
            11) action_uninstall ;;
            0|q|Q|exit|"") clear; exit 0 ;;
            *)  printf '%sНеверный выбор: %s%s\n' "$C_RED" "$choice" "$C_RST"; sleep 1 ;;
        esac
    done
}

main "$@"
