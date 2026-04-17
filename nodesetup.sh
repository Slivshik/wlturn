#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

retry() {
    local max_attempts=5
    local delay=5
    local attempt=1
    local cmd="$*"
    until $cmd; do
        if (( attempt >= max_attempts )); then
            echo -e "${RED}Команда '$cmd' не удалась после $max_attempts попыток.${NC}"
            return 1
        fi
        echo -e "${YELLOW}Попытка $attempt не удалась. Повтор через ${delay}с...${NC}"
        sleep $delay
        ((attempt++))
    done
}

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

echo -e "${GREEN}=== Безопасная установка VPN-ноды ===${NC}"

# Загрузка сохранённых параметров
if [[ -f /etc/vpn-node.env ]]; then
    source /etc/vpn-node.env
    echo -e "${YELLOW}Используем сохранённые параметры для ноды ${NODE_NAME}${NC}"
else
    read -r -p "Имя ноды: " NODE_NAME
    read -r -p "Пароль SSH (для экстренного доступа): " SSH_PASSWORD
    WG_PORT="${WG_PORT:-51820}"
    TURN_PORT="${TURN_PORT:-56000}"
    API_PORT="${API_PORT:-8787}"
    API_HOST="${API_HOST:-0.0.0.0}"
    read -r -p "API токен (пусто = автогенерация): " API_TOKEN
    API_TOKEN="${API_TOKEN:-$(openssl rand -hex 32)}"
    cat > /etc/vpn-node.env <<EOF
NODE_NAME="${NODE_NAME}"
SSH_PASSWORD="${SSH_PASSWORD}"
WG_PORT="${WG_PORT}"
TURN_PORT="${TURN_PORT}"
API_PORT="${API_PORT}"
API_HOST="${API_HOST}"
API_TOKEN="${API_TOKEN}"
EOF
    chmod 600 /etc/vpn-node.env
fi

EXT_IF=$(ip route | grep default | awk '{print $5}')
echo -e "${YELLOW}Внешний интерфейс: $EXT_IF${NC}"

# ------------------------------------------------------------------------------
# 1. Установка пакетов
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Пакеты...${NC}"
apt update -y
apt install -y wireguard net-tools curl iptables-persistent python3-venv python3-pip

# ------------------------------------------------------------------------------
# 2. Резервное копирование текущих правил iptables
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/7] Резервное копирование iptables...${NC}"
iptables-save > /root/iptables.backup.$(date +%s)
echo "Резервная копия сохранена в /root/iptables.backup.*"

# ------------------------------------------------------------------------------
# 3. Настройка IP-форвардинга (безопасно)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[3/7] IP forwarding...${NC}"
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ------------------------------------------------------------------------------
# 4. WireGuard — НАСТРОЙКА БЕЗ ЗАПУСКА
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Конфигурация WireGuard (без запуска)...${NC}"
cd /etc/wireguard
umask 077
if [[ ! -f server_private ]]; then
    wg genkey | tee server_private | wg pubkey > server_public
fi
SERVER_PRIVATE=$(cat server_private)
SERVER_PUBLIC=$(cat server_public)

# Важно: PostUp и PostDown должны быть безопасными
cat > wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address = 10.0.0.1/13
ListenPort = ${WG_PORT}
# Безопасные правила: MASQUERADE ТОЛЬКО для трафика из туннеля
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/13 -o ${EXT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/13 -o ${EXT_IF} -j MASQUERADE
EOF

# ЯВНО ЗАПРЕЩАЕМ автоматический запуск при установке пакета
systemctl mask wg-quick@wg0 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. TURN-прокси
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[5/7] TURN прокси...${NC}"
if [[ ! -f /opt/vk-turn-proxy ]]; then
    retry wget -q -O /opt/vk-turn-proxy https://github.com/kiper292/vk-turn-proxy/releases/download/v2.0.7/server-linux-amd64
    chmod +x /opt/vk-turn-proxy
fi

cat > /etc/systemd/system/vk-turn-proxy.service <<EOF
[Unit]
Description=VK Turn Proxy
After=network.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/vk-turn-proxy -listen 0.0.0.0:${TURN_PORT} -connect 127.0.0.1:${WG_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vk-turn-proxy

# ------------------------------------------------------------------------------
# 6. Node API (Python)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[6/7] Node API...${NC}"
id -u vpnnodeapi &>/dev/null || useradd --system --home /opt/vpn-node-api --shell /usr/sbin/nologin vpnnodeapi
mkdir -p /opt/vpn-node-api
cd /opt/vpn-node-api

cat > requirements.txt <<'REQ'
fastapi==0.115.6
uvicorn==0.32.1
REQ

if [[ ! -d .venv ]]; then
    python3 -m venv .venv
fi
retry .venv/bin/pip install --upgrade pip
retry .venv/bin/pip install -r requirements.txt

# Код API (тот же, что раньше)
cat > app.py <<'PY'
# ... (вставьте код app.py из предыдущего ответа)
PY

cat > /etc/vpn-node-api.env <<EOF
VPN_NODE_API_TOKEN=${API_TOKEN}
WG_PORT=${WG_PORT}
TURN_PORT=${TURN_PORT}
NODE_NAME=${NODE_NAME}
CMD_TIMEOUT=12
EOF
chmod 600 /etc/vpn-node-api.env

cat > /etc/systemd/system/vpn-node-api.service <<EOF
[Unit]
Description=VPN Node API
After=network.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/vpn-node-api.env
WorkingDirectory=/opt/vpn-node-api
ExecStart=/opt/vpn-node-api/.venv/bin/uvicorn app:app --host ${API_HOST} --port ${API_PORT} --workers 1
Restart=always
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-node-api

# ------------------------------------------------------------------------------
# 7. ФИНАЛЬНЫЙ ЗАПУСК WIREGUARD С ПРОВЕРКОЙ СЕТИ
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[7/7] Запуск WireGuard с контролем сети...${NC}"

# Сначала проверяем, что правила iptables не поломают SSH
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
netfilter-persistent save

# Размаскируем и запускаем
systemctl unmask wg-quick@wg0
systemctl start wg-quick@wg0

echo "Проверка доступности интернета..."
sleep 3
if ! curl -s --max-time 5 ifconfig.me > /dev/null; then
    echo -e "${RED}ОШИБКА: После запуска WireGuard пропал интернет! Откат...${NC}"
    systemctl stop wg-quick@wg0
    iptables -F
    iptables -t nat -F
    iptables-restore < /root/iptables.backup.* 2>/dev/null || true
    echo -e "${RED}Сервер возвращён в исходное состояние. Свяжитесь с администратором.${NC}"
    exit 1
fi

systemctl enable wg-quick@wg0
systemctl restart vk-turn-proxy
systemctl restart vpn-node-api

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
PUB_IP="$(curl -fsS ifconfig.me)"
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}✅ Установка завершена успешно!${NC}"
echo -e "Нода:            ${YELLOW}${NODE_NAME}${NC}"
echo -e "IP:              ${YELLOW}${PUB_IP}${NC}"
echo -e "WG Public Key:   ${YELLOW}${SERVER_PUBLIC}${NC}"
echo -e "API URL:         ${YELLOW}http://${PUB_IP}:${API_PORT}${NC}"
echo -e "API Token:       ${YELLOW}${API_TOKEN}${NC}"
echo -e "${GREEN}=====================================${NC}"
