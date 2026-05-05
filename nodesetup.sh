#!/usr/bin/env bash
# ==============================================================================
#  VPN Node Setup — Unified Installer v4.0
#  Поддержка: Debian 11+, Ubuntu 20.04+, CentOS/RHEL/Fedora/AlmaLinux/Rocky
#
#  Два режима:
#    --mode vk    → vk-turn-proxy (старый, nodesetup.sh)
#    --mode wdtt  → wdtt-server   (новый, deploy.sh, рекомендуется)
#
#  NAT:  MASQUERADE (стандартный iptables/nft)
#  WDTT: DTLS порт 56000, WG порт 56001
#  VK:   TURN порт 56000, WG порт 51820
# ==============================================================================
set -uo pipefail

readonly SCRIPT_VERSION="4.0"
readonly LOG_FILE="/var/log/vpn-node-install.log"
readonly HY2_INSTALL_SCRIPT_URL="${HY2_INSTALL_SCRIPT_URL:-https://get.hy2.sh/}"

# ─── Цвета ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${CYAN}[►]${NC} ${BOLD}$*${NC}" | tee -a "$LOG_FILE"; }
die()       { log_error "$*"; exit 1; }

# ─── Параметры (переопределяются флагами) ─────────────────────────────────────
INSTALL_MODE=""     # wdtt | vk | dual  — обязателен
NODE_NAME=""
SSH_PASSWORD=""
API_TOKEN=""
API_PORT="${API_PORT:-8787}"
API_HOST="${API_HOST:-0.0.0.0}"

# WDTT-специфичные
WDTT_DTLS_PORT=56000
WDTT_WG_PORT=56001
WDTT_BINARY_URL="${WDTT_BINARY_URL:-}"   # задаётся приложением при деплое

# VK-специфичные
VK_TURN_PORT=56010
VK_WG_PORT=51820
HY2_PORT="${HY2_PORT:-443}"
HY2_ENABLE="${HY2_ENABLE:-1}"

VPN_SUBNET=""       # будет определён автоматически

# ─── Разбор аргументов ────────────────────────────────────────────────────────
usage() {
    echo "Использование:"
    echo "  $0 --mode <wdtt|vk|dual> [опции]"
    echo "  $0 --upgrade-existing [опции]"
    echo "  $0 --upgrade-vk [опции]"
    echo "  $0 --upgrade-dual [опции]"
    echo "  $0 --upgrade-to-wdtt [--wdtt-url <url>]"
    echo ""
    echo "Опции:"
    echo "  --name <name>        Имя ноды (например RU-1)"
    echo "  --ssh-pass <pass>    Пароль SSH для экстренного доступа"
    echo "  --api-token <token>  Токен API (автогенерируется если не задан)"
    echo "  --api-port <port>    Порт Node API (по умолчанию 8787)"
    echo "  --wdtt-url <url>     URL для скачивания wdtt-server бинарника"
    echo "  --wdtt-dtls-port <p> DTLS порт WDTT (по умолчанию 56000)"
    echo "  --wdtt-wg-port <p>   WG порт WDTT (по умолчанию 56001)"
    echo "  --hy2-port <p>       Порт Hysteria2 (по умолчанию 443)"
    echo "  --hy2-enable <0|1>   Установить/обновить Hysteria2 (по умолчанию 1)"
    echo "  --subnet <cidr>      VPN подсеть (автоопределяется)"
    echo ""
    echo "Примеры:"
    echo "  $0 --mode wdtt --name RU-1 --ssh-pass mypass"
    echo "  $0 --mode vk   --name RU-2 --ssh-pass mypass --subnet 10.100.0.0/24"
    echo "  $0 --mode dual --name RU-1 --wdtt-dtls-port 56100 --wdtt-wg-port 56101"
    echo "  $0 --upgrade-vk --name RU-2"
    echo "  $0 --upgrade-dual --name RU-2 --wdtt-dtls-port 56100 --wdtt-wg-port 56101"
    echo "  $0 --upgrade-existing --mode vk"
    echo "  $0 --upgrade-to-wdtt --wdtt-url https://example/wdtt-server"
    exit 1
}

parse_upgrade_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       INSTALL_MODE="$2";    shift 2 ;;
            --name)       NODE_NAME="$2";       shift 2 ;;
            --ssh-pass)   SSH_PASSWORD="$2";    shift 2 ;;
            --api-token)  API_TOKEN="$2";       shift 2 ;;
            --api-port)   API_PORT="$2";        shift 2 ;;
            --wdtt-url)   WDTT_BINARY_URL="$2"; shift 2 ;;
            --wdtt-dtls-port) WDTT_DTLS_PORT="$2"; shift 2 ;;
            --wdtt-wg-port)   WDTT_WG_PORT="$2"; shift 2 ;;
            --hy2-port)   HY2_PORT="$2";       shift 2 ;;
            --hy2-enable) HY2_ENABLE="$2";     shift 2 ;;
            --subnet)     VPN_SUBNET="$2";      shift 2 ;;
            --help|-h)    usage ;;
            *)            log_warn "Неизвестный параметр: $1"; shift ;;
        esac
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       INSTALL_MODE="$2";    shift 2 ;;
            --name)       NODE_NAME="$2";       shift 2 ;;
            --ssh-pass)   SSH_PASSWORD="$2";    shift 2 ;;
            --api-token)  API_TOKEN="$2";       shift 2 ;;
            --api-port)   API_PORT="$2";        shift 2 ;;
            --wdtt-url)   WDTT_BINARY_URL="$2"; shift 2 ;;
            --wdtt-dtls-port) WDTT_DTLS_PORT="$2"; shift 2 ;;
            --wdtt-wg-port)   WDTT_WG_PORT="$2"; shift 2 ;;
            --hy2-port)   HY2_PORT="$2";       shift 2 ;;
            --hy2-enable) HY2_ENABLE="$2";     shift 2 ;;
            --subnet)     VPN_SUBNET="$2";      shift 2 ;;
            --help|-h)    usage ;;
            *) log_warn "Неизвестный параметр: $1"; shift ;;
        esac
    done

    # Интерактивный ввод если параметры не переданы
    if [[ -z "$INSTALL_MODE" ]]; then
        exec </dev/tty
        echo -e "${CYAN}Выберите режим установки:${NC}"
        echo "  1) wdtt — WDTT/DTLS (рекомендуется, новый)"
        echo "  2) vk   — VK TURN proxy (старый)"
        read -r -p "Режим [1/2]: " mode_choice
        case "$mode_choice" in
            1|wdtt) INSTALL_MODE="wdtt" ;;
            2|vk)   INSTALL_MODE="vk" ;;
            *) die "Неверный выбор" ;;
        esac
        exec <&-
    fi

    if [[ "$INSTALL_MODE" != "wdtt" && "$INSTALL_MODE" != "vk" && "$INSTALL_MODE" != "dual" ]]; then
        die "Режим должен быть 'wdtt', 'vk' или 'dual'"
    fi

    if [[ -z "$NODE_NAME" ]]; then
        exec </dev/tty
        read -r -p "Имя ноды (например RU-1): " NODE_NAME
        exec <&-
    fi

    if [[ -z "$SSH_PASSWORD" ]]; then
        exec </dev/tty
        read -r -s -p "Пароль SSH для экстренного доступа: " SSH_PASSWORD
        echo
        exec <&-
    fi

    if [[ -z "$API_TOKEN" ]]; then
        API_TOKEN=$(openssl rand -hex 32)
        log_info "API токен сгенерирован автоматически"
    fi
}

# ─── Проверка root ────────────────────────────────────────────────────────────
check_root() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите от root (sudo bash $0)"
}

# ─── Определение ОС ──────────────────────────────────────────────────────────
OS_ID="" ; PKG_MGR=""

detect_os() {
    log_step "Определение ОС..."
    [[ -f /etc/os-release ]] || die "Файл /etc/os-release не найден"
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)        PKG_MGR="apt" ;;
        centos|rhel|rocky|almalinux|oracle) PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf" ;;
        fedora)                             PKG_MGR="dnf" ;;
        arch|manjaro|endeavouros)           PKG_MGR="pacman" ;;
        *) die "Неподдерживаемый дистрибутив: $OS_ID" ;;
    esac
    log_info "ОС: ${PRETTY_NAME:-$OS_ID} | PM: $PKG_MGR"
}

# ─── WAN-интерфейс ───────────────────────────────────────────────────────────
detect_wan_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [[ -z "$iface" ]] && iface=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)
    [[ -z "$iface" ]] && iface=$(ls /sys/class/net/ | grep -v lo | head -1)
    echo "$iface"
}

# ─── Firewall-бэкенд ─────────────────────────────────────────────────────────
FW_BACKEND=""

detect_firewall() {
    if command -v iptables &>/dev/null; then
        FW_BACKEND="iptables"
    elif command -v nft &>/dev/null; then
        FW_BACKEND="nft"
    else
        log_warn "Устанавливаем iptables..."
        case "$PKG_MGR" in
            apt)    apt-get install -y -qq iptables ;;
            dnf|yum) $PKG_MGR install -y iptables ;;
            pacman) pacman -Sy --noconfirm iptables ;;
        esac
        command -v iptables &>/dev/null && FW_BACKEND="iptables" || die "Не удалось установить iptables"
    fi
    log_info "Firewall: $FW_BACKEND"
}

# ─── Firewall-помощники ───────────────────────────────────────────────────────
fw_add_input_tcp() {
    case "$FW_BACKEND" in
        iptables) iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || true ;;
        nft)      nft add rule inet filter input tcp dport "$1" accept 2>/dev/null || true ;;
    esac
}

fw_add_input_udp() {
    case "$FW_BACKEND" in
        iptables) iptables -C INPUT -p udp --dport "$1" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$1" -j ACCEPT 2>/dev/null || true ;;
        nft)      nft add rule inet filter input udp dport "$1" accept 2>/dev/null || true ;;
    esac
}

fw_add_forward() {
    case "$FW_BACKEND" in
        iptables)
            iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
            iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
            ;;
        nft) nft add rule inet filter forward accept 2>/dev/null || true ;;
    esac
}

fw_add_masquerade() {
    local iface="$1" subnet="$2"
    case "$FW_BACKEND" in
        iptables) iptables -t nat -C POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null || \
                  iptables -t nat -A POSTROUTING -s "$subnet" -o "$iface" -j MASQUERADE 2>/dev/null || true ;;
        nft)
            nft add table nat 2>/dev/null || true
            nft add chain nat postrouting '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
            nft add rule nat postrouting ip saddr "$subnet" oifname "$iface" masquerade 2>/dev/null || true
            ;;
    esac
}

fw_add_mss_clamping() {
    local subnet="$1"
    case "$FW_BACKEND" in
        iptables)
            iptables -t mangle -C FORWARD -s "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
                iptables -t mangle -I FORWARD -s "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            iptables -t mangle -C FORWARD -d "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
                iptables -t mangle -I FORWARD -d "$subnet" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            ;;
        nft)
            nft add table inet mangle 2>/dev/null || true
            nft add chain inet mangle forward '{ type filter hook forward priority -150; }' 2>/dev/null || true
            nft add rule inet mangle forward ip saddr "$subnet" tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null || true
            ;;
    esac
}

fw_established() {
    case "$FW_BACKEND" in
        iptables) iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                  iptables -I INPUT 2 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true ;;
        nft)      nft add rule inet filter input ct state established,related accept 2>/dev/null || true ;;
    esac
}

# ─── Автовыбор подсети ────────────────────────────────────────────────────────
auto_select_subnet() {
    if [[ -n "$VPN_SUBNET" ]]; then
        log_info "Подсеть задана вручную: $VPN_SUBNET"
        return
    fi

    local default_subnet
    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        default_subnet="10.66.66.0/24"
    else
        default_subnet="172.16.0.0/12"
    fi

    local candidates=("$default_subnet" "10.200.0.0/16" "192.168.200.0/24" "172.31.0.0/12")
    local used
    used=$(ip -4 addr show | grep -oP 'inet \K[\d.]+/\d+' | awk -F/ '{print $1}' | sed 's/\.[0-9]*$//')

    for subnet in "${candidates[@]}"; do
        local base
        base=$(echo "$subnet" | cut -d/ -f1 | sed 's/\.[0-9]*$//')
        if ! echo "$used" | grep -q "^${base}"; then
            VPN_SUBNET="$subnet"
            log_info "Автовыбрана подсеть: $VPN_SUBNET"
            return
        fi
    done

    VPN_SUBNET="10.99.0.0/24"
    log_warn "Не найдена свободная подсеть, использую fallback: $VPN_SUBNET"
}

# ─── Sysctl тюнинг ───────────────────────────────────────────────────────────
setup_sysctl() {
    log_step "Настройка sysctl..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    cat > /etc/sysctl.d/99-vpn-node.conf <<'SYSEOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 300
SYSEOF
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-vpn-node.conf >/dev/null 2>&1 || true
    log_info "Sysctl настроен"
}

# ─── Установка пакетов ────────────────────────────────────────────────────────
install_packages() {
    log_step "Установка пакетов..."
    case "$PKG_MGR" in
        apt)
            apt-get update -y -qq 2>>"$LOG_FILE"
            apt-get install -y wireguard net-tools curl iptables-persistent python3-venv python3-pip ipcalc 2>>"$LOG_FILE"
            ;;
        dnf|yum)
            $PKG_MGR install -y epel-release 2>>"$LOG_FILE" || true
            $PKG_MGR install -y wireguard-tools net-tools curl python3 python3-pip 2>>"$LOG_FILE"
            ;;
        pacman)
            pacman -Sy --noconfirm wireguard-tools curl python python-pip 2>>"$LOG_FILE"
            ;;
    esac
    log_info "Пакеты установлены"
}

# ─── Резерв iptables ──────────────────────────────────────────────────────────
backup_iptables() {
    command -v iptables-save &>/dev/null && \
        iptables-save > "/root/iptables.backup.$(date +%s)" 2>/dev/null || true
}

# ─── Настройка WireGuard ─────────────────────────────────────────────────────
setup_wireguard() {
    log_step "Настройка WireGuard..."
    local wg_port="$1"

    cd /etc/wireguard
    umask 077

    if [[ ! -f server_private ]]; then
        wg genkey | tee server_private | wg pubkey > server_public
    fi
    SERVER_PRIVATE=$(cat server_private)
    SERVER_PUBLIC=$(cat server_public)

    local server_ip
    server_ip="$(echo "$VPN_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
    local prefix
    prefix="$(echo "$VPN_SUBNET" | cut -d/ -f2)"

    mkdir -p /etc/wireguard/scripts

    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address = ${server_ip}/${prefix}
ListenPort = ${wg_port}
PostUp   = /etc/wireguard/scripts/iptables-up.sh
PostDown = /etc/wireguard/scripts/iptables-down.sh
EOF

    cat > /etc/wireguard/scripts/iptables-up.sh <<'SCRIPT'
#!/bin/bash
source /etc/vpn-node.env
EXT_IF=$(ip route | grep default | awk '{print $5}')
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o $EXT_IF -j MASQUERADE
SCRIPT

    cat > /etc/wireguard/scripts/iptables-down.sh <<'SCRIPT'
#!/bin/bash
source /etc/vpn-node.env
EXT_IF=$(ip route | grep default | awk '{print $5}')
iptables -D FORWARD -i wg0 -j ACCEPT
iptables -D FORWARD -o wg0 -j ACCEPT
iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o $EXT_IF -j MASQUERADE
SCRIPT

    chmod +x /etc/wireguard/scripts/*.sh
    log_info "WireGuard настроен (порт ${wg_port}, подсеть ${VPN_SUBNET})"
}

# ─── NAT + Firewall ──────────────────────────────────────────────────────────
setup_nat() {
    log_step "Настройка NAT и фаервола..."
    local iface
    iface=$(detect_wan_interface)
    [[ -z "$iface" ]] && { log_warn "Не удалось определить WAN-интерфейс! Настройте NAT вручную."; return 0; }

    fw_add_input_tcp 22
    fw_established
    fw_add_input_udp "$API_PORT"
    fw_add_input_tcp "$API_PORT"

    if [[ "$INSTALL_MODE" == "wdtt" || "$INSTALL_MODE" == "dual" ]]; then
        fw_add_input_udp "$WDTT_DTLS_PORT"
        fw_add_input_udp "$WDTT_WG_PORT"
        # WDTT использует весь UDP диапазон для TURN relay
        case "$FW_BACKEND" in
            iptables) iptables -C INPUT -p udp --dport 1024:65535 -j ACCEPT 2>/dev/null || \
                      iptables -I INPUT -p udp --dport 1024:65535 -j ACCEPT 2>/dev/null || true ;;
            nft)      nft add rule inet filter input udp dport 1024-65535 accept 2>/dev/null || true ;;
        esac
    fi
    if [[ "$INSTALL_MODE" == "vk" || "$INSTALL_MODE" == "dual" ]]; then
        fw_add_input_udp "$VK_TURN_PORT"
        fw_add_input_udp "$VK_WG_PORT"
        if [[ "${HY2_ENABLE}" == "1" ]]; then
            fw_add_input_udp "$HY2_PORT"
            fw_add_input_tcp "$HY2_PORT"
        fi
    fi

    fw_add_forward
    fw_add_masquerade "$iface" "$VPN_SUBNET"
    fw_add_mss_clamping "$VPN_SUBNET"

    # Сохраняем правила
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_info "NAT настроен: MASQUERADE на $iface для $VPN_SUBNET"
}

# ─── РЕЖИМ WDTT: установка wdtt-server ───────────────────────────────────────
install_wdtt_server() {
    log_step "Установка wdtt-server..."

    if [[ -f /tmp/wdtt-server ]]; then
        chmod +x /tmp/wdtt-server
        mv /tmp/wdtt-server /usr/local/bin/wdtt-server
        log_info "wdtt-server установлен из /tmp"
    elif [[ -n "$WDTT_BINARY_URL" ]]; then
        log_info "Загрузка wdtt-server с $WDTT_BINARY_URL..."
        curl -fsSL -o /usr/local/bin/wdtt-server "$WDTT_BINARY_URL" 2>>"$LOG_FILE" \
            || die "Не удалось загрузить wdtt-server"
        chmod +x /usr/local/bin/wdtt-server
        log_info "wdtt-server загружен и установлен"
    elif [[ -f /usr/local/bin/wdtt-server ]]; then
        log_info "wdtt-server уже установлен"
    else
        log_warn "wdtt-server не найден. После установки скопируйте бинарник в /usr/local/bin/wdtt-server"
    fi
}

# ─── РЕЖИМ WDTT: systemd-сервис ──────────────────────────────────────────────
setup_wdtt_service() {
    log_step "Создание systemd-сервиса wdtt..."
    local wdtt_cfg_dir="/etc/wireguard"
    if [[ "$INSTALL_MODE" == "dual" ]]; then
        wdtt_cfg_dir="/etc/wireguard/wdtt"
        mkdir -p "$wdtt_cfg_dir"
    fi

    cat > /etc/systemd/system/wdtt.service <<EOF
[Unit]
Description=WDTT VPN Server (DTLS+WireGuard)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/env bash -c "fuser -k -9 ${WDTT_DTLS_PORT}/udp ${WDTT_WG_PORT}/udp 2>/dev/null || true"
ExecStart=/usr/local/bin/wdtt-server -listen 0.0.0.0:${WDTT_DTLS_PORT} -wg-port ${WDTT_WG_PORT} -config-dir ${wdtt_cfg_dir}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wdtt
    log_info "Сервис wdtt.service создан"
}

# ─── РЕЖИМ VK: vk-turn-proxy ──────────────────────────────────────────────────
install_vk_turn_proxy() {
    log_step "Установка vk-turn-proxy..."
    local url="https://github.com/kiper292/vk-turn-proxy/releases/download/v2.0.7/server-linux-amd64"

    if [[ ! -f /opt/vk-turn-proxy ]]; then
        local attempt=1
        while [[ $attempt -le 5 ]]; do
            if curl -fsSL -o /opt/vk-turn-proxy "$url" 2>>"$LOG_FILE"; then
                break
            fi
            log_warn "Попытка $attempt/5 не удалась, повтор через 5с..."
            sleep 5
            ((attempt++))
        done
        chmod +x /opt/vk-turn-proxy
        log_info "vk-turn-proxy установлен"
    else
        log_info "vk-turn-proxy уже установлен"
    fi

    cat > /etc/systemd/system/vk-turn-proxy.service <<EOF
[Unit]
Description=VK Turn Proxy
After=network.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/vk-turn-proxy -listen 0.0.0.0:${VK_TURN_PORT} -connect 127.0.0.1:${VK_WG_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vk-turn-proxy
    log_info "vk-turn-proxy.service создан"
}

# ─── HY2: установка/обновление hysteria2 ─────────────────────────────────────
install_hy2_server() {
    [[ "${HY2_ENABLE}" == "1" ]] || { log_info "HY2 отключен (HY2_ENABLE=${HY2_ENABLE})"; return 0; }
    log_step "Установка/обновление Hysteria2 через ${HY2_INSTALL_SCRIPT_URL}..."
    if curl -fsSL "$HY2_INSTALL_SCRIPT_URL" | bash >/dev/null 2>>"$LOG_FILE"; then
        log_info "Hysteria2 установлен/обновлен"
    else
        log_warn "Не удалось установить/обновить Hysteria2 через get.hy2.sh"
        return 0
    fi

    # Открываем порт HY2 (обычно 443, можно переопределить).
    fw_add_input_udp "$HY2_PORT"
    fw_add_input_tcp "$HY2_PORT"

    # Если есть конфиг — стартуем/перезапускаем сервис.
    if [[ -f /etc/hysteria/config.yaml ]]; then
        systemctl enable hysteria-server.service 2>/dev/null || true
        systemctl restart hysteria-server.service 2>>"$LOG_FILE" || log_warn "hysteria-server не запустился"
    else
        log_warn "Файл /etc/hysteria/config.yaml не найден (создайте конфиг и запустите hysteria-server.service)"
    fi
}

# ─── Node API (для обоих режимов) ─────────────────────────────────────────────
setup_node_api() {
    log_step "Настройка Node API (порт ${API_PORT})..."

    local svc_name
    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        svc_name="wdtt"
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        svc_name="wdtt"
    else
        svc_name="vk-turn-proxy"
    fi

    mkdir -p /opt/vpn-node-api
    cd /opt/vpn-node-api

    cat > requirements.txt <<'REQ'
fastapi==0.115.6
uvicorn==0.32.1
REQ

    if [[ ! -d .venv ]]; then
        python3 -m venv .venv
    fi
    .venv/bin/pip install --upgrade pip -q 2>>"$LOG_FILE"
    .venv/bin/pip install -r requirements.txt -q 2>>"$LOG_FILE"

    local turn_port
    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        turn_port="$WDTT_DTLS_PORT"
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        turn_port="$VK_TURN_PORT"
    else
        turn_port="$VK_TURN_PORT"
    fi
    local wg_port
    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        wg_port="$WDTT_WG_PORT"
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        wg_port="$VK_WG_PORT"
    else
        wg_port="$VK_WG_PORT"
    fi

    cat > app.py <<PY
import asyncio, json, os, re, secrets, shlex, subprocess, time
from pathlib import Path
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

API_TOKEN   = os.getenv("VPN_NODE_API_TOKEN", "")
WG_PORT     = int(os.getenv("WG_PORT", "$wg_port"))
TURN_PORT   = int(os.getenv("TURN_PORT", "$turn_port"))
NODE_NAME   = os.getenv("NODE_NAME", "node")
NODE_MODE   = os.getenv("NODE_MODE", "$INSTALL_MODE")
VPN_SUBNET  = os.getenv("VPN_SUBNET", "$VPN_SUBNET")
CMD_TIMEOUT = int(os.getenv("CMD_TIMEOUT", "10"))
ALLOW_KEYPAIR_API = os.getenv("ALLOW_KEYPAIR_API", "0") == "1"
WDTT_TURN_PORT = int(os.getenv("WDTT_TURN_PORT", "$WDTT_DTLS_PORT"))
VK_TURN_PORT   = int(os.getenv("VK_TURN_PORT", "$VK_TURN_PORT"))
WDTT_SECRET_PATH = Path(os.getenv("WDTT_SECRET_PATH", "/var/lib/vpn-node-api/wdtt-secrets.json"))

app = FastAPI(title="vpn-node-api", version="2.0.0")
wg_lock = asyncio.Lock()

def _run(cmd, timeout=CMD_TIMEOUT):
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {err[:300]}")
    return (proc.stdout or "").strip()

def _run_input(cmd, stdin_data, timeout=CMD_TIMEOUT):
    proc = subprocess.run(
        cmd,
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=timeout
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {err[:300]}")
    return (proc.stdout or "").strip()

def _check_auth(token):
    if not API_TOKEN or token != API_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")

def _load_wdtt_secrets():
    try:
        if not WDTT_SECRET_PATH.exists():
            return {}
        return json.loads(WDTT_SECRET_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}

def _save_wdtt_secrets(data: dict):
    WDTT_SECRET_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = WDTT_SECRET_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(WDTT_SECRET_PATH)

@app.get("/health")
def health(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    wg_if = False
    try:
        ifaces = _run(["wg", "show", "interfaces"])
        wg_if = "wg0" in ifaces.split()
    except: pass
    out = ""
    try:
        out = _run(["bash", "-lc", "ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null"])
    except: pass
    wg_port_ok   = bool(re.search(rf":{WG_PORT}\b",   out))
    turn_port_ok = bool(re.search(rf":{TURN_PORT}\b", out))
    wdtt_turn_ok = bool(re.search(rf":{WDTT_TURN_PORT}\b", out))
    vk_turn_ok   = bool(re.search(rf":{VK_TURN_PORT}\b", out))
    if NODE_MODE == "dual":
        turn_port_ok = wdtt_turn_ok and vk_turn_ok
    return {
        "ok": wg_if and turn_port_ok,
        "node": NODE_NAME,
        "mode": NODE_MODE,
        "wg_interface_ok": wg_if,
        "wg_service_ok":   True,
        "turn_service_ok": True,
        "wg_port_ok":      wg_port_ok,
        "turn_port_ok":    turn_port_ok,
        "wdtt_turn_port_ok": wdtt_turn_ok,
        "vk_turn_port_ok": vk_turn_ok,
    }

@app.get("/info")
def info(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    pub = ""
    try: pub = _run(["wg", "show", "wg0", "public-key"]).strip()
    except: pass
    return {"node": NODE_NAME, "mode": NODE_MODE, "vpn_subnet": VPN_SUBNET,
            "public_key": pub}

@app.get("/wg/public-key")
def wg_public_key(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    return {"public_key": _run(["wg", "show", "wg0", "public-key"]).strip()}

@app.post("/wg/keypair")
def wg_keypair(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    if not ALLOW_KEYPAIR_API:
        raise HTTPException(status_code=404, detail="Endpoint disabled")
    priv = _run(["wg", "genkey"]).strip()
    pub = _run_input(["wg", "pubkey"], priv).strip()
    return {"private_key": priv, "public_key": pub}

@app.get("/wg/transfer")
def wg_transfer(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "transfer"])
    data = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            try: data.append({"public_key": parts[0], "rx": int(parts[1]), "tx": int(parts[2])})
            except: pass
    return {"items": data}

@app.get("/wg/latest-handshakes")
def latest_handshakes(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "latest-handshakes"])
    data = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try: data.append({"public_key": parts[0], "ts": int(parts[1])})
            except: pass
    return {"items": data}

class PeerUpsert(BaseModel):
    public_key: str = Field(min_length=44, max_length=44)
    ip: str

@app.post("/wg/peer/upsert")
async def wg_peer_upsert(payload: PeerUpsert, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    async with wg_lock:
        _run(["wg", "set", "wg0", "peer", payload.public_key, "allowed-ips", f"{payload.ip}/32"])
    return {"ok": True}

class PeerRemove(BaseModel):
    public_key: str = Field(min_length=44, max_length=44)

@app.post("/wg/peer/remove")
async def wg_peer_remove(payload: PeerRemove, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    async with wg_lock:
        _run(["wg", "set", "wg0", "peer", payload.public_key, "remove"])
    return {"ok": True}

class RestartReq(BaseModel):
    service: str

@app.post("/service/restart")
def restart_service(payload: RestartReq, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    allowed = {"wg-quick@wg0", "wdtt", "vk-turn-proxy", "hysteria-server.service"}
    if payload.service not in allowed:
        raise HTTPException(400, f"Service not allowed. Use one of: {allowed}")
    _run(["systemctl", "restart", payload.service], timeout=20)
    return {"ok": True}

class WDTTSecretReq(BaseModel):
    uid: int
    peer_id: int
    public_key: str = Field(min_length=44, max_length=44)

@app.post("/wdtt/secret")
def wdtt_secret(payload: WDTTSecretReq, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    data = _load_wdtt_secrets()
    key = str(payload.peer_id)
    cur = data.get(key)
    if cur and isinstance(cur, dict) and cur.get("secret"):
        return {"ok": True, "peer_id": payload.peer_id, "secret": cur["secret"], "reused": True}
    secret = secrets.token_urlsafe(18)
    data[key] = {
        "uid": payload.uid,
        "peer_id": payload.peer_id,
        "public_key": payload.public_key,
        "secret": secret,
        "created_at": int(time.time()),
    }
    _save_wdtt_secrets(data)
    return {"ok": True, "peer_id": payload.peer_id, "secret": secret, "reused": False}

@app.post("/wdtt/secret/generate")
def wdtt_secret_generate(payload: WDTTSecretReq, x_api_token: str | None = Header(default=None)):
    return wdtt_secret(payload, x_api_token)

@app.get("/wdtt/secret/{peer_id}")
def wdtt_secret_get(peer_id: int, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    data = _load_wdtt_secrets()
    cur = data.get(str(peer_id))
    if not cur:
        raise HTTPException(404, "Secret not found")
    return {"ok": True, "peer_id": peer_id, "secret": cur.get("secret", "")}

@app.get("/wdtt/runtime-password")
def wdtt_runtime_password(x_api_token: str | None = Header(default=None)):
    """
    Returns actual runtime password from wdtt.service ExecStart (-password ...).
    """
    _check_auth(x_api_token)
    out = _run(["systemctl", "cat", "wdtt"], timeout=8)
    for ln in out.splitlines():
        if "ExecStart=" not in ln or "wdtt-server" not in ln:
            continue
        line = ln.split("ExecStart=", 1)[1].strip()
        try:
            parts = shlex.split(line)
        except Exception:
            parts = line.split()
        for i, p in enumerate(parts):
            if p == "-password" and i + 1 < len(parts):
                return {"ok": True, "password": str(parts[i + 1])}
            if p.startswith("-password="):
                return {"ok": True, "password": p.split("=", 1)[1]}
    raise HTTPException(404, "Runtime WDTT password not found")
PY

    cat > /etc/vpn-node-api.env <<EOF
VPN_NODE_API_TOKEN=${API_TOKEN}
WG_PORT=${wg_port}
TURN_PORT=${turn_port}
NODE_NAME=${NODE_NAME}
NODE_MODE=${INSTALL_MODE}
VPN_SUBNET=${VPN_SUBNET}
VPN_SERVER_IP=$(echo "$VPN_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')
CMD_TIMEOUT=12
ALLOW_KEYPAIR_API=0
WDTT_TURN_PORT=${WDTT_DTLS_PORT}
VK_TURN_PORT=${VK_TURN_PORT}
WDTT_SECRET_PATH=/var/lib/vpn-node-api/wdtt-secrets.json
EOF
    chmod 600 /etc/vpn-node-api.env

    cat > /etc/systemd/system/vpn-node-api.service <<EOF
[Unit]
Description=VPN Node API
After=network.target ${svc_name}.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/vpn-node-api.env
WorkingDirectory=/opt/vpn-node-api
ExecStart=/opt/vpn-node-api/.venv/bin/uvicorn app:app --host ${API_HOST} --port ${API_PORT} --workers 1
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-node-api
    log_info "Node API настроен на порту ${API_PORT}"
}

# ─── Сохранение общего env ────────────────────────────────────────────────────
save_env() {
    local wg_port turn_port
    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        wg_port="$WDTT_WG_PORT"; turn_port="$WDTT_DTLS_PORT"
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        wg_port="$VK_WG_PORT";   turn_port="$VK_TURN_PORT"
    else
        wg_port="$VK_WG_PORT";   turn_port="$VK_TURN_PORT"
    fi

    cat > /etc/vpn-node.env <<EOF
NODE_NAME="${NODE_NAME}"
NODE_MODE="${INSTALL_MODE}"
SSH_PASSWORD="${SSH_PASSWORD}"
WG_PORT="${wg_port}"
TURN_PORT="${turn_port}"
API_PORT="${API_PORT}"
API_HOST="${API_HOST}"
API_TOKEN="${API_TOKEN}"
VPN_SUBNET="${VPN_SUBNET}"
VPN_SERVER_IP="$(echo "$VPN_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
WDTT_DTLS_PORT="${WDTT_DTLS_PORT}"
WDTT_WG_PORT="${WDTT_WG_PORT}"
VK_TURN_PORT="${VK_TURN_PORT}"
VK_WG_PORT="${VK_WG_PORT}"
HY2_PORT="${HY2_PORT}"
HY2_ENABLE="${HY2_ENABLE}"
EOF
    chmod 600 /etc/vpn-node.env
}

# ─── Запуск всех сервисов ────────────────────────────────────────────────────
start_services() {
    log_step "Запуск сервисов..."

    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        # WDTT: wdtt-server управляет WG сам
        if [[ -f /usr/local/bin/wdtt-server ]]; then
            systemctl start wdtt 2>>"$LOG_FILE" || log_warn "wdtt не запустился (бинарник не найден?)"
        else
            log_warn "wdtt-server не найден в /usr/local/bin — запуск пропущен"
            log_warn "После копирования бинарника: systemctl start wdtt"
        fi
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        # Dual: VK остается на wg0, WDTT поднимается отдельно
        systemctl unmask wg-quick@wg0 2>/dev/null || true
        systemctl start wg-quick@wg0 2>>"$LOG_FILE" || log_warn "wg-quick@wg0 не запустился"
        systemctl restart vk-turn-proxy 2>>"$LOG_FILE" || log_warn "vk-turn-proxy не запустился"
        if [[ -f /usr/local/bin/wdtt-server ]]; then
            systemctl start wdtt 2>>"$LOG_FILE" || log_warn "wdtt не запустился"
        else
            log_warn "wdtt-server не найден в /usr/local/bin — запуск WDTT пропущен"
        fi
        if [[ "${HY2_ENABLE}" == "1" ]]; then
            systemctl restart hysteria-server.service 2>>"$LOG_FILE" || log_warn "hysteria-server не запустился"
        fi
    else
        # VK: сначала WG, потом vk-turn-proxy
        systemctl unmask wg-quick@wg0 2>/dev/null || true
        systemctl start wg-quick@wg0 2>>"$LOG_FILE" || log_warn "wg-quick@wg0 не запустился"
        sleep 2

        # Проверяем сеть после запуска WG
        if ! curl -fsS --max-time 5 ifconfig.me > /dev/null 2>&1; then
            log_warn "СЕТЬ ПРОПАЛА после запуска WireGuard! Пробуем остановить..."
            systemctl stop wg-quick@wg0 2>/dev/null || true
        else
            systemctl enable wg-quick@wg0
        fi

        systemctl restart vk-turn-proxy 2>>"$LOG_FILE" || log_warn "vk-turn-proxy не запустился"
        if [[ "${HY2_ENABLE}" == "1" ]]; then
            systemctl restart hysteria-server.service 2>>"$LOG_FILE" || log_warn "hysteria-server не запустился"
        fi
    fi

    systemctl restart vpn-node-api 2>>"$LOG_FILE" || log_warn "vpn-node-api не запустился"
    sleep 2
}

# ─── Итоговый вывод ──────────────────────────────────────────────────────────
print_summary() {
    local pub_ip
    pub_ip=$(curl -fsS --max-time 10 ifconfig.me 2>/dev/null || echo "N/A")
    local server_pub=""
    [[ -f /etc/wireguard/server_public ]] && server_pub=$(cat /etc/wireguard/server_public)

    local api_url="http://${pub_ip}:${API_PORT}"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ Установка завершена успешно!                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Нода:        ${YELLOW}${NODE_NAME}${NC}  [${BOLD}${INSTALL_MODE^^}${NC}]"
    echo -e "  Публичный IP:${YELLOW}${pub_ip}${NC}"
    echo -e "  VPN Subnet:  ${YELLOW}${VPN_SUBNET}${NC}"
    echo -e "  WG PubKey:   ${YELLOW}${server_pub}${NC}"
    echo ""
    echo -e "  API URL:     ${YELLOW}${api_url}${NC}"
    echo -e "  API Token:   ${YELLOW}${API_TOKEN}${NC}"
    echo ""

    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        echo -e "  DTLS порт:   ${YELLOW}${WDTT_DTLS_PORT}${NC}"
        echo -e "  WG порт:     ${YELLOW}${WDTT_WG_PORT}${NC}"
        if [[ ! -f /usr/local/bin/wdtt-server ]]; then
            echo ""
            echo -e "  ${RED}⚠ wdtt-server НЕ УСТАНОВЛЕН!${NC}"
            echo -e "  Скопируйте бинарник и запустите: systemctl start wdtt"
        fi
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        echo -e "  VK TURN порт:${YELLOW}${VK_TURN_PORT}${NC}  (wg0:${VK_WG_PORT})"
        echo -e "  WDTT DTLS:   ${YELLOW}${WDTT_DTLS_PORT}${NC}  (WG:${WDTT_WG_PORT})"
        [[ "${HY2_ENABLE}" == "1" ]] && echo -e "  HY2 порт:     ${YELLOW}${HY2_PORT}${NC}"
        echo -e "  Режим:       ${YELLOW}dual${NC} (старые VK конфиги сохраняются)"
    else
        echo -e "  TURN порт:   ${YELLOW}${VK_TURN_PORT}${NC}"
        echo -e "  WG порт:     ${YELLOW}${VK_WG_PORT}${NC}"
        [[ "${HY2_ENABLE}" == "1" ]] && echo -e "  HY2 порт:     ${YELLOW}${HY2_PORT}${NC}"
    fi

    echo ""
    echo -e "${YELLOW}  ─── Добавить ноду в бот ──────────────────────────────${NC}"
    echo -e "  ./nodeadd.sh ${NODE_NAME} ${pub_ip} user1 <ssh_pass> 0 \\"
    echo -e "               ${api_url} ${API_TOKEN} 1"
    echo ""
    echo -e "  Затем в боте: /set_mode ${NODE_NAME} ${INSTALL_MODE}"
    echo -e "                /set_subnet ${NODE_NAME} ${VPN_SUBNET}"
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
}

# ────────────────────────────────────────────────────────────────────────────
#  ОБНОВЛЕНИЕ УЖЕ НАСТРОЕННОЙ НОДЫ ДО WDTT
#  Вызвать: bash nodesetup_wdtt.sh --upgrade-to-wdtt
# ────────────────────────────────────────────────────────────────────────────
upgrade_to_wdtt() {
    log_step "Обновление ноды с VK TURN → WDTT..."

    # 1. Останавливаем старые сервисы
    systemctl stop vk-turn-proxy 2>/dev/null || true
    systemctl disable vk-turn-proxy 2>/dev/null || true
    # WG оставляем работать — wdtt-server будет управлять им сам

    # 2. Если нет wdtt-server — пробуем скачать
    if [[ ! -f /usr/local/bin/wdtt-server ]]; then
        if [[ -n "$WDTT_BINARY_URL" ]]; then
            log_info "Загрузка wdtt-server..."
            curl -fsSL -o /usr/local/bin/wdtt-server "$WDTT_BINARY_URL" && \
                chmod +x /usr/local/bin/wdtt-server || \
                log_warn "Не удалось загрузить. Скопируйте бинарник вручную в /usr/local/bin/wdtt-server"
        else
            log_warn "Укажите --wdtt-url <url> или скопируйте wdtt-server вручную в /usr/local/bin/"
        fi
    fi

    # 3. Обновляем sysctl и NAT
    detect_firewall
    auto_select_subnet
    setup_sysctl

    local iface
    iface=$(detect_wan_interface)
    # Добавляем WDTT-порты в firewall
    fw_add_input_tcp 22
    fw_established
    fw_add_input_udp "$WDTT_DTLS_PORT"
    fw_add_input_udp "$WDTT_WG_PORT"
    case "$FW_BACKEND" in
        iptables) iptables -C INPUT -p udp --dport 1024:65535 -j ACCEPT 2>/dev/null || \
                  iptables -I INPUT -p udp --dport 1024:65535 -j ACCEPT 2>/dev/null || true ;;
        nft)      nft add rule inet filter input udp dport 1024-65535 accept 2>/dev/null || true ;;
    esac
    fw_add_mss_clamping "$VPN_SUBNET"

    # 4. Создаём сервис wdtt
    setup_wdtt_service

    # 5. Обновляем env и Node API
    INSTALL_MODE="wdtt"
    save_env

    # Обновляем NODE_MODE в API env
    if [[ -f /etc/vpn-node-api.env ]]; then
        sed -i 's/^NODE_MODE=.*/NODE_MODE=wdtt/' /etc/vpn-node-api.env
        sed -i "s/^WG_PORT=.*/WG_PORT=${WDTT_WG_PORT}/" /etc/vpn-node-api.env
        sed -i "s/^TURN_PORT=.*/TURN_PORT=${WDTT_DTLS_PORT}/" /etc/vpn-node-api.env
        systemctl restart vpn-node-api 2>/dev/null || true
    fi

    # 6. Запускаем wdtt если бинарник есть
    if [[ -f /usr/local/bin/wdtt-server ]]; then
        systemctl restart wdtt
        sleep 2
        if systemctl is-active wdtt &>/dev/null; then
            log_info "wdtt запущен успешно!"
        else
            log_warn "wdtt не запустился. journalctl -u wdtt -n 20"
        fi
    fi

    echo ""
    echo -e "${GREEN}✅ Обновление до WDTT завершено!${NC}"
    echo ""
    echo "  В боте выполните:"
    echo -e "  ${YELLOW}/set_mode <ваша_нода> wdtt${NC}"
    echo ""
    echo "  Пользователи должны получить новые конфиги через /start"
}

detect_installed_mode() {
    if [[ -f /etc/vpn-node.env ]]; then
        # shellcheck disable=SC1091
        source /etc/vpn-node.env
        if [[ "${NODE_MODE:-}" == "wdtt" || "${NODE_MODE:-}" == "vk" || "${NODE_MODE:-}" == "dual" ]]; then
            echo "$NODE_MODE"
            return
        fi
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^wdtt\.service' && \
       systemctl list-unit-files 2>/dev/null | grep -q '^vk-turn-proxy\.service'; then
        echo "dual"
        return
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^wdtt\.service'; then
        echo "wdtt"
        return
    fi
    echo "vk"
}

upgrade_existing_node() {
    log_step "Обновление уже установленной ноды (без чистой переустановки)..."

    # Подтягиваем текущие параметры, если есть
    if [[ -f /etc/vpn-node.env ]]; then
        # shellcheck disable=SC1091
        source /etc/vpn-node.env
    fi

    if [[ -z "${INSTALL_MODE:-}" ]]; then
        INSTALL_MODE="$(detect_installed_mode)"
    fi

    if [[ "$INSTALL_MODE" != "vk" && "$INSTALL_MODE" != "wdtt" && "$INSTALL_MODE" != "dual" ]]; then
        die "Неверный режим обновления: $INSTALL_MODE (допустимо: vk|wdtt|dual)"
    fi

    [[ -n "${NODE_NAME:-}" ]] || NODE_NAME="$(hostname -s)"
    [[ -n "${VPN_SUBNET:-}" ]] || VPN_SUBNET=$([[ "$INSTALL_MODE" == "wdtt" ]] && echo "10.66.66.0/24" || echo "172.16.0.0/12")
    [[ -n "${API_TOKEN:-}" ]]  || API_TOKEN="$(openssl rand -hex 32)"

    log_info "Режим обновления: ${INSTALL_MODE^^} | Нода: ${NODE_NAME} | Подсеть: ${VPN_SUBNET}"

    backup_iptables
    install_packages
    setup_sysctl

    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        install_wdtt_server
        setup_wdtt_service
        setup_node_api
        setup_nat
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        setup_wireguard "$VK_WG_PORT"
        install_vk_turn_proxy
        install_hy2_server
        install_wdtt_server
        setup_wdtt_service
        setup_node_api
        setup_nat
    else
        setup_wireguard "$VK_WG_PORT"
        install_vk_turn_proxy
        install_hy2_server
        setup_node_api
        setup_nat
    fi

    save_env
    start_services
    print_summary
}

# ════════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  VPN Node Setup v${SCRIPT_VERSION} — WDTT + VK unified        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

    check_root

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== VPN Node Setup v${SCRIPT_VERSION} — $(date) ===" >> "$LOG_FILE"

    # Проверяем специальный режим обновления
    if [[ "${1:-}" == "--upgrade-to-wdtt" ]]; then
        detect_os
        detect_firewall
        # Читаем текущий env если есть
        [[ -f /etc/vpn-node.env ]] && source /etc/vpn-node.env
        [[ -n "${VPN_SUBNET:-}" ]] || VPN_SUBNET="10.66.66.0/24"
        [[ -n "${NODE_NAME:-}" ]]  || NODE_NAME="unknown"
        shift
        # Парсим доп. флаги (например --wdtt-url)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --wdtt-url) WDTT_BINARY_URL="$2"; shift 2 ;;
                --wdtt-dtls-port) WDTT_DTLS_PORT="$2"; shift 2 ;;
                --wdtt-wg-port)   WDTT_WG_PORT="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        upgrade_to_wdtt
        return 0
    fi

    # Обновление уже установленной ноды в текущем режиме
    if [[ "${1:-}" == "--upgrade-existing" || "${1:-}" == "--upgrade-vk" || "${1:-}" == "--upgrade-dual" ]]; then
        local upgrade_cmd="${1:-}"
        shift
        detect_os
        detect_firewall
        parse_upgrade_args "$@"
        if [[ "$upgrade_cmd" == "--upgrade-vk" && -z "${INSTALL_MODE:-}" ]]; then
            INSTALL_MODE="vk"
        fi
        if [[ "$upgrade_cmd" == "--upgrade-dual" && -z "${INSTALL_MODE:-}" ]]; then
            INSTALL_MODE="dual"
        fi
        upgrade_existing_node
        return 0
    fi

    parse_args "$@"
    detect_os
    detect_firewall
    auto_select_subnet
    save_env

    log_step "Режим установки: ${INSTALL_MODE^^}"
    log_step "Нода: ${NODE_NAME} | Подсеть: ${VPN_SUBNET}"

    backup_iptables
    install_packages
    setup_sysctl

    if [[ "$INSTALL_MODE" == "wdtt" ]]; then
        # WDTT не использует wg-quick — wdtt-server управляет WG
        install_wdtt_server
        setup_wdtt_service
        setup_node_api
        setup_nat
    elif [[ "$INSTALL_MODE" == "dual" ]]; then
        # Dual: оставляем VK на wg0 и добавляем WDTT на отдельные порты
        setup_wireguard "$VK_WG_PORT"
        install_vk_turn_proxy
        install_hy2_server
        install_wdtt_server
        setup_wdtt_service
        setup_node_api
        setup_nat
    else
        # VK TURN: стандартный WG + vk-turn-proxy
        setup_wireguard "$VK_WG_PORT"
        install_vk_turn_proxy
        install_hy2_server
        setup_node_api
        setup_nat
    fi

    start_services
    print_summary
}

main "$@"
