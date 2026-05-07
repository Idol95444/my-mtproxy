#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy.sh — установка MTProto-прокси одной командой
# Использование: git clone <repo> && cd my-mtproxy && bash deploy.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- цвета ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ИНФО]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[ВНИМАНИЕ]${NC}  $*"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

# ---------- определение команды docker compose ----------
detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE="docker-compose"
    else
        return 1
    fi
    info "Используем: $COMPOSE"
}

# ---------- загрузка или запрос переменных ----------
load_config() {
    if [[ -f .env ]]; then
        info "Найден .env, загружаю значения..."
        # shellcheck source=/dev/null
        source .env
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        echo ""
        read -rp "Домен (например tg.example.com): " DOMAIN
    fi
    [[ -z "$DOMAIN" ]] && error "DOMAIN не может быть пустым"

    if [[ -z "${BASE_SECRET:-}" ]]; then
        echo ""
        info "Сгенерируй секрет командой:  head -c 16 /dev/urandom | xxd -ps"
        read -rp "Базовый секрет (32 hex-символа): " BASE_SECRET
    fi
    [[ ${#BASE_SECRET} -ne 32 ]] && error "BASE_SECRET должен быть ровно 32 hex-символа"
    if ! [[ "$BASE_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        error "BASE_SECRET должен содержать только hex-символы (0-9, a-f)"
    fi

    if [[ -z "${AD_TAG:-}" ]]; then
        echo ""
        info "AD_TAG — необязательный. Получи его в @MTProxybot -> /newproxy"
        read -rp "AD_TAG (оставь пустым чтобы пропустить): " AD_TAG
    fi

    # Сохраняем для следующего запуска
    cat > .env <<EOF
DOMAIN=$DOMAIN
BASE_SECRET=$BASE_SECRET
AD_TAG=${AD_TAG:-}
EOF
    chmod 600 .env
    info "Значения сохранены в .env (chmod 600)"
}

# ---------- установка Docker если отсутствует ----------
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker уже установлен"
    else
        info "Устанавливаю Docker..."
        apt update && apt install -y docker.io git curl
        systemctl enable --now docker
    fi

    if ! detect_compose; then
        info "Устанавливаю docker-compose-v2..."
        apt install -y docker-compose-v2 || apt install -y docker-compose
        detect_compose || error "Не удалось найти docker compose после установки"
    fi
}

# ---------- клонирование alexbers ----------
clone_alexbers() {
    if [[ -d src/.git ]]; then
        info "src/ уже существует, обновляю..."
        git -C src pull
    else
        info "Клонирую alexbers/mtprotoproxy (ветка stable)..."
        rm -rf src
        git clone -b stable https://github.com/alexbers/mtprotoproxy.git src
    fi
}

# ---------- генерация конфигов из шаблонов ----------
generate_configs() {
    info "Генерирую Caddyfile из шаблона..."
    sed "s/__DOMAIN__/$DOMAIN/g" Caddyfile.template > Caddyfile

    info "Генерирую config.py из шаблона..."
    local secret_escaped="${BASE_SECRET//\//\\/}"
    if [[ -n "${AD_TAG:-}" ]]; then
        sed \
            -e "s/__DOMAIN__/$DOMAIN/g" \
            -e "s/__BASE_SECRET__/$secret_escaped/g" \
            -e "s/# AD_TAG = \"__AD_TAG__\"/AD_TAG = \"$AD_TAG\"/g" \
            config.py.template > config.py
    else
        sed \
            -e "s/__DOMAIN__/$DOMAIN/g" \
            -e "s/__BASE_SECRET__/$secret_escaped/g" \
            config.py.template > config.py
    fi
    chmod 600 config.py
    info "config.py сгенерирован (chmod 600)"
}

# ---------- проверка DNS ----------
check_dns() {
    info "Проверяю DNS для $DOMAIN..."
    local resolved
    resolved=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
    if [[ -z "$resolved" ]]; then
        warn "DNS-запрос не вернул результатов для $DOMAIN"
        warn "Убедись что A-запись указывает на IP этого сервера"
        read -rp "Продолжить всё равно? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
    else
        info "DNS резолвится в: $resolved"
    fi
}

# ---------- запуск сервисов ----------
start_services() {
    info "Запускаю Caddy первым (для получения LE-сертификата)..."
    $COMPOSE up -d caddy
    info "Жду 20 секунд пока Caddy получит сертификат..."
    sleep 20

    # Проверка сертификата
    info "Проверяю TLS-сертификат..."
    local cert_info
    cert_info=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -subject -issuer 2>/dev/null) || true

    if echo "$cert_info" | grep -qi "let.s.encrypt\|zerossl\|$DOMAIN"; then
        info "Сертификат OK:"
        echo "$cert_info"
    else
        warn "Не удалось проверить LE-сертификат. Логи Caddy:"
        $COMPOSE logs --tail 20 caddy
        warn "Сертификат может ещё выпускаться. Продолжаю..."
    fi

    info "Запускаю alexbers..."
    $COMPOSE up -d --build alexbers
    sleep 5

    info "Логи alexbers:"
    $COMPOSE logs --tail 15 alexbers
}

# ---------- вывод результата ----------
print_result() {
    local hex_domain
    hex_domain=$(echo -n "$DOMAIN" | xxd -ps | tr -d '\n')
    local faketls_secret="ee${BASE_SECRET}${hex_domain}"
    local link="https://t.me/proxy?server=${DOMAIN}&port=853&secret=${faketls_secret}"

    echo ""
    echo "============================================================"
    echo -e "${GREEN} MTProto-прокси запущен!${NC}"
    echo "============================================================"
    echo ""
    echo "FakeTLS-ссылка для пользователей:"
    echo ""
    echo -e "  ${YELLOW}${link}${NC}"
    echo ""
    echo "------------------------------------------------------------"
    echo "Оставшиеся ручные шаги:"
    echo ""
    echo "  1. Открой @MTProxybot в Telegram"
    echo "  2. Отправь /newproxy"
    echo "  3. Введи: ${DOMAIN}:853"
    echo "  4. Введи базовый секрет: ${BASE_SECRET}"
    echo "  5. Сохрани AD_TAG из ответа бота"
    echo "  6. ВАЖНО: /myproxies -> выбери свой прокси"
    echo "     -> Set promoted channel -> @твой_канал"
    echo "     (Без этого спонсорский канал НЕ появится!)"
    echo "  7. Добавь AD_TAG в .env и перезапусти deploy.sh"
    echo "     или отредактируй config.py вручную и перезапусти:"
    echo "     $COMPOSE restart alexbers"
    echo ""
    echo "Управление:"
    echo "  $COMPOSE logs --tail 50 alexbers    # логи прокси"
    echo "  $COMPOSE logs --tail 30 caddy       # логи Caddy"
    echo "  $COMPOSE restart alexbers            # перезапуск прокси"
    echo "  $COMPOSE down && $COMPOSE up -d      # полный перезапуск"
    echo "============================================================"
}

# ===================== ГЛАВНЫЙ БЛОК =====================

echo ""
echo "=========================================="
echo "  Установщик MTProto-прокси"
echo "=========================================="
echo ""

# Нужен root (для Docker)
[[ $EUID -eq 0 ]] || error "Запусти от root: sudo bash deploy.sh"

load_config
install_docker
clone_alexbers
generate_configs
check_dns
start_services
print_result
