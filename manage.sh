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

# Публичный IPv4 сервера — для бездоменного режима (ссылки на IP) и проверок DNS.
detect_public_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
         curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
         curl -s --max-time 5 https://icanhazip.com 2>/dev/null)
    ip=$(printf '%s' "$ip" | tr -d '[:space:]')
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
    fi
    printf '%s' "$ip"
}

check_dns_health() {
    local domain="$1"
    local errors=0 warnings=0

    printf '\n%sПроверка DNS и доступности:%s\n' "$C_BLD" "$C_RST"

    local server_ip
    server_ip=$(detect_public_ip)
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
        if [[ -n "${DOMAIN:-}" ]]; then
            domain="$DOMAIN"
        else
            domain="${C_DIM}без домена (ссылки на IP)${C_RST}"
        fi
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

    step "1/4" "Домен (A-запись должна указывать на этот VPS; пусто — режим без домена)"
    printf '       %sБез домена%s ссылки строятся на публичный IP: РКН нечего резолвить,\n' "$C_BLD" "$C_RST"
    printf '       но при смене IP придётся раздать новые ссылки.\n'
    DOMAIN=$(prompt_value "Введи домен (пусто — без домена)" "$DOMAIN")
    local LINK_HOST="$DOMAIN"
    if [[ -z "$DOMAIN" ]]; then
        LINK_HOST=$(detect_public_ip)
        if [[ -z "$LINK_HOST" ]]; then
            fail_inline "Не удалось определить публичный IP сервера"
            pause; return
        fi
        ok_inline "Режим без домена: ссылки будут на IP ${LINK_HOST}"
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

    step "3/4" "TLS-маскировка"
    local USE_OWN_DOMAIN=false TLS_EMAIL="" CERT_MODE="http01"
    if [[ -z "$DOMAIN" ]]; then
        printf '       Без домена маскируемся под CDN-домен (свой сертификат выпустить нельзя).\n'
        printf '       Ищу доступный CDN с этого VPS...\n'
        if detect_tls_domain noisy; then
            ok_inline "Авто-выбран: ${TLS_MASK_DOMAIN}"
        else
            fail_inline "Ни один CDN-домен недоступен с этого VPS — нет исходящего HTTPS?"
            pause; return
        fi
    else
    printf '       %sСвоим доменом%s (%s) — рекомендуется: совместимо с VLESS/VPN-клиентами,\n' \
        "$C_BLD" "$C_RST" "$DOMAIN"
    printf '       telemt выпустит Let'\''s Encrypt cert + nginx:8443 + NAT-редирект.\n'
    printf '       %sCDN-домен%s — проще, но конфликтует с VPN-клиентами (sniff override).\n\n' "$C_BLD" "$C_RST"
    if confirm "Маскировать своим доменом ${DOMAIN}?" Y; then
        USE_OWN_DOMAIN=true
        TLS_MASK_DOMAIN="$DOMAIN"
        ok_inline "Маска: ${DOMAIN} (свой домен)"
        printf '\n       %sСертификат:%s HTTP-01 — для одного сервера (порт 80).\n' "$C_BLD" "$C_RST"
        printf '       DNS-01 (reg.ru) — если домен на нескольких VPS (round-robin, Вариант 2).\n'
        if confirm "Домен на нескольких серверах? (DNS-01 reg.ru)" N; then
            CERT_MODE="dns01-regru"
            ok_inline "Сертификат: DNS-01 через reg.ru API"
        else
            TLS_EMAIL=$(prompt_value "Email для Let's Encrypt (пусто — без email)" "")
        fi
    else
        printf '       Ищу доступный CDN с этого VPS...\n'
        if detect_tls_domain noisy; then
            ok_inline "Авто-выбран: ${TLS_MASK_DOMAIN}"
        else
            fail_inline "Ни один CDN-домен недоступен с этого VPS — нет исходящего HTTPS?"
            pause; return
        fi
    fi
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

    if [[ -n "$DOMAIN" ]] && ! check_dns_health "$DOMAIN"; then
        printf '\n'
        if ! confirm "Продолжить несмотря на ошибки? (не рекомендую)" N; then
            return
        fi
    fi

    printf '\n%sИтого:%s\n' "$C_BLD" "$C_RST"
    if [[ -n "$DOMAIN" ]]; then
        printf '  Домен:      %s\n' "$DOMAIN"
    else
        printf '  Домен:      без домена (ссылки на IP %s)\n' "$LINK_HOST"
    fi
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
        -e "s/__PUBLIC_HOST__/$LINK_HOST/g" \
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
Environment=RUST_LOG=warn,telemt::maestro::admission=info,telemt::transport::middle_proxy=info
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

    # Часы должны быть верны ДО старта telemt: при скью >30с middle-серверы отвергают
    # ME-хендшейк → direct-fallback → AD_TAG не доставляется (нет спонсорского канала).
    printf '  Синхронизирую часы (NTP)... '
    if setup_ntp; then
        printf '%ssynchronized%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sконфиг применён, синхронизации пока нет (проверь UDP/123)%s\n' "$C_YLW" "$C_RST"
    fi

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

    # H2: TLS-фронтенд своим доменом (nginx:8443 + Let's Encrypt + NAT-редирект),
    # чтобы деплой с нуля воспроизводил рабочую конфигурацию, а не настраивать руками.
    if $USE_OWN_DOMAIN; then
        printf '\n%sНастраиваю TLS-фронтенд (свой домен):%s\n' "$C_BLD" "$C_RST"
        if setup_tls_frontend "$DOMAIN" "$TLS_EMAIL" "$CERT_MODE"; then
            printf '  Перезапускаю telemt для захвата TLS-профиля... '
            systemctl restart "$TELEMT_SVC" >/dev/null 2>&1 || true
            sleep 5
            systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1 \
                && printf '%sok%s\n' "$C_GRN" "$C_RST" \
                || fail_inline "telemt не поднялся после фронтенда — проверь логи (пункт 5)"
        else
            printf '%s  TLS-фронтенд не настроен полностью — проверь домен и порт 80%s\n' "$C_YLW" "$C_RST"
        fi
    fi

    local AD_TAG=""
    [[ -f .env ]] && { source .env 2>/dev/null || true; }
    if [[ -n "${AD_TAG:-}" ]]; then
        printf '  Применяю AD_TAG из .env (всем пользователям)... '
        if apply_ad_tag_all "$AD_TAG"; then
            ok_inline "AD_TAG применён"
        else
            printf '%sпропущено (проверь пункт 16)%s\n' "$C_YLW" "$C_RST"
        fi
    fi

    # H2: сбор статистики/мониторинг (cron + logrotate) + постоянство iptables
    printf '  Настраиваю аудит и мониторинг... '
    if setup_audit_cron; then printf '%sok%s\n' "$C_GRN" "$C_RST"; else printf '%sпропущено%s\n' "$C_YLW" "$C_RST"; fi
    persist_iptables >/dev/null 2>&1 || true

    local hex_mask link_ee link_dd
    hex_mask=$(printf '%s' "$TLS_MASK_DOMAIN" | xxd -ps | tr -d '\n')
    link_ee="https://t.me/proxy?server=${LINK_HOST}&port=${PROXY_PORT}&secret=ee${BASE_SECRET}${hex_mask}"
    link_dd="https://t.me/proxy?server=${LINK_HOST}&port=${PROXY_PORT}&secret=dd${BASE_SECRET}"

    printf '\n%s═══ Готово ═══%s\n\n' "$C_GRN$C_BLD" "$C_RST"
    printf '%sОсновная ссылка (FakeTLS):%s\n%s\n\n' "$C_BLD" "$C_RST" "$link_ee"
    printf '%sДля пользователей с VPN (VLESS и др.):%s\n%s\n\n' "$C_BLD" "$C_RST" "$link_dd"
    printf '%sНастройка безопасности:%s запусти пункт 3 (ufw, keepalive, rate-limit)\n' "$C_BLD" "$C_RST"
    [[ -z "${AD_TAG:-}" ]] && printf '%sСпонсорский канал:%s запусти пункт 16 (AD_TAG)\n' "$C_BLD" "$C_RST"

    pause
}

# Применяет AD_TAG (спонсорский канал) ВСЕМ пользователям telemt.
# AD_TAG общий для прокси — раньше был захардкожен на user1, теперь не зависит
# ни от одного конкретного юзера. Пустой аргумент = очистить тег у всех.
# Возвращает успех, только если все PATCH прошли и хотя бы один юзер существует.
apply_ad_tag_all() {
    local tag="$1" payload users u ok=0 fail=0
    if [[ -n "$tag" ]]; then
        payload="{\"user_ad_tag\":\"${tag}\"}"
    else
        payload='{"user_ad_tag":null}'
    fi
    users=$(curl -s "http://127.0.0.1:${PROXY_API_PORT}/v1/users" 2>/dev/null \
        | python3 -c "import sys,json; print('\n'.join(u['username'] for u in json.load(sys.stdin).get('data',[])))" 2>/dev/null || true)
    [[ -z "$users" ]] && return 1
    for u in $users; do
        if curl -s -X PATCH "http://127.0.0.1:${PROXY_API_PORT}/v1/users/${u}" \
            -H "Content-Type: application/json" -d "$payload" 2>/dev/null \
            | python3 -c "import sys,json; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    [[ $fail -eq 0 && $ok -gt 0 ]]
}

# Ставит iptables-persistent (если нет) и сохраняет ВСЕ текущие правила в
# /etc/iptables/rules.v4 — иначе rate-limit и NAT-редирект НЕ переживут
# перезагрузку (H1). netfilter-persistent.service восстанавливает их при boot.
persist_iptables() {
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections 2>/dev/null || true
        echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || return 1
    fi
    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    return 0
}

# Выпускает Let's Encrypt cert через DNS-01 (reg.ru API) — работает при round-robin
# DNS (несколько A-записей, Вариант 2), без порта 80. acme.sh сам ставит cron на
# авто-обновление с reloadcmd. Путь к серту возвращается в глобал CERT_DIR.
# Нужен API-доступ в ЛК reg.ru: включить API и добавить IP этого сервера в allowlist.
obtain_cert_regru_dns01() {
    local domain="$1"
    local acme="/root/.acme.sh/acme.sh"

    if [[ ! -x "$acme" ]]; then
        printf '  Ставлю acme.sh... '
        if curl -fsSL https://get.acme.sh | sh -s email="acme@${domain}" >/dev/null 2>&1; then
            printf '%sok%s\n' "$C_GRN" "$C_RST"
        else
            fail_inline "не удалось установить acme.sh"; return 1
        fi
    fi
    [[ -x "$acme" ]] || { fail_inline "acme.sh не найден после установки"; return 1; }

    printf '\n  %sreg.ru API: в ЛК reg.ru включи API и добавь IP этого сервера в allowlist.%s\n' "$C_YLW" "$C_RST"
    local ru_user ru_pass
    ru_user=$(prompt_value "REG.RU API логин (логин аккаунта reg.ru)" "")
    ru_pass=$(prompt_value "REG.RU API пароль (API-пароль из ЛК)" "")
    if [[ -z "$ru_user" || -z "$ru_pass" ]]; then
        fail_inline "Логин/пароль reg.ru пустые"; return 1
    fi

    printf '  Выпускаю cert через DNS-01 (reg.ru)... '
    if REGRU_API_Username="$ru_user" REGRU_API_Password="$ru_pass" \
        "$acme" --issue --dns dns_regru -d "$domain" --server letsencrypt >/dev/null 2>&1; then
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        fail_inline "acme.sh не выпустил cert (проверь API reg.ru и allowlist IP в ЛК)"
        return 1
    fi

    CERT_DIR="/etc/telemt-tls/${domain}"
    mkdir -p "$CERT_DIR"
    printf '  Устанавливаю cert + авто-обновление... '
    if "$acme" --install-cert -d "$domain" \
        --key-file       "${CERT_DIR}/privkey.pem" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl restart nginx; systemctl restart telemt" >/dev/null 2>&1; then
        printf '%sok%s\n' "$C_GRN" "$C_RST"
        return 0
    fi
    fail_inline "acme.sh install-cert не прошёл"; return 1
}

# Настраивает синхронизацию часов через ДОСТУПНЫЙ NTP. Критично: при скью >30с
# middle-серверы Telegram отвергают ME-хендшейк telemt → direct-fallback → AD_TAG
# не доставляется (пропадает спонсорский канал). Многие провайдеры режут UDP/123 к
# дефолтным ntp.ubuntu.com/pool.ntp.org (timesyncd висит с Packet count: 0, часы
# дрейфуют). Cloudflare NTP (162.159.200.x) обычно проходит — ставим его основным.
# Идемпотентно.
setup_ntp() {
    mkdir -p /etc/systemd/timesyncd.conf.d
    cat > /etc/systemd/timesyncd.conf.d/10-reachable-ntp.conf <<'EOF'
# Провайдер часто режет UDP/123 к ntp.ubuntu.com/pool.ntp.org (timesyncd не
# синхронит → часы убегают → ломается ME-хендшейк telemt → пропадает канал спонсора).
# Cloudflare NTP доступен по UDP/123 — основной; google/pool как fallback.
[Time]
NTP=time.cloudflare.com 162.159.200.1 162.159.200.123
FallbackNTP=time.google.com pool.ntp.org
EOF
    timedatectl set-ntp true >/dev/null 2>&1 || true
    systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
    systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    # ждём первую успешную синхронизацию (до ~12с)
    local i
    for i in $(seq 1 12); do
        [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && return 0
        sleep 1
    done
    # не синхронизировался за окно — вернём «частичный успех»: конфиг применён,
    # синхронизация может подтянуться позже (или UDP/123 режется и к Cloudflare)
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]
}

# Поднимает TLS-фронтенд для маскировки СВОИМ доменом (VPN/VLESS-совместимость):
# реальный Let's Encrypt cert + nginx на 8443 + NAT-редирект 443→8443 +
# пин self-fetch в /etc/hosts. Идемпотентно. Закрывает H2.
# cert_mode: "http01" (один сервер, certbot standalone) | "dns01-regru" (round-robin).
setup_tls_frontend() {
    local domain="$1" email="${2:-}" cert_mode="${3:-http01}"
    local server_ip
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
              || curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
    server_ip=$(printf '%s' "$server_ip" | tr -d '[:space:]')

    local cert_fc cert_key
    if [[ "$cert_mode" == "dns01-regru" ]]; then
        printf '  Ставлю nginx... '
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/dev/null 2>&1; then
            fail_inline "apt не смог поставить nginx"; return 1
        fi
        printf '%sok%s\n' "$C_GRN" "$C_RST"
        CERT_DIR=""
        obtain_cert_regru_dns01 "$domain" || return 1
        cert_fc="${CERT_DIR}/fullchain.pem"
        cert_key="${CERT_DIR}/privkey.pem"
    else
        printf '  Ставлю nginx + certbot... '
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot >/dev/null 2>&1; then
            fail_inline "apt не смог поставить nginx/certbot"; return 1
        fi
        printf '%sok%s\n' "$C_GRN" "$C_RST"
        cert_fc="/etc/letsencrypt/live/${domain}/fullchain.pem"
        cert_key="/etc/letsencrypt/live/${domain}/privkey.pem"
        # Сертификат (standalone, http-01 на порту 80). Если уже есть — переиспользуем.
        if [[ ! -f "$cert_fc" ]]; then
            printf '  Выпускаю сертификат Let'\''s Encrypt для %s... ' "$domain"
            systemctl stop nginx >/dev/null 2>&1 || true   # освобождаем порт 80
            local reg=(--register-unsafely-without-email)
            [[ -n "$email" ]] && reg=(-m "$email")
            if certbot certonly --standalone --non-interactive --agree-tos \
                "${reg[@]}" -d "$domain" --http-01-port 80 >/dev/null 2>&1; then
                printf '%sok%s\n' "$C_GRN" "$C_RST"
            else
                fail_inline "certbot не выпустил cert (порт 80 занят/закрыт извне, DNS не на этот VPS?)"
                return 1
            fi
        else
            printf '  Сертификат %s уже есть — использую\n' "$domain"
        fi
    fi

    # nginx на 8443 с реальным сертом — telemt берёт отсюда TLS-профиль через mask_port
    printf '  Настраиваю nginx:8443... '
    cat > /etc/nginx/sites-available/tg-cert <<NGINX
server {
    listen 8443 ssl;
    server_name ${domain};

    ssl_certificate     ${cert_fc};
    ssl_certificate_key ${cert_key};

    access_log off;
    error_log /dev/null;

    location / {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/tg-cert /etc/nginx/sites-enabled/tg-cert
    rm -f /etc/nginx/sites-enabled/default   # убираем дефолт с порта 80
    if nginx -t >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx >/dev/null 2>&1 || true
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        fail_inline "nginx -t не прошёл — проверь конфиг"; return 1
    fi

    # КРИТИЧНО для round-robin: telemt резолвит tls_domain для self-fetch серта.
    # При нескольких A-записях он может пойти за сертом на ДРУГОЙ узел (там telemt,
    # а не nginx) → профиль не обновится. Пиним домен в /etc/hosts на СВОЙ IP →
    # NAT-редирект ниже уводит self-fetch на локальный nginx:8443. Клиентов не
    # касается (у них настоящий DNS).
    if [[ -n "$server_ip" ]]; then
        local hosts_line="${server_ip} ${domain}"
        if ! grep -qF "$hosts_line" /etc/hosts 2>/dev/null; then
            printf '%s  # telemt self-fetch TLS-профиля → локальный nginx\n' "$hosts_line" >> /etc/hosts
        fi
    fi

    # NAT-редирект: self-fetch telemt'ом серта по своему IP:443 уходит в петлю на
    # самого себя. Перенаправляем локально-сгенерированный трафик на nginx:8443.
    if [[ -n "$server_ip" ]]; then
        printf '  NAT-редирект %s:443 → 8443... ' "$server_ip"
        iptables -t nat -D OUTPUT -p tcp -d "$server_ip" --dport 443 -j REDIRECT --to-ports 8443 2>/dev/null || true
        iptables -t nat -I OUTPUT -p tcp -d "$server_ip" --dport 443 -j REDIRECT --to-ports 8443
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    fi

    # deploy-hook нужен только для certbot (http-01). При DNS-01 reg.ru обновление и
    # перезагрузку делает сам acme.sh (--reloadcmd при --install-cert).
    if [[ "$cert_mode" != "dns01-regru" ]]; then
        printf '  Ставлю certbot deploy-hook... '
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/telemt-tls-reload.sh <<'HOOK'
#!/bin/bash
# Авто-перезагрузка nginx и telemt после обновления Let's Encrypt серта.
set -eu
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
systemctl restart telemt 2>/dev/null || true
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/telemt-tls-reload.sh
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    fi

    persist_iptables   # NAT-правило тоже должно пережить перезагрузку
    return 0
}

# Ставит сбор статистики (audit.jsonl каждые 5 мин) + монитор RAM/диск/сервис
# с алертом в Telegram + ротацию лога. Раньше настраивалось вручную (H2).
setup_audit_cron() {
    cat > /usr/local/bin/telemt-audit.sh <<AUDIT
#!/bin/bash
curl -s http://127.0.0.1:${PROXY_API_PORT}/v1/users | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
if not d.get('ok'):
    sys.exit(1)
d['ts'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
print(json.dumps(d, ensure_ascii=False))
" >> ${AUDIT_LOG}
AUDIT
    chmod +x /usr/local/bin/telemt-audit.sh

    {
        printf '#!/bin/bash\n'
        printf '# Монитор RAM/диск/telemt с алертом в Telegram (антидребезг 1 час).\n'
        printf 'ENV_FILE="%s/.env"\n' "$SCRIPT_DIR"
        cat <<'MON'
FLAG_FILE="/tmp/telemt-monitor-alerted"
ALERT_COOLDOWN=3600

BOT_TOKEN=""
BOT_CHAT_ID=""
if [[ -f "$ENV_FILE" ]]; then
    BOT_TOKEN=$(grep -m1 '^BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
    BOT_CHAT_ID=$(grep -m1 '^BOT_CHAT_ID=' "$ENV_FILE" | cut -d= -f2-)
fi
[[ -z "$BOT_TOKEN" || -z "$BOT_CHAT_ID" ]] && exit 0

tg_send() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${BOT_CHAT_ID}\",\"text\":\"$1\",\"parse_mode\":\"HTML\"}" \
        > /dev/null
}

ALERT=""
RAM_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
SWAP_USED=$(free -m  | awk '/^Swap:/ {print $3}')

if [[ "$RAM_AVAIL" -lt 200 ]]; then
    ALERT="${ALERT}⚠️ RAM: доступно ${RAM_AVAIL} MB (критично &lt; 200 MB)\n"
fi
if [[ "$SWAP_TOTAL" -gt 0 ]]; then
    SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
    if [[ "$SWAP_PCT" -gt 80 ]]; then
        ALERT="${ALERT}⚠️ Swap: ${SWAP_PCT}% заполнен (${SWAP_USED}/${SWAP_TOTAL} MB)\n"
    fi
fi
if ! systemctl is-active --quiet telemt; then
    ALERT="${ALERT}🔴 telemt: сервис не запущен!\n"
fi
DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
if [[ "$DISK_PCT" -gt 85 ]]; then
    ALERT="${ALERT}💾 Диск: ${DISK_PCT}% заполнен\n"
fi

# Часы: рассинхрон NTP уводит скью >30с → middle-серверы отвергают ME-хендшейк
# → telemt уходит в direct-fallback → AD_TAG не доставляется (пропадает спонсорский канал).
# Ранний индикатор — ловит ДО поломки канала.
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    ALERT="${ALERT}🕐 Часы: NTP не синхронизирован — скью ломает ME-хендшейк, под угрозой канал спонсора\n"
fi

# ME-пул: при живом telemt мало ESTAB к middle :8888 = direct-fallback (AD_TAG не идёт).
# Подтверждающий симптом. Гард по аптайму >120с, чтобы не алертить на свежем старте (пул растёт ~20с).
if systemctl is-active --quiet telemt; then
    ME_PID=$(systemctl show -p MainPID --value telemt 2>/dev/null)
    ME_UP=$(ps -o etimes= -p "$ME_PID" 2>/dev/null | tr -d ' ')
    ME_CONNS=$(ss -tn state established 2>/dev/null | grep -c ':8888')
    if [[ -n "$ME_UP" && "$ME_UP" -gt 120 && "$ME_CONNS" -lt 5 ]]; then
        ALERT="${ALERT}📡 ME-пул: соединений к middle :8888 = ${ME_CONNS} (норма ~30-40) — спонсорский канал не доставляется (проверь часы: timedatectl)\n"
    fi
fi

# Качели ME-пула: любой fallback_reason= (fast_not_ready / strict_grace) = cutover, который
# закрывает ВСЕ живые сессии (Cutover affected ... closing client connection). До фикса
# me2dc_fast=false было 14-25/час днём; после — 0 за 20 мин. Порог 5 — сигнал регресса.
CUTOVERS=$(journalctl -u telemt --since "1 hour ago" --no-pager -o cat 2>/dev/null | grep -c 'fallback_reason=')
if [[ "${CUTOVERS:-0}" -gt 5 ]]; then
    ALERT="${ALERT}🔁 ME-пул: ${CUTOVERS} cutover за час (порог 5) — все сессии рвутся (провал ME-пула к DC2 дольше 6с grace)\n"
fi

if [[ -z "$ALERT" ]]; then
    rm -f "$FLAG_FILE"
    exit 0
fi
if [[ -f "$FLAG_FILE" ]]; then
    LAST=$(cat "$FLAG_FILE")
    NOW=$(date +%s)
    if (( NOW - LAST < ALERT_COOLDOWN )); then
        exit 0
    fi
fi
date +%s > "$FLAG_FILE"
tg_send "🚨 <b>MTProxy Monitor</b>\n\n${ALERT}"
MON
    } > /usr/local/bin/telemt-monitor.sh
    chmod +x /usr/local/bin/telemt-monitor.sh

    cat > /etc/cron.d/telemt-audit <<CRON
# Снапшот статистики пользователей каждые 5 минут
*/5 * * * * root /usr/local/bin/telemt-audit.sh
# Мониторинг памяти и состояния сервиса каждые 5 минут
*/5 * * * * root /usr/local/bin/telemt-monitor.sh
CRON

    cat > /etc/logrotate.d/telemt-audit <<'ROT'
/var/log/telemt-audit.jsonl {
    rotate 30
    daily
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
ROT
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
    printf '  • на порт 443 добавлен iptables rate-limit (20 SYN/сек, всплеск до 60 на IP)\n'
    printf '  • правила iptables сохранены и переживут перезагрузку\n'
    printf '  • установлен fail2ban\n'
    printf '  • включены автообновления безопасности\n'
    printf '  • применены sysctl-настройки (TCP keepalive — фикс залипания iOS)\n'
    printf '  • настроена синхронизация часов (NTP на Cloudflare — без неё пропадает канал спонсора)\n\n'

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
    # порт 80 нужен certbot для обновления Let's Encrypt серта (standalone http-01)
    ufw allow 80/tcp comment "ACME http-01 renew" >/dev/null 2>&1 || true
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

    # hashlimit: burst-толерантный rate-limit (устойчиво 50 SYN/сек, всплеск до 200 на IP).
    # На 20/60 счётчик DROP набрал 290k SYN против 3.97M ACCEPT (~7%): за одним
    # адресом провайдерского NAT или VPN-выхода абоненты выбирают лимит сообща.
    # ВАЖНО: Telegram-клиент при загрузке медиа открывает до 8 параллельных
    # соединений на КАЖДЫЙ DC, а за VPN/VLESS-выходом сидят десятки юзеров
    # с ОДНОГО IP. Старая схема xt_recent (15 SYN/5с; потолок модуля — 20)
    # резала такие всплески → тормоза медиа и отвалы через VPN.
    # hashlimit пропускает всплеск до 60 SYN и 20/сек устойчиво,
    # но режет реальный SYN-флуд (сотни-тысячи в секунду).
    printf '  Добавляю iptables rate-limit на порт 443... '
    if modprobe xt_hashlimit 2>/dev/null; then
        printf 'hashlimit '
        # удаляем старые правила xt_recent (устаревшие схемы) и прошлые hashlimit
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --rcheck --seconds 1 -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --update --seconds 5 --hitcount 15 -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m hashlimit --hashlimit-name mtp443 --hashlimit-mode srcip --hashlimit-upto 20/sec --hashlimit-burst 60 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -m hashlimit --hashlimit-name mtp443 --hashlimit-mode srcip --hashlimit-upto 50/sec --hashlimit-burst 200 -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 443 --syn -j DROP 2>/dev/null || true
        # Сначала ACCEPT в пределах лимита (позиция 1), затем DROP сразу под ним
        # (позиция 2) — нет «окна», когда дропается весь новый SYN
        iptables -I INPUT 1 -p tcp --dport 443 --syn -m hashlimit --hashlimit-name mtp443 --hashlimit-mode srcip --hashlimit-upto 50/sec --hashlimit-burst 200 -j ACCEPT
        iptables -I INPUT 2 -p tcp --dport 443 --syn -j DROP
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sxt_hashlimit недоступен — пропущено%s\n' "$C_YLW" "$C_RST"
    fi

    # Точечный бан: адреса из /etc/telemt/banlist.txt (по одному в строке). Цепочка
    # стоит ПЕРЕД hashlimit ACCEPT — ufw-правила туда не дотягиваются (ACCEPT раньше
    # ufw-цепочек), поэтому «ufw deny» для порта 443 здесь не работает.
    # Кандидаты — лидеры beobachten.txt: один домашний IP давал 100k попыток/сутки.
    printf '  Применяю бан-лист (/etc/telemt/banlist.txt)... '
    iptables -N mtp443-ban 2>/dev/null || iptables -F mtp443-ban
    BAN_N=0
    if [[ -f /etc/telemt/banlist.txt ]]; then
        while read -r ip; do
            [[ -z "$ip" || "$ip" == \#* ]] && continue
            iptables -A mtp443-ban -s "$ip" -j DROP && BAN_N=$((BAN_N+1))
        done < /etc/telemt/banlist.txt
    fi
    iptables -C INPUT -p tcp --dport 443 -j mtp443-ban 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -j mtp443-ban
    printf '%s%s адресов%s\n' "$C_GRN" "$BAN_N" "$C_RST"

    # H1: ставим iptables-persistent и сохраняем правила (rate-limit + NAT-редирект),
    # иначе после reboot они теряются.
    printf '  Делаю правила iptables постоянными... '
    if persist_iptables; then
        printf '%sok%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sне удалось (поставь iptables-persistent вручную)%s\n' "$C_YLW" "$C_RST"
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
# conntrack: дефолтный max 65536 переполнялся retry-штормом (table full =
# ядро дропает пакеты НОВЫХ соединений → «прокси не подключается»).
# 262144 записей ≈ 80 МБ RAM worst-case — допустимо для VPS от 2 ГБ.
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
# conntrack: короткоживущие состояния чистим быстрее (флуд-коннекты
# не должны висеть в таблице по 60-120 секунд)
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
# listen-очередь: при всплесках SYN переполнялась (см. netstat -s overflow);
# telemt берёт backlog = min(своего, somaxconn) при старте
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
# PMTU: client_mss=tspu зажимает MSS, а VPN-инкапсуляция у клиента режет путь
# ещё сильнее. Без проб ядро не выходит из чёрной дыры PMTU — хендшейк MTProto
# приходит нулевой длины (см. [expected_64_got_0] в /opt/telemt/beobachten.txt).
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024
# BBR: маршруты до РФ-абонентов теряют пакеты, cubic на потерях складывает окно
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Буферы сокетов: дефолтные 208 КБ не дают BBR раскрыть окно (скорость медиа).
# Поднимаем ТОЛЬКО потолок — ядро растит буфер автотюнингом по BDP. Значения
# по умолчанию не трогаем: на 2 ГБ RAM и ~1400 сокетах поднятый default
# (официальный HIGH_LOAD-гайд предлагает 256 КБ) стоил бы до ~350 МБ.
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 131072 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
# swap: на 2 ГБ RAM ядро с swappiness=60 выталкивало telemt в swap (135 МБ RSS
# в swap при забитом swap) — стопоры по 20+ таймаутов connect к DC за секунду,
# ME-пул уходил в not-ready и cutover рвал все сессии каждые 3-5 минут днём.
vm.swappiness = 10
EOF
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr > /etc/modules-load.d/tcp_bbr.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    # journald: telemt при RUST_LOG=warn пишет ~150k строк/час, без лимита журнал
    # разрастался до 1.5 ГБ и держал 100 МБ RSS на journald — на 2 ГБ RAM это swap.
    printf '  Ограничиваю journald (200 МБ)... '
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/telemt.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=3day
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    printf '%sok%s\n' "$C_GRN" "$C_RST"

    # Синхронизация часов: скью >30с ломает ME-хендшейк → пропадает спонсорский канал.
    printf '  Настраиваю синхронизацию часов (NTP)... '
    if setup_ntp; then
        printf '%ssynchronized%s\n' "$C_GRN" "$C_RST"
    else
        printf '%sконфиг применён, но синхронизации пока нет (проверь UDP/123)%s\n' "$C_YLW" "$C_RST"
    fi

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
    printf '%s═══ Ссылки пользователей ═══%s\n\n' "$C_BLD" "$C_RST"
    if [[ ! -f .env ]]; then
        fail_inline ".env не найден. Сначала установи прокси."
        pause; return
    fi

    local DOMAIN="" TLS_DOMAIN=""
    # shellcheck source=/dev/null
    source .env
    local mask="${TLS_DOMAIN:-$TLS_MASK_DOMAIN}"
    local host="${DOMAIN:-$(detect_public_ip)}"

    if [[ -z "$host" || -z "$mask" ]]; then
        fail_inline "Не определить хост для ссылок: нет DOMAIN в .env и не определяется публичный IP"
        pause; return
    fi

    # Ссылки берём из API по каждому юзеру — больше не зависим от BASE_SECRET/user1
    local api_data
    api_data=$(curl -s "http://127.0.0.1:${PROXY_API_PORT}/v1/users" 2>/dev/null || true)
    if ! printf '%s' "$api_data" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
        fail_inline "telemt API недоступен — сервис запущен?"
        pause; return
    fi

    printf '%s' "$api_data" | DOMAIN="$host" PORT="$PROXY_PORT" MASK="$mask" python3 -c '
import sys, json, os
domain = os.environ["DOMAIN"]; port = os.environ["PORT"]; mask = os.environ["MASK"]
hexmask = mask.encode().hex()
GRN="\033[32m"; CYN="\033[36m"; BLD="\033[1m"; RST="\033[0m"
for u in json.load(sys.stdin).get("data", []):
    tls = u.get("links", {}).get("tls", [])
    if not tls:
        continue
    s = tls[0].split("secret=")[-1]
    secret = s[2:34] if s[:2] in ("ee", "dd") else s[:32]
    ee = f"https://t.me/proxy?server={domain}&port={port}&secret=ee{secret}{hexmask}"
    dd = f"https://t.me/proxy?server={domain}&port={port}&secret=dd{secret}"
    name = u["username"]
    icon = "" if u.get("enabled", True) else " (выключен)"
    print(f"{BLD}{name}{icon}{RST}")
    print(f"  {GRN}FakeTLS:{RST} {ee}")
    print(f"  {CYN}dd:     {RST} {dd}")
    print()
'
    printf '%sМаска ee: %s | dd-режим работает с любым VPN-клиентом%s\n' "$C_DIM" "$mask" "$C_RST"
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
                local link_host="${DOMAIN:-$(detect_public_ip)}"
                sed -e "s/__BASE_SECRET__/$BASE_SECRET/g" \
                    -e "s/__TLS_DOMAIN__/${TLS_DOMAIN:-$TLS_MASK_DOMAIN}/g" \
                    -e "s/__PUBLIC_HOST__/$link_host/g" \
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
                    apply_ad_tag_all "$AD_TAG" >/dev/null 2>&1 || true
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
    iptables -D INPUT -p tcp --dport 443 -j mtp443-ban 2>/dev/null || true
    iptables -F mtp443-ban 2>/dev/null || true; iptables -X mtp443-ban 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --rcheck --seconds 1 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --update --seconds 5 --hitcount 15 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m recent --name mtp443 --set 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m hashlimit --hashlimit-name mtp443 --hashlimit-mode srcip --hashlimit-upto 20/sec --hashlimit-burst 60 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -m hashlimit --hashlimit-name mtp443 --hashlimit-mode srcip --hashlimit-upto 50/sec --hashlimit-burst 200 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 --syn -j DROP 2>/dev/null || true
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

    printf '  Применяю всем пользователям через API... '
    if apply_ad_tag_all "$new_tag"; then
        ok_inline "Применено без перезапуска"
        sed -i "s/^AD_TAG=.*/AD_TAG=${new_tag}/" .env 2>/dev/null || true
        [[ -z "$(grep '^AD_TAG=' .env 2>/dev/null)" ]] && printf '\nAD_TAG=%s\n' "$new_tag" >> .env || true
    else
        fail_inline "API вернул ошибку (применено не всем пользователям)"
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
Restart=always
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

    # M2: AD_TAG (спонсорский канал) общий для прокси — проставляем сразу при
    # создании, как это делает бот. Иначе новый юзер из CLI был бы без канала.
    local ad_tag=""
    ad_tag=$(grep -m1 '^AD_TAG=' .env 2>/dev/null | cut -d= -f2- || true)

    printf '  Создаю пользователя... '
    local result payload
    if [[ -n "$ad_tag" ]]; then
        payload="{\"username\":\"${name}\",\"secret\":\"${secret}\",\"user_ad_tag\":\"${ad_tag}\"}"
    else
        payload="{\"username\":\"${name}\",\"secret\":\"${secret}\"}"
    fi
    result=$(curl -s -X POST "http://127.0.0.1:${PROXY_API_PORT}/v1/users" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null || true)

    if printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        ok_inline "Создан через API (без перезапуска)"
        [[ -n "$ad_tag" ]] && printf '  %sAD_TAG применён%s\n' "$C_DIM" "$C_RST"
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
        if [[ -n "$ad_tag" ]]; then
            if grep -q "^\[access\.user_ad_tags\]" "$TELEMT_CONF" 2>/dev/null; then
                sed -i "/^\[access\.user_ad_tags\]/a ${name} = \"${ad_tag}\"" "$TELEMT_CONF"
            else
                printf '\n[access.user_ad_tags]\n%s = "%s"\n' "$name" "$ad_tag" >> "$TELEMT_CONF"
            fi
        fi
        systemctl restart "$TELEMT_SVC" >/dev/null 2>&1 && sleep 3
        systemctl is-active "$TELEMT_SVC" >/dev/null 2>&1 \
            && ok_inline "Готово (telemt перезапущен)" \
            || fail_inline "telemt не запустился — проверь пункт 5"
    fi

    local DOMAIN="" TLS_DOMAIN=""
    [[ -f .env ]] && source .env 2>/dev/null || true
    local host="${DOMAIN:-$(detect_public_ip)}"
    local hex_mask
    hex_mask=$(printf '%s' "${TLS_DOMAIN:-$TLS_MASK_DOMAIN}" | xxd -ps | tr -d '\n')
    printf '\n%sОсновная (FakeTLS):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n\n' \
        "$C_GRN$C_BLD" "$C_RST" "$host" "$PROXY_PORT" "$secret" "$hex_mask"
    printf '%sРезервная (dd):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' \
        "$C_CYN$C_BLD" "$C_RST" "$host" "$PROXY_PORT" "$secret"
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
            local cur conns
            read -r cur conns < <(printf '%s' "$api_data" | python3 -c "
import sys,json
n='${name}'
d=json.load(sys.stdin)
u=next((x for x in d['data'] if x['username']==n),None)
print(('true' if u and u.get('enabled',True) else 'false'), (u.get('current_connections',0) if u else 0))
" 2>/dev/null || echo "true 0")
            if [[ "$cur" == "true" ]]; then
                # M3: выключение активного юзера = retry-шторм (клиенты проходят
                # handshake, ловят отказ и бесконечно ретраят). Предупреждаем.
                if [[ "${conns:-0}" -gt 0 ]]; then
                    printf '\n  %s⚠ У %s сейчас %s активных соединений.%s\n' "$C_YLW" "$name" "$conns" "$C_RST"
                    printf '  %sВыключение (enabled=false) НЕ рвёт клиентов чисто — они уйдут в\n' "$C_DIM"
                    printf '  бесконечные переподключения (шторм). Если юзер не нужен — лучше УДАЛИТЬ.%s\n' "$C_RST"
                    confirm "Всё равно выключить ${name}?" N || { sleep 1; return; }
                fi
                payload='{"enabled":false}'
            else
                payload='{"enabled":true}'
            fi
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
    local host="${DOMAIN:-$(detect_public_ip)}"
    local hex_mask
    hex_mask=$(printf '%s' "${TLS_DOMAIN:-$TLS_MASK_DOMAIN}" | xxd -ps | tr -d '\n')
    printf '%sОсновная (FakeTLS):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=ee%s%s\n\n' \
        "$C_GRN$C_BLD" "$C_RST" "$host" "$PROXY_PORT" "$secret" "$hex_mask"
    printf '%sРезервная (dd):%s\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' \
        "$C_CYN$C_BLD" "$C_RST" "$host" "$PROXY_PORT" "$secret"
    pause
}

_users_delete() {
    local api_data="$1"
    printf '\n%s─── Удалить пользователя ───%s\n\n' "$C_BLD" "$C_RST"
    local name; name=$(prompt_value "Имя пользователя" ""); [[ -z "$name" ]] && return

    if ! confirm "Удалить ${name}? Ссылка перестанет работать." N; then return; fi

    printf '  Удаляю... '
    local result
    result=$(curl -s -X DELETE "http://127.0.0.1:${PROXY_API_PORT}/v1/users/${name}" 2>/dev/null || true)
    if printf '%s' "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        ok_inline "Удалён"
    else
        # M1: НЕ откатываемся на enabled:false — выключенный (но не удалённый) юзер
        # кладёт клиентов в retry-шторм (см. .stack). telemt 3.4.15+ поддерживает DELETE.
        fail_inline "API вернул ошибку — юзер НЕ удалён"
        printf '  %sЮзер НЕ выключен специально: выключение активного юзера вызывает%s\n' "$C_YLW" "$C_RST"
        printf '  %sшторм переподключений. Проверь логи telemt (пункт 5).%s\n' "$C_YLW" "$C_RST"
        printf '  %sОтвет API: %s%s\n' "$C_DIM" "$result" "$C_RST"
    fi
    sleep 2
}

# Экспорт всех юзеров (username + secret + квота/срок/лимиты/ad_tag) в JSON-файл.
# Файл секретный (chmod 600) — переносится на второй VPS по scp, НЕ через git.
# Ядро мультисервера (Вариант 2): одинаковый набор юзеров на обоих узлах.
_users_export() {
    local api_data="$1"
    printf '\n%s─── Экспорт пользователей ───%s\n\n' "$C_BLD" "$C_RST"
    local out
    out=$(prompt_value "Файл для экспорта" "/root/users-export.json")
    [[ -z "$out" ]] && return

    local count
    count=$(printf '%s' "$api_data" | OUT="$out" python3 -c '
import sys, json, os
data = json.load(sys.stdin).get("data", [])
users = []
for u in data:
    tls = u.get("links", {}).get("tls", [])
    if not tls:
        continue
    s = tls[0].split("secret=")[-1]
    secret = s[2:34] if s[:2] in ("ee", "dd") else s[:32]
    users.append({
        "username":           u["username"],
        "secret":             secret,
        "user_ad_tag":        u.get("user_ad_tag"),
        "data_quota_bytes":   u.get("data_quota_bytes"),
        "expiration_rfc3339": u.get("expiration_rfc3339"),
        "max_unique_ips":     u.get("max_unique_ips"),
        "max_tcp_conns":      u.get("max_tcp_conns"),
        "enabled":            u.get("enabled", True),
    })
with open(os.environ["OUT"], "w") as f:
    json.dump(users, f, ensure_ascii=False, indent=2)
print(len(users))
' 2>/dev/null || true)

    if [[ -n "$count" && "$count" =~ ^[0-9]+$ ]]; then
        chmod 600 "$out" 2>/dev/null || true
        ok_inline "Экспортировано юзеров: ${count} → ${out}"
        printf '  %sСекретный файл (chmod 600). Перенеси на второй VPS:%s\n' "$C_DIM" "$C_RST"
        printf '    %sscp %s root@IP2:%s%s\n' "$C_CYN" "$out" "$out" "$C_RST"
        printf '  %sзатем там: sudo proxy → 18 → 6 (Импорт). В git НЕ коммитить.%s\n' "$C_DIM" "$C_RST"
    else
        fail_inline "Не удалось записать экспорт (API недоступен?)"
    fi
    pause
}

# Импорт юзеров из JSON-файла (созданного экспортом) в локальный telemt через API.
# Создаёт недостающих юзеров с теми же секретами; существующих пропускает.
_users_import() {
    printf '\n%s─── Импорт пользователей ───%s\n\n' "$C_BLD" "$C_RST"
    local in
    in=$(prompt_value "Файл импорта" "/root/users-export.json")
    [[ -z "$in" ]] && return
    if [[ ! -f "$in" ]]; then
        fail_inline "Файл не найден: $in"; pause; return
    fi
    if ! python3 -c "import json; json.load(open('$in'))" 2>/dev/null; then
        fail_inline "Файл не является корректным JSON"; pause; return
    fi

    local total
    total=$(python3 -c "import json; print(len(json.load(open('$in'))))" 2>/dev/null || echo 0)
    printf 'В файле юзеров: %s%s%s\n' "$C_BLD" "$total" "$C_RST"
    printf '%sСоздаст недостающих через API; существующих пропустит (рестарт не нужен).%s\n\n' "$C_DIM" "$C_RST"
    if ! confirm "Импортировать в этот telemt?" Y; then return; fi
    printf '\n'

    IN_FILE="$in" API="http://127.0.0.1:${PROXY_API_PORT}" python3 - <<'PYEOF' || true
import json, os, urllib.request

users = json.load(open(os.environ["IN_FILE"]))
api   = os.environ["API"]

def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(api + path, data=data,
                                 headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"ok": False, "error": str(e)}

created = skipped = failed = 0
for u in users:
    name, secret = u.get("username"), u.get("secret")
    if not name or not secret:
        failed += 1; print(f"  ✗ {name or '?'}: нет username/secret"); continue
    payload = {"username": name, "secret": secret}
    if u.get("user_ad_tag"):
        payload["user_ad_tag"] = u["user_ad_tag"]
    if not call("POST", "/v1/users", payload).get("ok"):
        skipped += 1; print(f"  • {name}: пропущен (уже есть или ошибка)"); continue
    patch = {k: u[k] for k in
             ("data_quota_bytes", "expiration_rfc3339", "max_unique_ips", "max_tcp_conns")
             if u.get(k) is not None}
    if u.get("enabled") is False:
        patch["enabled"] = False
    if patch:
        call("PATCH", f"/v1/users/{name}", patch)
    created += 1; print(f"  ✓ {name}: создан")

print(f"\nСоздано: {created} | пропущено: {skipped} | ошибок: {failed}")
PYEOF
    pause
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

        printf '\n  %s1)%s Добавить   %s2)%s Изменить/квота   %s3)%s Ссылка   %s4)%s Удалить\n' \
            "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_CYN" "$C_RST"
        printf '  %s5)%s Экспорт юзеров   %s6)%s Импорт юзеров   %s(для второго VPS)%s   %s0)%s Назад\n' \
            "$C_CYN" "$C_RST" "$C_CYN" "$C_RST" "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
        printf '%sВыбор:%s ' "$C_BLD" "$C_RST"
        local sub
        read -r sub </dev/tty || break
        case "$sub" in
            1) _users_add ;;
            2) _users_edit "$api_data" ;;
            3) _users_show_link "$api_data" ;;
            4) _users_delete "$api_data" ;;
            5) _users_export "$api_data" ;;
            6) _users_import ;;
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
