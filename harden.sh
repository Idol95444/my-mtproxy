#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# harden.sh — базовая защита VPS для MTProto-прокси
# Запускать ПОСЛЕ deploy.sh (или отдельно)
# Использование: sudo bash harden.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ИНФО]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[ВНИМАНИЕ]${NC}  $*"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Запусти от root: sudo bash harden.sh"

echo ""
echo "=========================================="
echo "  Защита VPS"
echo "=========================================="
echo ""

# =====================================================
# 1. FIREWALL (UFW)
# Открываем только нужные порты, остальное блокируем
# =====================================================

setup_firewall() {
    info "--- Настройка файрвола (ufw) ---"

    apt install -y ufw > /dev/null 2>&1

    # Сброс правил на случай если ufw уже был настроен
    ufw --force reset > /dev/null 2>&1

    # Политика по умолчанию: блокировать всё входящее
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1

    # SSH (порт 22) — без этого потеряем доступ!
    ufw allow 22/tcp comment "SSH" > /dev/null 2>&1
    info "Порт 22 (SSH) — открыт"

    # Caddy — HTTP и HTTPS
    ufw allow 80/tcp comment "Caddy HTTP (LE challenge)" > /dev/null 2>&1
    info "Порт 80 (HTTP) — открыт"

    ufw allow 443/tcp comment "Caddy HTTPS" > /dev/null 2>&1
    info "Порт 443 (HTTPS) — открыт"

    # alexbers — MTProto
    ufw allow 853/tcp comment "MTProto proxy" > /dev/null 2>&1
    info "Порт 853 (MTProto) — открыт"

    # Включаем
    ufw --force enable > /dev/null 2>&1
    info "Файрвол активирован. Всё остальное заблокировано"

    echo ""
    ufw status verbose
    echo ""
}

# =====================================================
# 2. FAIL2BAN
# Блокирует IP после неудачных попыток входа по SSH
# =====================================================

setup_fail2ban() {
    info "--- Настройка fail2ban ---"

    apt install -y fail2ban > /dev/null 2>&1

    # Создаём локальный конфиг (не трогаем стандартный jail.conf)
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# Время бана: 1 час
bantime = 3600
# Окно наблюдения: 10 минут
findtime = 600
# Максимум попыток до бана
maxretry = 3
# Игнорировать localhost
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban

    info "fail2ban активирован: бан на 1 час после 3 неудачных попыток SSH"
}

# =====================================================
# 3. АВТООБНОВЛЕНИЕ БЕЗОПАСНОСТИ
# Критические патчи ставятся автоматически
# =====================================================

setup_auto_updates() {
    info "--- Настройка автообновлений безопасности ---"

    apt install -y unattended-upgrades > /dev/null 2>&1

    # Включаем автообновление
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Настройка: только security-обновления, авторестарт ночью если нужно
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

// Автоматический рестарт если требуется (в 4 утра)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";

// Не обновлять эти пакеты (Docker управляется отдельно)
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker.io";
};
CONF

    systemctl enable unattended-upgrades > /dev/null 2>&1
    systemctl restart unattended-upgrades

    info "Автообновления включены (только security, рестарт в 04:00 если нужно)"
}

# =====================================================
# 4. ЗАЩИТА СЕТИ (sysctl)
# Базовые настройки ядра против типичных атак
# =====================================================

setup_sysctl() {
    info "--- Настройка сетевой защиты (sysctl) ---"

    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Защита от IP-спуфинга
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Игнорировать ICMP-редиректы (защита от MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Игнорировать source-routed пакеты
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Защита от SYN-flood
net.ipv4.tcp_syncookies = 1

# Логировать подозрительные пакеты
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Игнорировать ICMP broadcast (защита от Smurf-атак)
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

    sysctl --system > /dev/null 2>&1

    info "Сетевые настройки ядра применены"
}

# =====================================================
# ГЛАВНЫЙ БЛОК
# =====================================================

setup_firewall
echo ""
setup_fail2ban
echo ""
setup_auto_updates
echo ""
setup_sysctl

echo ""
echo "============================================================"
echo -e "${GREEN} Защита VPS настроена!${NC}"
echo "============================================================"
echo ""
echo "Что установлено:"
echo "  1. Файрвол (ufw) — открыты только 22, 80, 443, 853"
echo "  2. fail2ban — бан IP на 1 час после 3 неудачных SSH-попыток"
echo "  3. Автообновления — security-патчи ставятся автоматически"
echo "  4. Сетевая защита — sysctl против спуфинга, SYN-flood, MITM"
echo ""
echo "Полезные команды:"
echo "  ufw status                    # статус файрвола"
echo "  fail2ban-client status sshd   # заблокированные IP"
echo "  fail2ban-client unban IP      # разбанить конкретный IP"
echo "  cat /var/log/fail2ban.log     # лог fail2ban"
echo "  cat /var/log/unattended-upgrades/unattended-upgrades.log"
echo "============================================================"
