#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy.sh — one-command MTProto proxy setup
# Usage: git clone <repo> && cd my-mtproxy && bash deploy.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- detect docker compose command ----------
detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE="docker-compose"
    else
        return 1
    fi
    info "Using: $COMPOSE"
}

# ---------- load or ask for variables ----------
load_config() {
    if [[ -f .env ]]; then
        info "Found .env, loading values..."
        # shellcheck source=/dev/null
        source .env
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        echo ""
        read -rp "Domain (e.g. tg.example.com): " DOMAIN
    fi
    [[ -z "$DOMAIN" ]] && error "DOMAIN cannot be empty"

    if [[ -z "${BASE_SECRET:-}" ]]; then
        echo ""
        info "Generate a secret with:  head -c 16 /dev/urandom | xxd -ps"
        read -rp "Base secret (32 hex chars): " BASE_SECRET
    fi
    [[ ${#BASE_SECRET} -ne 32 ]] && error "BASE_SECRET must be exactly 32 hex characters"
    if ! [[ "$BASE_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        error "BASE_SECRET must contain only hex characters (0-9, a-f)"
    fi

    if [[ -z "${AD_TAG:-}" ]]; then
        echo ""
        info "AD_TAG is optional. Get it from @MTProxybot -> /newproxy"
        read -rp "AD_TAG (leave empty to skip): " AD_TAG
    fi

    # Save for next run
    cat > .env <<EOF
DOMAIN=$DOMAIN
BASE_SECRET=$BASE_SECRET
AD_TAG=${AD_TAG:-}
EOF
    chmod 600 .env
    info "Saved values to .env (chmod 600)"
}

# ---------- install docker if missing ----------
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed"
    else
        info "Installing Docker..."
        apt update && apt install -y docker.io git curl
        systemctl enable --now docker
    fi

    if ! detect_compose; then
        info "Installing docker-compose-v2..."
        apt install -y docker-compose-v2 || apt install -y docker-compose
        detect_compose || error "Cannot find docker compose after install"
    fi
}

# ---------- clone alexbers ----------
clone_alexbers() {
    if [[ -d src/.git ]]; then
        info "src/ already exists, pulling latest..."
        git -C src pull
    else
        info "Cloning alexbers/mtprotoproxy (stable)..."
        rm -rf src
        git clone -b stable https://github.com/alexbers/mtprotoproxy.git src
    fi
}

# ---------- generate configs from templates ----------
generate_configs() {
    info "Generating Caddyfile from template..."
    sed "s/__DOMAIN__/$DOMAIN/g" Caddyfile.template > Caddyfile

    info "Generating config.py from template..."
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
    info "config.py generated (chmod 600)"
}

# ---------- pre-flight: check DNS ----------
check_dns() {
    info "Checking DNS for $DOMAIN..."
    local resolved
    resolved=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
    if [[ -z "$resolved" ]]; then
        warn "DNS lookup returned nothing for $DOMAIN"
        warn "Make sure A-record points to this server's IP"
        read -rp "Continue anyway? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
    else
        info "DNS resolves to: $resolved"
    fi
}

# ---------- start services ----------
start_services() {
    info "Starting Caddy first (to get LE certificate)..."
    $COMPOSE up -d caddy
    info "Waiting 20 seconds for LE certificate..."
    sleep 20

    # Check certificate
    info "Verifying TLS certificate..."
    local cert_info
    cert_info=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -subject -issuer 2>/dev/null) || true

    if echo "$cert_info" | grep -qi "let.s.encrypt\|zerossl\|$DOMAIN"; then
        info "Certificate OK:"
        echo "$cert_info"
    else
        warn "Could not verify LE certificate. Caddy logs:"
        $COMPOSE logs --tail 20 caddy
        warn "Certificate may still be provisioning. Continuing..."
    fi

    info "Starting alexbers..."
    $COMPOSE up -d --build alexbers
    sleep 5

    info "alexbers logs:"
    $COMPOSE logs --tail 15 alexbers
}

# ---------- print result ----------
print_result() {
    local hex_domain
    hex_domain=$(echo -n "$DOMAIN" | xxd -ps | tr -d '\n')
    local faketls_secret="ee${BASE_SECRET}${hex_domain}"
    local link="https://t.me/proxy?server=${DOMAIN}&port=853&secret=${faketls_secret}"

    echo ""
    echo "============================================================"
    echo -e "${GREEN} MTProto Proxy is running!${NC}"
    echo "============================================================"
    echo ""
    echo "FakeTLS link for users:"
    echo ""
    echo -e "  ${YELLOW}${link}${NC}"
    echo ""
    echo "------------------------------------------------------------"
    echo "Remaining manual steps:"
    echo ""
    echo "  1. Open @MTProxybot in Telegram"
    echo "  2. Send /newproxy"
    echo "  3. Enter: ${DOMAIN}:853"
    echo "  4. Enter base secret: ${BASE_SECRET}"
    echo "  5. Save the AD_TAG from bot response"
    echo "  6. IMPORTANT: /myproxies -> select your proxy"
    echo "     -> Set promoted channel -> @your_channel"
    echo "     (Without this, the sponsored channel will NOT appear!)"
    echo "  7. Add AD_TAG to .env and re-run deploy.sh"
    echo "     or edit config.py manually and restart:"
    echo "     $COMPOSE restart alexbers"
    echo ""
    echo "Management:"
    echo "  $COMPOSE logs --tail 50 alexbers    # proxy logs"
    echo "  $COMPOSE logs --tail 30 caddy       # caddy logs"
    echo "  $COMPOSE restart alexbers            # restart proxy"
    echo "  $COMPOSE down && $COMPOSE up -d      # full restart"
    echo "============================================================"
}

# ===================== MAIN =====================

echo ""
echo "=========================================="
echo "  MTProto Proxy Deployer"
echo "=========================================="
echo ""

# Must run as root (Docker needs it)
[[ $EUID -eq 0 ]] || error "Run as root: sudo bash deploy.sh"

load_config
install_docker
clone_alexbers
generate_configs
check_dns
start_services
print_result
