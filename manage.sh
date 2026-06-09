#!/usr/bin/env bash
# set -o pipefail не используем: grep без совпадений даёт non-zero, это нормально в TUI
set -eu

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

SSH_PORT="22"
PROXY_PORT="443"
PROXY_API_PORT="9091"
TELEMT_BIN="/bin/telemt"
TELEMT_CONF="/etc/telemt/telemt.toml"
TELEMT_SVC="telemt"

TLS_DOMAIN_CANDIDATES=("www.cloudflare.com" "www.apple.com" "www.microsoft.com" "www.bing.com")
TLS_MASK_DOMAIN="www.cloudflare.com"

AUDIT_LOG="/var/log/telemt-audit.jsonl"

# ============ HELPERS ============

require_root() {
    [[ $EUID -eq 0 ]] || {
        if [[ -L /usr/local/bin/proxy ]]; then
            printf '%sЗапусти от root:%s sudo proxy\n' "$C_RED" "$C_RST"
        else
            printf '%sЗапусти от root:%s sudo bash manage.sh\n' "$C_RED" "$C_RST"
        fi
        exit 1
    }
}

ensure_deps() {
    local need=()
    command -v ss      >/dev/null 2>&1 || need+=(iproute2)
    command -v xxd     >/dev/null 2>&1 || need+=(xxd)
    command -v dig     >/dev/null 2>&1 || need+=(dnsutils)
    command -v git     >/dev/null 2>&1 || need+=(git)
    command -v curl    >/dev/null 2>&1 || need+=(curl)
    command -v python3 >/dev/null 2>&1 || need+=(python3)
    if [[ ${#need[@]} -gt 0 ]]; then
        printf '%sУстанавливаю зависимости: %s%s\n' "$C_DIM" "${need[*]}" "$C_RST"
        apt update >/dev/null 2>&1
        apt install -y "${need[@]}" >/dev/null 2>&1
    fi
}

install_shortcut() {
    local target="/usr/local/bin/proxy"
    local script_path="${SCRIPT_DIR}/manage.sh"
    local quiet="${1:-noisy}"

    if [[ -L "$target" ]] && [[ "$(readlink -f "$target" 2>/dev/null)" == "$script_path" ]]; then
        [[ "$quiet" == "noisy" ]] && printf '%s✓%s Команда %ssudo proxy%s уже установлена\n' \
            "$C_GRN" "$C_RST" "$C_BLD" "$C_RST"
        return 0
    fi

    if [[ -e "$target" ]] && [[ ! -L "$target" ]]; then
        printf '%s⚠%s По пути %s лежит обычный файл — не трогаю\n' "$C_YLW" "$C_RST" "$target"
        return 1
    fi

    chmod +x "$script_path" 2>/dev/null || true

    if ! ln -sf "$script_path" "$target" 2>/dev/null; then
        printf '%s✗%s Не удалось создать %s\n' "$C_RED" "$C_RST" "$target"
        return 1
    fi

    hash -r 2>/dev/null || true

    printf '\n%s✓%s Команда %ssudo proxy%s установлена\n' "$C_GRN" "$C_RST" "$C_BLD" "$C_RST"
    printf '%s   Если в текущем терминале sudo proxy выдаёт "command not found" —%s\n' "$C_DIM" "$C_RST"
    printf '%s   выполни %shash -r%s или открой новую SSH-сессию.%s\n\n' "$C_DIM" "$C_BLD$C_DIM" "$C_DIM" "$C_RST"
    sleep 2
    return 0
}

ensure_shortcut() { install_shortcut quiet; }

detect_ssh_port() {
    local port=""
    port=$(awk '/^[Pp]ort / {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
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

ok_inline()   { printf '%s✓ %s%s\n' "$C_GRN" "$1" "$C_RST"; }
fail_inline() { printf '%s✗ %s%s\n' "$C_RED" "$1" "$C_RST"; }
step()        { printf '%s[%s]%s %s\n' "$C_CYN" "$1" "$C_RST" "$2"; }

detect_tls_domain() {
    local quiet="${1:-noisy}"
    for candidate in "${TLS_DOMAIN_CANDIDATES[@]}"; do
        [[ "$quiet" == "noisy" ]] && printf '    Пробую %s... ' "$candidate"
        if timeout 5 bash -c "echo >/dev/tcp/${candidate}/443" 2>/dev/null; then
            TLS_MASK_DOMAIN="$candidate"
            [[ "$quiet" == "noisy" ]] && printf '%sдоступен%s\n' "$C_GRN" "$C_RST"
            return 0
        else
            [[ "$quiet" == "noisy" ]] && printf '%sнедоступен%s\n' "$C_DIM" "$C_RST"
        fi
    done
    return 1
}

install_telemt_binary() {
    local url="https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz"
    if curl -fsSL "$url" | tar -xz -C /tmp 2>/dev/null && [[ -f /tmp/telemt ]]; then
        mv /tmp/telemt "$TELEMT_BIN"
        chmod +x "$TELEMT_BIN"
        return 0
    fi
    return 1
}

check_dns_health() {
    local domain="$1"
    local errors=0 warnings=0

    printf '\n%sПроверка DNS и доступности:%s\n' "$C_BLD" "$C_RST"

    local server_ip
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null)
    server_ip=$(printf '%s' "$server_ip" | tr -d '[:space:]')
    if [[ -z "$server_ip" ]]; then
        printf '  %s✗ Не удалось определить публичный IP сервера%s\n' "$C_RED" "$C_RST"
        errors=$((errors+1))
    else
        printf '  %s✓%s Публичный IP этого VPS: %s%s%s\n' "$C_GRN" "$C_RST" "$C_BLD" "$server_ip" "$C_RST"
    fi

    local resolved_ips
    resolved_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
    if [[ -z "$resolved_ips" ]]; then
        printf '  %s✗%s Домен %s не резолвится — A-запись не настроена или не пропагировала\n' \
            "$C_RED" "$C_RST" "$domain"
        return 1
    fi

    local ip_count
    ip_count=$(printf '%s\n' "$resolved_ips" | wc -l | tr -d ' ')
    if (( ip_count > 1 )); then
        printf '  %s⚠%s У домена несколько A-записей:\n' "$C_YLW" "$C_RST"
        printf '%s\n' "$resolved_ips" | sed "s/^/      /"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s A-запись: %s\n' "$C_GRN" "$C_RST" "$resolved_ips"
    fi

    if [[ -n "$server_ip" ]]; then
        if printf '%s\n' "$resolved_ips" | grep -qx "$server_ip"; then
            printf '  %s✓%s Домен указывает на этот сервер\n' "$C_GRN" "$C_RST"
        else
            printf '  %s✗%s Домен не указывает на этот сервер!\n' "$C_RED" "$C_RST"
            printf '      VPS: %s\n' "$server_ip"
            printf '      DNS: %s\n' "$(printf '%s\n' "$resolved_ips" | tr '\n' ' ')"
            errors=$((errors+1))
        fi
    fi

    local cf_ip="" google_ip=""
    cf_ip=$(dig @1.1.1.1 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
    google_ip=$(dig @8.8.8.8 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)

    if [[ -z "$cf_ip" ]]; then
        printf '  %s⚠%s Cloudflare DNS (1.1.1.1) не видит домен — DNS не пропагировал\n' "$C_YLW" "$C_RST"
        warnings=$((warnings+1))
    elif [[ -n "$server_ip" && "$cf_ip" != "$server_ip" ]]; then
        printf '  %s⚠%s Cloudflare DNS видит другой IP: %s\n' "$C_YLW" "$C_RST" "$cf_ip"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Cloudflare DNS видит: %s\n' "$C_GRN" "$C_RST" "$cf_ip"
    fi

    if [[ -z "$google_ip" ]]; then
        printf '  %s⚠%s Google DNS (8.8.8.8) не видит домен\n' "$C_YLW" "$C_RST"
        warnings=$((warnings+1))
    elif [[ -n "$server_ip" && "$google_ip" != "$server_ip" ]]; then
        printf '  %s⚠%s Google DNS видит другой IP: %s\n' "$C_YLW" "$C_RST" "$google_ip"
        warnings=$((warnings+1))
    else
        printf '  %s✓%s Google DNS видит: %s\n' "$C_GRN" "$C_RST" "$google_ip"
    fi

    local p443_user=""
    p443_user=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/ {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1 || true)
    if [[ -n "$p443_user" ]]; then
        if printf '%s' "$p443_user" | grep -qE '"telemt"'; then
            printf '  %s✓%s Порт 443 занят telemt (текущий деплой)\n' "$C_GRN" "$C_RST"
        else
            local hint=""
            printf '%s' "$p443_user" | grep -qE '"caddy"'    && hint="Caddy — останови: docker stop mtproxy-caddy"
            printf '%s' "$p443_user" | grep -qE '"nginx"'    && hint="nginx — отключи или убери с 443"
            printf '%s' "$p443_user" | grep -qE '"python3"'  && hint="Старый alexbers — останови: docker compose down"
            printf '  %s✗%s Порт 443 занят чужим процессом: %s\n' "$C_RED" "$C_RST" "$p443_user"
            [[ -n "$hint" ]] && printf '      %s%s%s\n' "$C_YLW" "$hint" "$C_RST"
            printf '      %stelemt не сможет занять 443.%s\n' "$C_DIM" "$C_RST"
            errors=$((errors+1))
        fi
    else
        printf '  %s✓%s Порт 443 свободен — telemt займёт его\n' "$C_GRN" "$C_RST"
    fi

    printf '\n'
    if (( errors > 0 )); then
        printf '  %sНайдено критичных ошибок: %d%s\n' "$C_RED" "$errors" "$C_RST"
        return 1
    fi
    (( warnings > 0 )) && printf '  %sПредупреждений: %d (не блокирует)%s\n' "$C_YLW" "$warnings" "$C_RST" \
                       || printf '  %sВсе проверки пройдены%s\n' "$C_GRN" "$C_RST"
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
    local domain="${C_DIM}не установлен${C_RST}"
    local proxy_state="${C_DIM}не запущен${C_RST}"
    local tls_mask="$TLS_MASK_DOMAIN"
    local ufw_state="${C_DIM}не настроен${C_RST}"

    if [[ -f .env ]]; then
        local DOMAIN="" TLS_DOMAIN=""
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        [[ -n "${DOMAIN:-}"     ]] && domain="$DOMAIN"
        [[ -n "${TLS_DOMAIN:-}" ]] && tls_mask="$TLS_DOMAIN"
    fi

    if systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1; then
        proxy_state="${C_GRN}запущен${C_RST}"
    elif systemctl is-enabled "$TELEMT_SVC" >/dev/null 2>&1; then
        proxy_state="${C_YLW}остановлен${C_RST}"
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
  ${C_BLD}telemt:${C_RST}     ${proxy_state}    ${C_DIM}(порт ${PROXY_PORT}, маска: ${tls_mask}, MSS=tspu)${C_RST}
  ${C_BLD}Файрвол:${C_RST}    ${ufw_state}

STATUS
}

print_menu() {
    cat <<MENU
${C_BLD}═══ УСТАНОВКА ═══${C_RST}
  ${C_CYN}1)${C_RST} Проверить домен              ${C_DIM}(DNS, IP — без установки)${C_RST}
  ${C_CYN}2)${C_RST} Установить прокси            ${C_DIM}(telemt, client_mss=tspu)${C_RST}
  ${C_CYN}3)${C_RST} Настроить безопасность VPS   ${C_DIM}(ufw, fail2ban, keepalive, rate-limit)${C_RST}

${C_BLD}═══ УПРАВЛЕНИЕ ═══${C_RST}
  ${C_CYN}4)${C_RST} Статус сервиса
  ${C_CYN}5)${C_RST} Логи telemt                  ${C_DIM}(live, Ctrl+C — выход)${C_RST}
  ${C_CYN}6)${C_RST} Перезапустить прокси
  ${C_CYN}7)${C_RST} Остановить прокси
  ${C_CYN}8)${C_RST} Запустить прокси
  ${C_CYN}9)${C_RST} Показать ссылку для пользователей

${C_BLD}═══ ОБСЛУЖИВАНИЕ ═══${C_RST}
  ${C_CYN}10)${C_RST} Обновить систему              ${C_DIM}(apt update && upgrade)${C_RST}
  ${C_CYN}11)${C_RST} Обновить скрипт из git
  ${C_CYN}12)${C_RST} Установить команду proxy      ${C_DIM}(если не работает sudo proxy)${C_RST}
  ${C_CYN}13)${C_RST} Удалить прокси
  ${C_CYN}14)${C_RST} Проверить связь с Telegram    ${C_DIM}(DC-серверы, порты 443/8888)${C_RST}
  ${C_CYN}15)${C_RST} Обновить telemt              ${C_DIM}(скачать последнюю версию)${C_RST}
  ${C_CYN}16)${C_RST} Задать AD_TAG               ${C_DIM}(спонсорский канал, без перезапуска)${C_RST}
  ${C_CYN}17)${C_RST} Статистика и аудит           ${C_DIM}(соединения, IP, трафик, гео)${C_RST}
  ${C_CYN}18)${C_RST} Пользователи                 ${C_DIM}(добавить, ссылка, квота, удалить)${C_RST}
  ${C_CYN}19)${C_RST} Telegram-бот                 ${C_DIM}(установить, запустить, настроить)${C_RST}

  ${C_DIM}0) Выход${C_RST}

MENU
}

# ============ ACTIONS: CHECK DOMAIN ============

action_check_domain() {
    local DOMAIN=""
    if [[ -f .env ]]; then
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
        DOMAIN="${DOMAIN:-}"
    fi

    print_header
    printf '%s═══ Проверка домена ═══%s\n\n' "$C_BLD" "$C_RST"
    printf '%sПроверяем DNS и порт 443 — ничего не устанавливается.%s\n\n' "$C_DIM" "$C_RST"

    DOMAIN=$(prompt_value "Домен для проверки" "$DOMAIN")
    if [[ -z "$DOMAIN" ]]; then
        fail_inline "Домен не может быть пустым"
        pause; return
    fi

    while true; do
        print_header
        printf '%s═══ Проверка домена: %s%s%s ═══%s\n' "$C_BLD" "$C_CYN" "$DOMAIN" "$C_RST$C_BLD" "$C_RST"

        check_dns_health "$DOMAIN" \
            && printf '\n%sДомен готов для telemt.%s\n' "$C_GRN" "$C_RST" \
            || printf '\n%sЕсть проблемы — исправь перед деплоем.%s\n' "$C_RED" "$C_RST"

        printf '\n%s───────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"
        printf '  %sr)%s Повторить проверку\n' "$C_CYN" "$C_RST"
        printf '  %sd)%s Сменить домен\n' "$C_CYN" "$C_RST"
        printf '  %s0)%s Назад\n\n' "$C_DIM" "$C_RST"
        printf '%sВыбор:%s ' "$C_BLD" "$C_RST"

        local choice
        read -r choice </dev/tty || return
        case "$choice" in
            r|R|"") continue ;;
            d|D)
                local new_domain
                new_domain=$(prompt_value "Новый домен" "$DOMAIN")
                [[ -n "$new_domain" ]] && DOMAIN="$new_domain"
                ;;
            0|q|Q|exit) return ;;
            *) printf '%sНеверный выбор%s\n' "$C_RED" "$C_RST"; sleep 1 ;;
        esac
    done
}

# ============ ACTIONS: DEPLOY ============

action_deploy() {
    print_header
    printf '%s═══ Установка прокси (telemt) ═══%s\n\n' "$C_BLD" "$C_RST"

    local DOMAIN="" BASE_SECRET="" TLS_DOMAIN=""
    if [[ -f .env ]]; then
        # shellcheck source=/dev/null
        source .env 2>/dev/null || true
    fi

    step "1/4" "Домен (A-запись должна указывать на этот VPS)"
    DOMAIN=$(prompt_value "Введи домен" "$DOMAIN")
    if [[ -z "$DOMAIN" ]]; then
        fail_inline "DOMAIN не может быть пустым"
        pause; return
    fi
    printf '\n'

    step "2/4" "Базовый секрет (32 hex-символа, пусто — сгенерирую)"
    BASE_SECRET=$(prompt_value "Секрет" "$BASE_SECRET")
    if [[ -z "$BASE_SECRET" ]]; then
        BASE_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        ok_inline "Сгенерирован: ${BASE_SECRET}"
    elif ! [[ "$BASE_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        fail_inline "BASE_SECRET должен быть ровно 32 hex-символа (0-9, a-f)"
        pause; return
    fi
    printf '\n'

    step "3/4" "TLS-маскировочный домен (CDN, который telemt будет имитировать)"
    printf '       Telemt скачает реальный сертификат этого сайта.\n'
    printf '       Ищу доступный с этого VPS...\n'
    if detect_tls_domain noisy; then
        ok_inline "Авто-выбран: ${TLS_MASK_DOMAIN}"
    else
        fail_inline "Ни один CDN-домен недоступен с этого VPS — нет исходящего HTTPS?"
        pause; return
    fi
    printf '\n'

    step "4/4" "Спонсорский канал (AD_TAG, пусто — пропустить)"
    printf '       Получить тег: @MTProxybot → /newproxy → скопируй тег\n'
    local NEW_AD_TAG
    NEW_AD_TAG=$(prompt_value "AD_TAG (32 hex)" "${AD_TAG:-}")
    if [[ -n "$NEW_AD_TAG" ]] && ! [[ "$NEW_AD_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
        fail_inline "AD_TAG должен быть ровно 32 hex-символа — пропускаю"
        NEW_AD_TAG=""
    elif [[ -n "$NEW_AD_TAG" ]]; then
        ok_inline "AD_TAG принят"
    else
        printf '  %sПропущено — можно задать позже в пункте 16%s\n' "$C_DIM" "$C_RST"
    fi
    AD_TAG="${NEW_AD_TAG}"
    printf '\n'

    if ! check_dns_health "$DOMAIN"; then
        printf '\n'
        if ! confirm "Продолжить несмотря на ошибки? (не рекомендую)" N; then
            return
        fi
    fi

    printf '\n%sИтого:%s\n' "$C_BLD" "$C_RST"
    printf '  Домен:      %s\n' "$DOMAIN"
    printf '  Секрет:     %s\n' "$BASE_SECRET"
    printf '  TLS-маска:  %s\n' "$TLS_MASK_DOMAIN"
    printf '  Порт:       %s\n' "$PROXY_PORT"
    printf '  client_mss: tspu (обход DPI ТСПУ)\n'
    [[ -n "${AD_TAG:-}" ]] && printf '  AD_TAG:     %s\n' "$AD_TAG"
    printf '\n'

    if ! confirm "Запустить установку?" Y; then
        return
    fi

    cat > .env <<EOF
DOMAIN=$DOMAIN
BASE_SECRET=$BASE_SECRET
TLS_DOMAIN=$TLS_MASK_DOMAIN
EOF
    [[ -n "${AD_TAG:-}" ]] && printf 'AD_TAG=%s\n' "$AD_TAG" >> .env
    chmod 600 .env

    printf '\n%sУстановка:%s\n' "$C_BLD" "$C_RST"

    printf '  Обновляю apt... '
    apt update >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    if command -v docker >/dev/null 2>&1; then
        local old
        old=$(docker ps -q --filter "name=mtproto-final" --filter "name=mtproxy-caddy" 2>/dev/null || true)
        if [[ -n "$old" ]]; then
            printf '  Останавливаю старые контейнеры... '
            # shellcheck disable=SC2086
            docker stop $old >/dev/null 2>&1 || true
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        fi
    fi

    if [[ -x "$TELEMT_BIN" ]]; then
        printf '  telemt: %sуже установлен%s (%s)\n' "$C_DIM" "$C_RST" \
            "$("$TELEMT_BIN" --version 2>/dev/null | head -1 || echo 'версия неизвестна')"
    else
        printf '  Скачиваю telemt... '
        if install_telemt_binary; then
            printf '%sok%s (%s)\n' "$C_GRN" "$C_RST" \
                "$("$TELEMT_BIN" --version 2>/dev/null | head -1 || echo 'ok')"
        else
            fail_inline "Не удалось скачать telemt"
            printf '%s  Проверь: curl -fsSL https://github.com/telemt/telemt/releases/latest%s\n' "$C_DIM" "$C_RST"
            pause; return
        fi
    fi

    printf '  Создаю пользователя telemt... '
    id telemt >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /opt/telemt telemt >/dev/null 2>&1
    mkdir -p /opt/telemt /etc/telemt
    chown -R telemt:telemt /opt/telemt /etc/telemt
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Генерирую %s... ' "$TELEMT_CONF"
    sed -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
        -e "s/__TLS_DOMAIN__/$TLS_MASK_DOMAIN/g" \
        -e "s/__PORT__/$PROXY_PORT/g" \
        -e "s/__API_PORT__/$PROXY_API_PORT/g" \
        telemt.toml.template > "$TELEMT_CONF"
    chown telemt:telemt "$TELEMT_CONF"
    chmod 640 "$TELEMT_CONF"
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Создаю systemd-сервис... '
    cat > /etc/systemd/system/${TELEMT_SVC}.service <<EOF
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=${TELEMT_BIN} ${TELEMT_CONF}
Environment=RUST_LOG=error
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Запускаю telemt... '
    systemctl enable "$TELEMT_SVC" >/dev/null 2>&1
    systemctl restart "$TELEMT_SVC" >/dev/null 2>&1
    local i=0
    while (( i < 8 )); do
        sleep 1; i=$((i+1)); printf '.'
    done
    printf '\n'

    if ! systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1; then
        fail_inline "telemt не запустился"
        printf '%s   Проверь логи: sudo proxy → 5%s\n' "$C_DIM" "$C_RST"
        pause; return
    fi
    ok_inline "telemt запущен"

    local AD_TAG=""
    [[ -f .env ]] && { source .env 2>/dev/null || true; }
    if [[ -n "${AD_TAG:-}" ]]; then
        printf '  Применяю AD_TAG из .env... '
        local tag_result
        tag_result=$(curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/user1" \
            -H "Content-Type: application/json" \
            -d "{\"user_ad_tag\":\"${AD_TAG}\"}" 2>/dev/null || true)
        printf '%s' "$tag_result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null \
            && ok_inline "AD_TAG применён" \
            || printf '%sпропущено (проверь пункт 16)%s\n' "$C_YLW" "$C_RST"
    fi

    local hex_mask link_ee link_dd
    hex_mask=$(printf '%s' "$TLS_MASK_DOMAIN" | xxd -ps | tr -d '\n')
    link_ee="https://t.me/proxy?server=${DOMAIN}&port=${PROXY_PORT}&secret=ee${BASE_SECRET}${hex_mask}"
    link_dd="https://t.me/proxy?server=${DOMAIN}&port=${PROXY_PORT}&secret=dd${BASE_SECRET}"

    printf '\n%s═══ Готово ═══%s\n\n' "$C_GRN$C_BLD" "$C_RST"
    printf '%sОсновная ссылка (FakeTLS):%s\n%s\n\n' "$C_BLD" "$C_RST" "$link_ee"
    printf '%sДля пользователей с VPN (VLESS и др.):%s\n%s\n\n' "$C_BLD" "$C_RST" "$link_dd"
    printf '%sНастройка безопасности:%s запусти пункт 3 (ufw, keepalive, rate-limit)\n' "$C_BLD" "$C_RST"
    [[ -z "${AD_TAG:-}" ]] && printf '%sСпонсорский канал:%s запусти пункт 16 (AD_TAG)\n' "$C_BLD" "$C_RST"

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
    printf '  • настроен файрвол ufw\n'
    printf '  • на порт 443 добавлен iptables rate-limit (1 SYN/сек/IP)\n'
    printf '  • установлен fail2ban\n'
    printf '  • включены автообновления безопасности\n'
    printf '  • применены sysctl-настройки (TCP keepalive — фикс залипания iOS)\n\n'

    if ! confirm "Запустить?" Y; then
        return
    fi

    printf '\n%sСканирую открытые порты...%s\n' "$C_DIM" "$C_RST"
    local listening_ports=()
    while IFS= read -r line; do
        local port
        port=$(printf '%s' "$line" | awk '{print $4}' | awk -F: '{print $NF}')
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] && listening_ports+=("$port")
    done < <(ss -tln 2>/dev/null | tail -n +2)

    local unique_ports=""
    if [[ ${#listening_ports[@]} -gt 0 ]]; then
        unique_ports=$(printf '%s\n' "${listening_ports[@]}" | sort -un)
    fi

    local whitelist=("$SSH_PORT" 443)
    is_whitelisted() {
        local p="$1"
        for wp in "${whitelist[@]}"; do [[ "$p" == "$wp" ]] && return 0; done
        return 1
    }

    local extra_open=()
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        if ! is_whitelisted "$port"; then
            local proc=""
            proc=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | head -1 || true)
            [[ -z "$proc" ]] && proc="(неизвестно)"
            printf '\n%sПорт %s%s слушается: %s\n' "$C_YLW" "$port" "$C_RST" "$proc"
            if confirm "Оставить открытым в файрволе?" Y; then
                extra_open+=("$port")
            fi
        fi
    done <<< "$unique_ports"

    printf '\n%sПрименяю настройки:%s\n' "$C_BLD" "$C_RST"

    printf '  Обновляю apt... '
    apt update >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Устанавливаю ufw... '
    if ! apt install -y ufw >/dev/null 2>&1; then
        fail_inline "apt не сработал"
        pause; return
    fi
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Сбрасываю старые правила... '
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Открываю порты: '
    ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1 || true
    ufw allow 443/tcp comment "MTProto telemt" >/dev/null 2>&1 || true
    for port in "${extra_open[@]:-}"; do
        [[ -z "$port" ]] && continue
        ufw allow "${port}/tcp" comment "user-allowed" >/dev/null 2>&1 || true
    done
    printf '%s%s 443%s' "$C_CYN" "$SSH_PORT" "$C_RST"
    [[ ${#extra_open[@]} -gt 0 ]] && printf ' %s+ %s%s' "$C_CYN" "${extra_open[*]}" "$C_RST"
    printf ' %sok%s\n' "$C_GRN" "$C_RST"

    printf '  Активирую ufw... '
    ufw --force enable >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    # xt_recent: 1 SYN/сек на IP — надёжнее ufw limit против активного зондирования DPI
    printf '  Добавляю iptables rate-limit на порт 443... '
    if modprobe xt_recent 2>/dev/null; then
        printf 'xt_recent '
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --rcheck --seconds 1 -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set -j ACCEPT 2>/dev/null || true
        # Порядок важен: SET вставляется первым (позиция 1), потом CHECK+DROP
        # вставляется вторым → занимает позицию 1. Итог: CHECK→DROP идёт ДО SET→ACCEPT.
        iptables -I INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --rcheck --seconds 1 -j DROP
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sxt_recent недоступен — пропущено%s\n' "$C_YLW" "$C_RST"
    fi

    printf '  Устанавливаю fail2ban... '
    if apt install -y fail2ban >/dev/null 2>&1; then
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
        systemctl enable fail2ban >/dev/null 2>&1 || true
        systemctl restart fail2ban >/dev/null 2>&1 || true
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sпропущено%s\n' "$C_YLW" "$C_RST"
    fi

    printf '  Настраиваю автообновления... '
    if apt install -y unattended-upgrades >/dev/null 2>&1; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        systemctl enable unattended-upgrades >/dev/null 2>&1 || true
        systemctl restart unattended-upgrades >/dev/null 2>&1 || true
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sпропущено%s\n' "$C_YLW" "$C_RST"
    fi

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
# TCP keepalive: быстро рвёт мёртвые соединения — фикс залипания iOS Telegram
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
# conntrack: сокращаем таймаут мёртвых established с 5 суток до 1 часа
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
EOF
    sysctl --system >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '\n%s═══ Готово ═══%s\n' "$C_GRN$C_BLD" "$C_RST"
    pause
}

# ============ ACTIONS: MANAGEMENT ============

action_status() {
    print_header
    printf '%s═══ Статус сервиса telemt ═══%s\n\n' "$C_BLD" "$C_RST"
    systemctl status "$TELEMT_SVC" --no-pager 2>&1 || true
    pause
}

action_logs() {
    print_header
    printf '%s═══ Логи telemt (live, Ctrl+C — выход) ═══%s\n\n' "$C_BLD" "$C_RST"
    trap 'true' INT
    journalctl -u "$TELEMT_SVC" --tail=50 -f 2>/dev/null || true
    trap - INT
    pause
}

action_restart() {
    print_header
    printf '%s═══ Перезапуск ═══%s\n\n' "$C_BLD" "$C_RST"
    printf 'Перезапускаю telemt... '
    systemctl restart "$TELEMT_SVC" >/dev/null 2>&1
    sleep 2
    if systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1; then
        ok_inline "telemt запущен"
    else
        fail_inline "telemt не запустился — проверь логи (пункт 5)"
    fi
    pause
}

action_stop() {
    print_header
    printf '%s═══ Остановка ═══%s\n\n' "$C_BLD" "$C_RST"
    printf 'Останавливаю telemt... '
    systemctl stop "$TELEMT_SVC" >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"
    pause
}

action_start() {
    print_header
    printf '%s═══ Запуск ═══%s\n\n' "$C_BLD" "$C_RST"
    printf 'Запускаю telemt... '
    systemctl start "$TELEMT_SVC" >/dev/null 2>&1
    sleep 2
    if systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1; then
        ok_inline "telemt запущен"
    else
        fail_inline "telemt не запустился — проверь логи (пункт 5)"
    fi
    pause
}

action_show_link() {
    print_header
    printf '%s═══ Ссылка для пользователей ═══%s\n\n' "$C_BLD" "$C_RST"
    if [[ ! -f .env ]]; then
        fail_inline ".env не найден. Сначала установи прокси."
        pause; return
    fi

    local DOMAIN="" BASE_SECRET="" TLS_DOMAIN=""
    # shellcheck source=/dev/null
    source .env

    if [[ -z "$DOMAIN" || -z "$BASE_SECRET" || -z "$TLS_DOMAIN" ]]; then
        fail_inline "В .env нет DOMAIN, BASE_SECRET или TLS_DOMAIN"
        pause; return
    fi

    local hex_mask link_ee link_dd
    hex_mask=$(printf '%s' "$TLS_DOMAIN" | xxd -ps | tr -d '\n')
    link_ee="https://t.me/proxy?server=${DOMAIN}&port=${PROXY_PORT}&secret=ee${BASE_SECRET}${hex_mask}"
    link_dd="https://t.me/proxy?server=${DOMAIN}&port=${PROXY_PORT}&secret=dd${BASE_SECRET}"

    printf '%sОсновная (FakeTLS, рекомендуется):%s\n' "$C_BLD" "$C_RST"
    printf '%s%s%s\n\n' "$C_GRN" "$link_ee" "$C_RST"

    printf '%sДля пользователей с VPN (VLESS и др.):%s\n' "$C_BLD" "$C_RST"
    printf '%s%s%s\n\n' "$C_CYN" "$link_dd" "$C_RST"

    printf '%sМаска ee: %s | dd-режим работает с любым VPN-клиентом%s\n' "$C_DIM" "$TLS_DOMAIN" "$C_RST"
    pause
}

# ============ ACTIONS: SYSTEM UPDATE ============

action_system_update() {
    print_header
    printf '%s═══ Обновление системы ═══%s\n\n' "$C_BLD" "$C_RST"
    printf 'Обновит все пакеты Ubuntu/Debian (apt update && apt upgrade).\n'
    printf '%sМожет занять несколько минут.%s\n\n' "$C_DIM" "$C_RST"

    if ! confirm "Запустить обновление системы?" Y; then
        return
    fi

    printf '\n  Обновляю списки пакетов... '
    if apt update >/dev/null 2>&1; then
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        fail_inline "apt update завершился с ошибкой"
        pause; return
    fi

    local upgradable=0
    upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c . || echo 0)
    if [[ "$upgradable" -eq 0 ]]; then
        printf '\n%s✓%s Все пакеты уже актуальны\n' "$C_GRN" "$C_RST"
        pause; return
    fi

    printf '  Доступно обновлений: %s%d%s\n\n' "$C_BLD" "$upgradable" "$C_RST"
    if ! confirm "Установить обновления?" Y; then
        return
    fi

    printf '\n%sУстанавливаю обновления:%s\n\n' "$C_BLD" "$C_RST"
    DEBIAN_FRONTEND=noninteractive apt -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        upgrade || { fail_inline "apt upgrade завершился с ошибкой"; pause; return; }

    apt autoremove -y >/dev/null 2>&1 || true
    apt autoclean  >/dev/null 2>&1 || true

    if [[ -f /var/run/reboot-required ]]; then
        printf '\n%s⚠%s Требуется перезагрузка\n' "$C_YLW" "$C_RST"
        if confirm "Перезагрузить сейчас?" N; then
            printf '%sПерезагрузка через 5 сек...%s\n' "$C_YLW" "$C_RST"
            sleep 5; systemctl reboot; exit 0
        fi
    fi

    printf '\n%s═══ Обновление завершено ═══%s\n' "$C_GRN$C_BLD" "$C_RST"
    pause
}

# ============ ACTIONS: INSTALL SHORTCUT ============

action_install_shortcut() {
    print_header
    printf '%s═══ Установка команды proxy ═══%s\n\n' "$C_BLD" "$C_RST"
    printf 'Создаст симлинк %s/usr/local/bin/proxy%s → %s\n\n' \
        "$C_BLD" "$C_RST" "${SCRIPT_DIR}/manage.sh"
    install_shortcut noisy
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

    local local_changes
    local_changes=$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)
    if [[ -n "$local_changes" ]]; then
        printf '%sНайдены локальные изменения:%s\n' "$C_YLW" "$C_RST"
        printf '%s\n' "$local_changes" | sed 's/^/  /'
        if ! confirm "Сбросить локальные изменения и подтянуть GitHub?" Y; then
            pause; return
        fi
        git -C "$SCRIPT_DIR" reset --hard HEAD >/dev/null 2>&1
        git -C "$SCRIPT_DIR" clean -fd >/dev/null 2>&1
    fi

    local before after
    before=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

    printf 'Получаю изменения... '
    if ! git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null; then
        fail_inline "git fetch failed"
        pause; return
    fi
    git -C "$SCRIPT_DIR" reset --hard origin/main >/dev/null 2>&1
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

    if printf '%s' "$changed" | grep -q 'telemt\.toml\.template'; then
        printf '\n%sИзменился telemt.toml.template.%s\n' "$C_YLW" "$C_RST"
        if confirm "Перегенерировать конфиг и перезапустить?" N; then
            if [[ -f .env ]]; then
                local DOMAIN="" BASE_SECRET="" TLS_DOMAIN=""
                # shellcheck source=/dev/null
                source .env
                sed -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                    -e "s/__TLS_DOMAIN__/${TLS_DOMAIN:-$TLS_MASK_DOMAIN}/g" \
                    -e "s/__PORT__/$PROXY_PORT/g" \
                    -e "s/__API_PORT__/$PROXY_API_PORT/g" \
                    telemt.toml.template > "$TELEMT_CONF"
                chown telemt:telemt "$TELEMT_CONF" 2>/dev/null || true
                systemctl restart "$TELEMT_SVC" >/dev/null 2>&1 || true
                ok_inline "Конфиг обновлён, telemt перезапущен"
                local AD_TAG=""
                source .env 2>/dev/null || true
                if [[ -n "${AD_TAG:-}" ]]; then
                    sleep 3
                    curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/user1" \
                        -H "Content-Type: application/json" \
                        -d "{\"user_ad_tag\":\"${AD_TAG}\"}" >/dev/null 2>&1 || true
                    ok_inline "AD_TAG восстановлен"
                fi
            fi
        fi
    fi

    if printf '%s' "$changed" | grep -q '^manage\.sh$'; then
        printf '\n%smanage.sh обновился — перезапусти скрипт.%s\n' "$C_YLW" "$C_RST"
        pause; clear; exit 0
    fi

    pause
}

# ============ ACTIONS: UNINSTALL ============

action_uninstall() {
    print_header
    printf '%s═══ ПОЛНОЕ УДАЛЕНИЕ ═══%s\n\n' "$C_RED$C_BLD" "$C_RST"
    printf 'Удалит telemt, сервис и конфиги с этого VPS.\n\n'

    if ! confirm "Удалить прокси?" Y; then
        return
    fi

    local revert_security=false
    printf '\n%sБезопасность (опционально):%s\n' "$C_BLD" "$C_RST"
    printf '  • ufw — сбросить правила\n'
    printf '  • fail2ban — выключить\n'
    printf '  • sysctl-hardening — удалить\n'
    confirm "Откатить настройки безопасности?" Y && revert_security=true

    printf '\n%sПриступаю...%s\n' "$C_BLD" "$C_RST"

    printf '  Останавливаю telemt... '
    systemctl stop    "$TELEMT_SVC" >/dev/null 2>&1 || true
    systemctl disable "$TELEMT_SVC" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${TELEMT_SVC}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Удаляю бинарник и конфиги... '
    rm -f "$TELEMT_BIN" "$TELEMT_CONF"
    rm -rf /etc/telemt /opt/telemt
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Удаляю .env и локальные конфиги... '
    rm -f .env config.py Caddyfile
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Убираю iptables rate-limit... '
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --rcheck --seconds 1 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set -j ACCEPT 2>/dev/null || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    if command -v docker >/dev/null 2>&1; then
        local stale
        stale=$(docker ps -a --filter "name=mtproto-final" --filter "name=mtproxy-caddy" -q 2>/dev/null || true)
        if [[ -n "$stale" ]]; then
            printf '  Удаляю старые Docker-контейнеры... '
            # shellcheck disable=SC2086
            docker rm -f $stale >/dev/null 2>&1 || true
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        fi
    fi

    if [[ -L /usr/local/bin/proxy ]] && \
       [[ "$(readlink -f /usr/local/bin/proxy 2>/dev/null)" == "${SCRIPT_DIR}/manage.sh" ]]; then
        rm -f /usr/local/bin/proxy
    fi

    if $revert_security; then
        command -v ufw >/dev/null 2>&1 && {
            printf '  Откатываю ufw... '
            ufw --force reset >/dev/null 2>&1 || true
            ufw --force disable >/dev/null 2>&1 || true
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        }
        [[ -f /etc/fail2ban/jail.local ]] && {
            printf '  Откатываю fail2ban... '
            rm -f /etc/fail2ban/jail.local
            systemctl stop fail2ban >/dev/null 2>&1 || true
            systemctl disable fail2ban >/dev/null 2>&1 || true
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        }
        [[ -f /etc/sysctl.d/99-hardening.conf ]] && {
            printf '  Откатываю sysctl... '
            rm -f /etc/sysctl.d/99-hardening.conf
            sysctl --system >/dev/null 2>&1 || true
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        }
    fi

    printf '\n%s═══ Удалено ═══%s\n' "$C_GRN$C_BLD" "$C_RST"
    pause
}

# ============ ACTIONS: TELEGRAM CHECK ============

action_check_telegram() {
    print_header
    printf '%s═══ Проверка связи с Telegram ═══%s\n\n' "$C_BLD" "$C_RST"

    local TLS_DOMAIN=""
    [[ -f .env ]] && { source .env 2>/dev/null || true; }

    printf '%stellemt (порт %s):%s\n' "$C_BLD" "$PROXY_PORT" "$C_RST"
    if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${PROXY_PORT}" 2>/dev/null; then
        printf '  %s✓ 127.0.0.1:%s доступен — telemt слушает%s\n\n' "$C_GRN" "$PROXY_PORT" "$C_RST"
    else
        printf '  %s✗ 127.0.0.1:%s НЕДОСТУПЕН — telemt не запущен!%s\n' "$C_RED" "$PROXY_PORT" "$C_RST"
        printf '  %sЗапусти прокси (пункт 8)%s\n\n' "$C_DIM" "$C_RST"
    fi

    local mask="${TLS_DOMAIN:-$TLS_MASK_DOMAIN}"
    printf '%sTLS-маска (%s):%s\n' "$C_BLD" "$mask" "$C_RST"
    if timeout 5 bash -c "echo >/dev/tcp/${mask}/443" 2>/dev/null; then
        printf '  %s✓ %s:443 доступен — telemt скачает реальный cert%s\n\n' "$C_GRN" "$mask" "$C_RST"
    else
        printf '  %s✗ %s:443 НЕДОСТУПЕН — смени маску, запусти деплой заново%s\n\n' "$C_RED" "$mask" "$C_RST"
    fi

    printf 'Проверяю TCP-доступность датацентров Telegram...\n\n'

    local -a dc_list=("DC1:149.154.175.50" "DC2:149.154.167.51" "DC3:149.154.175.100" "DC4:149.154.167.91" "DC5:149.154.171.5")
    local -a ports=(443 8888)
    local ok_count=0 fail_count=0 middle_fail=0

    printf '  %s%-5s  %-20s  %s443%s  %s8888%s\n' \
        "$C_BLD" "DC" "(IP)" "$C_GRN" "$C_RST" "$C_CYN" "$C_RST"
    printf '  %s─────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"

    for entry in "${dc_list[@]}"; do
        local dc="${entry%%:*}" ip="${entry##*:}"
        printf '  %s%-5s%s %-20s' "$C_BLD" "$dc" "$C_RST" "(${ip})"
        local dc_ok=false
        for port in "${ports[@]}"; do
            if timeout 5 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; then
                printf '  %s%-6s ✓%s' "$C_GRN" "$port" "$C_RST"
                [[ "$port" == "443" ]] && dc_ok=true
            else
                printf '  %s%-6s ✗%s' "$C_RED" "$port" "$C_RST"
                [[ "$port" == "8888" ]] && middle_fail=$((middle_fail+1))
            fi
        done
        printf '\n'
        $dc_ok && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    done

    printf '\n'
    if   (( fail_count == 0 )); then
        printf '%s✓ Все DC доступны по порту 443%s\n' "$C_GRN" "$C_RST"
    elif (( ok_count   == 0 )); then
        printf '%s✗ Ни один DC Telegram недоступен по 443%s\n' "$C_RED" "$C_RST"
    else
        printf '%s⚠ Часть DC недоступна по 443 (%d из 5)%s\n' "$C_YLW" "$ok_count" "$C_RST"
    fi

    if (( middle_fail > 0 )); then
        printf '\n%s⚠ Middle proxy (8888): %d из 5 DC недоступны — AD_TAG и спонсорский канал могут не работать%s\n' \
            "$C_YLW" "$middle_fail" "$C_RST"
    fi

    pause
}

# ============ ACTIONS: UPDATE TELEMT BINARY ============

action_update_telemt() {
    print_header
    printf '%s═══ Обновление бинарника telemt ═══%s\n\n' "$C_BLD" "$C_RST"

    local cur_ver=""
    [[ -x "$TELEMT_BIN" ]] && cur_ver=$("$TELEMT_BIN" --version 2>/dev/null | head -1 || echo "?")
    printf 'Текущая версия: %s%s%s\n\n' "$C_BLD" "${cur_ver:-(не установлен)}" "$C_RST"

    if ! confirm "Скачать и установить последнюю версию?" Y; then
        return
    fi

    printf '  Скачиваю telemt... '
    if install_telemt_binary; then
        local new_ver
        new_ver=$("$TELEMT_BIN" --version 2>/dev/null | head -1 || echo "ok")
        printf '%sok%s (%s)\n' "$C_GRN" "$C_RST" "$new_ver"
        printf '  Перезапускаю сервис... '
        systemctl restart "$TELEMT_SVC" >/dev/null 2>&1 || true
        sleep 2
        systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1 \
            && ok_inline "telemt запущен" \
            || fail_inline "telemt не запустился — проверь логи (пункт 5)"
    else
        fail_inline "Не удалось скачать"
    fi

    pause
}

action_set_adtag() {
    print_header
    printf '%s═══ AD_TAG (спонсорский канал) ═══%s\n\n' "$C_BLD" "$C_RST"

    local AD_TAG=""
    [[ -f .env ]] && { source .env 2>/dev/null || true; }

    local cur_tag=""
    cur_tag=$(curl -s "http://127.0.0.1:${PROXY_API_PORT}/v1/users" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0].get('user_ad_tag') or '')" 2>/dev/null || true)

    if [[ -n "$cur_tag" ]]; then
        printf 'Текущий тег: %s%s%s\n\n' "$C_BLD" "$cur_tag" "$C_RST"
    else
        printf 'Текущий тег: %sне задан%s\n\n' "$C_DIM" "$C_RST"
    fi

    printf '%sПолучи тег в @MTProxybot → /newproxy%s\n\n' "$C_DIM" "$C_RST"
    local new_tag
    new_tag=$(prompt_value "Новый AD_TAG (32 hex, пусто — очистить)" "${AD_TAG}")

    if [[ -n "$new_tag" ]] && ! [[ "$new_tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
        fail_inline "Неверный формат: нужно ровно 32 hex-символа"
        pause; return
    fi

    printf '  Применяю через API... '
    local payload result
    if [[ -n "$new_tag" ]]; then
        payload="{\"user_ad_tag\":\"${new_tag}\"}"
    else
        payload='{"user_ad_tag":null}'
    fi
    result=$(curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/user1" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || true)

    if printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        ok_inline "Применено без перезапуска"
        sed -i "s/^AD_TAG=.*/AD_TAG=${new_tag}/" .env 2>/dev/null || true
        [[ -z "$(grep '^AD_TAG=' .env 2>/dev/null)" ]] && printf '\nAD_TAG=%s\n' "$new_tag" >> .env || true
    else
        fail_inline "API вернул ошибку"
        printf '%s%s%s\n' "$C_DIM" "$result" "$C_RST"
    fi

    pause
}

# ============ ACTIONS: STATS & AUDIT ============

action_stats() {
    print_header
    printf '%s═══ Статистика и аудит ═══%s\n\n' "$C_BLD" "$C_RST"

    local api_data
    api_data=$(curl -s "http://127.0.0.1:${PROXY_API_PORT}/v1/users" 2>/dev/null || true)

    if ! printf '%s' "$api_data" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        fail_inline "telemt API недоступен — сервис не запущен?"
        pause; return
    fi

    API_JSON="$api_data" python3 - <<'PYEOF'
import json, os

data = json.loads(os.environ['API_JSON'])
users = data['data']
total_conns = sum(u.get('current_connections', 0) for u in users)
total_ips   = sum(u.get('active_unique_ips', 0) for u in users)
total_bytes = sum(u.get('total_octets', 0) for u in users)
recent_ips  = sum(u.get('recent_unique_ips', 0) for u in users)
gb = total_bytes / 1024**3

print(f"  Соединений сейчас:  {total_conns}")
print(f"  Уникальных IP:      {total_ips}")
print(f"  Активных недавно:   {recent_ips}")
print(f"  Трафик всего:       {gb:.2f} ГБ")

if len(users) > 1:
    print()
    print("  По пользователям:")
    for u in users:
        tb = u.get('total_octets', 0) / 1024**3
        exp = u.get('expiration_rfc3339') or '—'
        quota = u.get('data_quota_bytes')
        quota_str = f"{quota/1024**3:.1f}ГБ лимит" if quota else '—'
        print(f"    {u['username']:10s}  {u.get('current_connections',0):4d} соед  "
              f"{u.get('active_unique_ips',0):3d} IP  {tb:.2f}ГБ  до:{exp}  квота:{quota_str}")
PYEOF

    printf '\n%sТоп-10 IP по соединениям:%s\n' "$C_BLD" "$C_RST"
    netstat -tn 2>/dev/null | awk '/ESTABLISHED/ && /:443 /{print $5}' \
        | cut -d: -f1 | grep -v "^${PROXY_IP:-78\.17\.13\.219}$" \
        | sort | uniq -c | sort -rn | head -10 \
        | awk '{printf "  %4d  %s\n", $1, $2}'

    printf '\n%sГео топ-3 IP:%s\n' "$C_BLD" "$C_RST"
    local top3
    top3=$(netstat -tn 2>/dev/null | awk '/ESTABLISHED/ && /:443 /{print $5}' \
        | cut -d: -f1 | grep -v "^${PROXY_IP:-78\.17\.13\.219}$" \
        | sort | uniq -c | sort -rn | head -3 | awk '{print $2}')
    for ip in $top3; do
        local info
        info=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/json" 2>/dev/null \
            | python3 -c "
import sys,json
d=json.load(sys.stdin)
org=d.get('org','?')[:35]
print(d.get('country','?'), d.get('city','?'), org)
" 2>/dev/null || echo "?")
        printf '  %-18s %s\n' "$ip" "$info"
    done

    if [[ -f "$AUDIT_LOG" ]]; then
        printf '\n%sИстория (последние 8 снапшотов):%s\n' "$C_BLD" "$C_RST"
        AUDIT_LINES="$(tail -8 "$AUDIT_LOG")" python3 - <<'PYEOF'
import json, os
for line in os.environ['AUDIT_LINES'].splitlines():
    try:
        d = json.loads(line.strip())
        ts = d.get('ts', '')[:16]
        u  = d.get('data', [{}])[0]
        c  = u.get('current_connections', '?')
        i  = u.get('active_unique_ips', '?')
        gb = u.get('total_octets', 0) / 1024**3
        print(f"  {ts}  соед={c:<5} IP={i:<4} трафик={gb:.2f}ГБ")
    except Exception:
        pass
PYEOF
    else
        printf '\n%sЛог аудита ещё не создан (cron запишет через 5 минут)%s\n' "$C_DIM" "$C_RST"
    fi

    pause
}

# ============ ACTIONS: TELEGRAM BOT ============

BOT_SVC="mtproxy-bot"
BOT_SCRIPT="${SCRIPT_DIR}/tgbot.py"

action_bot() {
    print_header
    printf '%s═══ Telegram-бот управления ═══%s\n\n' "$C_BLD" "$C_RST"

    local BOT_TOKEN="" BOT_CHAT_ID=""
    [[ -f .env ]] && source .env 2>/dev/null || true

    # Status
    if systemctl is-active "$BOT_SVC" >/dev/null 2>&1; then
        printf '  Статус бота: %s● запущен%s\n' "$C_GRN" "$C_RST"
    elif systemctl is-enabled "$BOT_SVC" >/dev/null 2>&1; then
        printf '  Статус бота: %s○ установлен, не запущен%s\n' "$C_YLW" "$C_RST"
    else
        printf '  Статус бота: %sне установлен%s\n' "$C_DIM" "$C_RST"
    fi
    [[ -n "${BOT_TOKEN:-}" ]] && printf '  BOT_TOKEN:   %s...%s\n' "${BOT_TOKEN:0:8}" "$C_RST" \
                               || printf '  BOT_TOKEN:   %sне задан%s\n' "$C_DIM" "$C_RST"
    [[ -n "${BOT_CHAT_ID:-}" ]] && printf '  CHAT_ID:     %s\n' "$BOT_CHAT_ID" \
                                 || printf '  CHAT_ID:     %sне задан%s\n' "$C_DIM" "$C_RST"
    printf '\n'

    printf '  %s1)%s Установить / обновить бота\n' "$C_CYN" "$C_RST"
    printf '  %s2)%s Запустить\n' "$C_CYN" "$C_RST"
    printf '  %s3)%s Остановить\n' "$C_CYN" "$C_RST"
    printf '  %s4)%s Логи бота\n' "$C_CYN" "$C_RST"
    printf '  %s5)%s Задать BOT_TOKEN и CHAT_ID\n' "$C_CYN" "$C_RST"
    printf '  %s0)%s Назад\n' "$C_DIM" "$C_RST"
    printf 'Выбор: '
    local sub; read -r sub </dev/tty || return
    case "$sub" in
        1) _bot_install ;;
        2) systemctl start  "$BOT_SVC" >/dev/null 2>&1 && ok_inline "Запущен"  || fail_inline "Ошибка"; sleep 2 ;;
        3) systemctl stop   "$BOT_SVC" >/dev/null 2>&1 && ok_inline "Остановлен" || fail_inline "Ошибка"; sleep 2 ;;
        4) journalctl -u "$BOT_SVC" -n 50 --no-pager 2>/dev/null; pause ;;
        5) _bot_set_credentials ;;
        0|"") return ;;
    esac
    action_bot
}

_bot_set_credentials() {
    printf '\n%s─── Настройка бота ───%s\n\n' "$C_BLD" "$C_RST"
    printf '  1. Создай бота через @BotFather → /newbot\n'
    printf '  2. Скопируй токен (формат: 123456:ABCdef...)\n'
    printf '  3. Узнай свой chat_id: напиши @userinfobot\n\n'

    local token chat_id
    token=$(prompt_value    "BOT_TOKEN (токен бота)" "${BOT_TOKEN:-}")
    chat_id=$(prompt_value  "BOT_CHAT_ID (твой chat_id, можно несколько через запятую)" "${BOT_CHAT_ID:-}")

    if [[ -z "$token" ]]; then
        fail_inline "Токен не может быть пустым"; sleep 2; return
    fi

    # Update .env
    if grep -q "^BOT_TOKEN=" .env 2>/dev/null; then
        sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=${token}|" .env
    else
        printf 'BOT_TOKEN=%s\n' "$token" >> .env
    fi
    if grep -q "^BOT_CHAT_ID=" .env 2>/dev/null; then
        sed -i "s|^BOT_CHAT_ID=.*|BOT_CHAT_ID=${chat_id}|" .env
    else
        printf 'BOT_CHAT_ID=%s\n' "$chat_id" >> .env
    fi

    ok_inline "Сохранено в .env"
    if systemctl is-active "$BOT_SVC" >/dev/null 2>&1; then
        printf '  Перезапускаю бота... '
        systemctl restart "$BOT_SVC" >/dev/null 2>&1 && ok_inline "Перезапущен"
    fi
    sleep 2
}

_bot_install() {
    printf '\n%s─── Установка бота ───%s\n\n' "$C_BLD" "$C_RST"

    local BOT_TOKEN="" BOT_CHAT_ID=""
    [[ -f .env ]] && source .env 2>/dev/null || true

    if [[ -z "${BOT_TOKEN:-}" ]]; then
        printf '%sСначала задай BOT_TOKEN (пункт 5)%s\n' "$C_YLW" "$C_RST"
        pause; return
    fi

    if [[ ! -f "$BOT_SCRIPT" ]]; then
        fail_inline "tgbot.py не найден — обнови скрипт из git (пункт 11)"; sleep 2; return
    fi

    chmod +x "$BOT_SCRIPT"

    printf '  Создаю systemd-сервис... '
    cat > "/etc/systemd/system/${BOT_SVC}.service" <<EOF
[Unit]
Description=MTProxy Telegram Bot
After=network-online.target telemt.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${BOT_SCRIPT}
WorkingDirectory=${SCRIPT_DIR}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    printf '  Запускаю... '
    systemctl enable "$BOT_SVC" >/dev/null 2>&1
    systemctl restart "$BOT_SVC" >/dev/null 2>&1
    sleep 3
    if systemctl is-active "$BOT_SVC" >/dev/null 2>&1; then
        ok_inline "Бот запущен и добавлен в автозапуск"
        printf '\n  %sНапиши /help боту чтобы проверить%s\n' "$C_DIM" "$C_RST"
    else
        fail_inline "Бот не запустился"
        printf '%s' "$(journalctl -u "$BOT_SVC" -n 10 --no-pager 2>/dev/null)"
    fi
    pause
}

# ============ ACTIONS: USER MANAGEMENT ============

_users_print_table() {
    API_JSON="$1" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ['API_JSON'])
users = data['data']
print(f"  {'#':<3} {'Имя':<12} {'Статус':<8} {'Соед':>5} {'IP':>4} {'Трафик':>8}  Квота / Срок")
print(f"  {'─'*62}")
for i, u in enumerate(users, 1):
    status = "✓ вкл" if u.get('enabled', True) else "✗ выкл"
    tb = u.get('total_octets', 0) / 1024**3
    c  = u.get('current_connections', 0)
    ip = u.get('active_unique_ips', 0)
    quota = u.get('data_quota_bytes')
    quota_str = f"{quota/1024**3:.0f}ГБ" if quota else "—"
    exp = (u.get('expiration_rfc3339') or '')[:10] or '—'
    print(f"  {i:<3} {u['username']:<12} {status:<8} {c:>5} {ip:>4} {tb:>7.2f}ГБ  {quota_str} / {exp}")
PYEOF
}

_users_add() {
    printf '\n%s─── Добавить пользователя ───%s\n\n' "$C_BLD" "$C_RST"
    local name
    name=$(prompt_value "Имя (a-z, 0-9, _)" "")
    if [[ -z "$name" ]] || ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        fail_inline "Некорректное имя"; sleep 2; return
    fi

    local secret
    secret=$(prompt_value "Секрет (32 hex, пусто — сгенерирую)" "")
    if [[ -z "$secret" ]]; then
        secret=$(head -c 16 /dev/urandom | xxd -ps)
        ok_inline "Сгенерирован: ${secret}"
    elif ! [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
        fail_inline "Секрет должен быть ровно 32 hex-символа"; sleep 2; return
    fi

    printf '  Создаю пользователя... '
    local result
    result=$(curl -s -X POST "http://127.0.0.1:${PROXY_API_PORT}/v1/users" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${name}\",\"secret\":\"${secret}\"}" 2>/dev/null || true)

    if printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        ok_inline "Создан через API (без перезапуска)"
    else
        printf '%s\n  Fallback: правлю конфиг + перезапуск...%s ' "$C_YLW" "$C_RST"
        if grep -q "^${name} = " "$TELEMT_CONF" 2>/dev/null; then
            fail_inline "Пользователь уже существует в конфиге"; sleep 2; return
        fi
        if grep -q "^\[access\.users\]" "$TELEMT_CONF" 2>/dev/null; then
            sed -i "/^\[access\.users\]/a ${name} = \"${secret}\"" "$TELEMT_CONF"
        else
            printf '\n[access.users]\n%s = "%s"\n' "$name" "$secret" >> "$TELEMT_CONF"
        fi
        systemctl restart "$TELEMT_SVC" >/dev/null 2>&1 && sleep 3
        systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1 \
            && ok_inline "Готово (telemt перезапущен)" \
            || fail_inline "telemt не запустился — проверь пункт 5"
    fi

    local DOMAIN="" TLS_DOMAIN=""
    [[ -f .env ]] && source .env 2>/dev/null || true
    local hex_mask
    hex_mask=$(printf '%s' "${TLS_DOMAIN:-$TLS_MASK_DOMAIN}" | xxd -ps | tr -d '\n')
    printf '\n%sОсновная (FakeTLS):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n\n' \
        "$C_GRN$C_BLD" "$C_RST" "$DOMAIN" "$PROXY_PORT" "$secret" "$hex_mask"
    printf '%sРезервная (dd):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' \
        "$C_CYN$C_BLD" "$C_RST" "$DOMAIN" "$PROXY_PORT" "$secret"
    pause
}

_users_edit() {
    local api_data="$1"
    printf '\n%s─── Изменить пользователя ───%s\n\n' "$C_BLD" "$C_RST"
    local name
    name=$(prompt_value "Имя пользователя" "")
    [[ -z "$name" ]] && return

    printf '\n  %s1)%s Квота трафика   %s2)%s Срок действия   %s3)%s Макс. устройств   %s4)%s Вкл/Выкл\n' \
        "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST"
    printf 'Что изменить? '
    local opt; read -r opt </dev/tty || return

    local payload=""
    case "$opt" in
        1)
            local gb; gb=$(prompt_value "Квота ГБ (пусто — снять лимит)" "")
            [[ -n "$gb" ]] && payload="{\"data_quota_bytes\":$(( gb * 1024 * 1024 * 1024 ))}" \
                           || payload='{"data_quota_bytes":null}'
            ;;
        2)
            local dt; dt=$(prompt_value "Дата YYYY-MM-DD (пусто — снять)" "")
            [[ -n "$dt" ]] && payload="{\"expiration_rfc3339\":\"${dt}T23:59:59Z\"}" \
                           || payload='{"expiration_rfc3339":null}'
            ;;
        3)
            local mx; mx=$(prompt_value "Макс IP/устройств (пусто — снять)" "")
            [[ -n "$mx" ]] && payload="{\"max_unique_ips\":${mx}}" \
                           || payload='{"max_unique_ips":null}'
            ;;
        4)
            local cur
            cur=$(printf '%s' "$api_data" | python3 -c "
import sys,json
n='${name}'
d=json.load(sys.stdin)
u=next((x for x in d['data'] if x['username']==n),None)
print('true' if u and u.get('enabled',True) else 'false')
" 2>/dev/null || echo "true")
            [[ "$cur" == "true" ]] && payload='{"enabled":false}' || payload='{"enabled":true}'
            ;;
        *) return ;;
    esac

    [[ -z "$payload" ]] && return
    printf '  Применяю... '
    local result
    result=$(curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/${name}" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null || true)
    printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null \
        && ok_inline "Применено без перезапуска" \
        || { fail_inline "Ошибка"; printf '  %s\n' "$result"; }
    sleep 2
}

_users_show_link() {
    local api_data="$1"
    printf '\n%s─── Ссылка пользователя ───%s\n\n' "$C_BLD" "$C_RST"
    local name; name=$(prompt_value "Имя пользователя" ""); [[ -z "$name" ]] && return

    local secret
    secret=$(printf '%s' "$api_data" | python3 -c "
import sys,json
n='${name}'
d=json.load(sys.stdin)
u=next((x for x in d['data'] if x['username']==n),None)
if not u: print(''); sys.exit()
links=u.get('links',{}).get('tls',[])
if not links: print(''); sys.exit()
s=links[0].split('secret=')[-1]
print(s[2:34] if s[:2] in ('ee','dd') else s[:32])
" 2>/dev/null || echo "")

    if [[ -z "$secret" ]]; then
        fail_inline "Пользователь не найден или нет TLS-ссылки"; sleep 2; return
    fi

    local DOMAIN="" TLS_DOMAIN=""
    [[ -f .env ]] && source .env 2>/dev/null || true
    local hex_mask
    hex_mask=$(printf '%s' "${TLS_DOMAIN:-$TLS_MASK_DOMAIN}" | xxd -ps | tr -d '\n')
    printf '%sОсновная (FakeTLS):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n\n' \
        "$C_GRN$C_BLD" "$C_RST" "$DOMAIN" "$PROXY_PORT" "$secret" "$hex_mask"
    printf '%sРезервная (dd):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' \
        "$C_CYN$C_BLD" "$C_RST" "$DOMAIN" "$PROXY_PORT" "$secret"
    pause
}

_users_delete() {
    local api_data="$1"
    printf '\n%s─── Удалить пользователя ───%s\n\n' "$C_BLD" "$C_RST"
    local name; name=$(prompt_value "Имя пользователя" ""); [[ -z "$name" ]] && return

    if [[ "$name" == "user1" ]]; then
        fail_inline "user1 — основной, удалить нельзя"; sleep 2; return
    fi
    if ! confirm "Удалить ${name}? Ссылка перестанет работать." N; then return; fi

    printf '  Удаляю... '
    local result
    result=$(curl -s -X DELETE "http://127.0.0.1:${PROXY_API_PORT}/v1/users/${name}" 2>/dev/null || true)
    if printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        ok_inline "Удалён"
    else
        printf '%s\n  DELETE не поддерживается — выключаю пользователя...%s ' "$C_YLW" "$C_RST"
        result=$(curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/${name}" \
            -H "Content-Type: application/json" -d '{"enabled":false}' 2>/dev/null || true)
        printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null \
            && ok_inline "Выключен (ссылка не работает)" || fail_inline "Ошибка API"
    fi
    sleep 2
}

action_manage_users() {
    while true; do
        print_header
        printf '%s═══ Пользователи ═══%s\n\n' "$C_BLD" "$C_RST"

        local api_data
        api_data=$(curl -s "http://127.0.0.1:${PROXY_API_PORT}/v1/users" 2>/dev/null || true)
        if ! printf '%s' "$api_data" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
            fail_inline "telemt API недоступен — сервис запущен?"
            pause; return
        fi

        _users_print_table "$api_data"

        printf '\n  %s1)%s Добавить   %s2)%s Изменить/квота   %s3)%s Ссылка   %s4)%s Удалить   %s0)%s Назад\n' \
            "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_DIM" "$C_RST"
        printf '%sВыбор:%s ' "$C_BLD" "$C_RST"
        local sub
        read -r sub </dev/tty || break
        case "$sub" in
            1) _users_add ;;
            2) _users_edit "$api_data" ;;
            3) _users_show_link "$api_data" ;;
            4) _users_delete "$api_data" ;;
            0|"") break ;;
            *) printf '%sНеверный выбор%s\n' "$C_RED" "$C_RST"; sleep 1 ;;
        esac
    done
}

# ============ MAIN ============

main() {
    require_root
    ensure_deps
    ensure_shortcut

    while true; do
        print_header
        print_status
        print_menu
        printf '%sВыбор:%s ' "$C_BLD" "$C_RST"
        local choice
        read -r choice </dev/tty || { clear; exit 0; }
        case "$choice" in
            1)  action_check_domain ;;
            2)  action_deploy ;;
            3)  action_security ;;
            4)  action_status ;;
            5)  action_logs ;;
            6)  action_restart ;;
            7)  action_stop ;;
            8)  action_start ;;
            9)  action_show_link ;;
            10) action_system_update ;;
            11) action_self_update ;;
            12) action_install_shortcut ;;
            13) action_uninstall ;;
            14) action_check_telegram ;;
            15) action_update_telemt ;;
            16) action_set_adtag ;;
            17) action_stats ;;
            18) action_manage_users ;;
            19) action_bot ;;
            0|q|Q|exit|"") clear; exit 0 ;;
            *) printf '%sНеверный выбор: %s%s\n' "$C_RED" "$choice" "$C_RST"; sleep 1 ;;
        esac
    done
}

main "$@"
