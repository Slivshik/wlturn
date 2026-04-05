#!/bin/bash
set -e

# ==================================================
# БЕЗОПАСНАЯ УСТАНОВКА НОДЫ (WireGuard + TURN)
# Ничего не блокирует, SSH остаётся доступным.
# ==================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка ноды для VPN-бота ===${NC}"

# --- Ввод параметров ---
read -p "Введите имя ноды (например SE-1, FI-1): " NODE_NAME
read -p "Введите пароль для SSH (будет использован ботом): " SSH_PASSWORD
read -p "Порт WireGuard [51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}
read -p "Порт TURN-прокси [56000]: " TURN_PORT
TURN_PORT=${TURN_PORT:-56000}

# --- Определение внешнего интерфейса ---
EXT_IF=$(ip route | grep default | awk '{print $5}')
echo -e "${YELLOW}Внешний интерфейс: $EXT_IF${NC}"

# --- 1. Базовая подготовка (безопасная) ---
apt update && apt upgrade -y
apt install wireguard net-tools curl iptables-persistent -y

# --- 2. Гарантируем, что SSH не заблокирован (на всякий случай) ---
iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
netfilter-persistent save

# --- 3. Включаем IP-форвардинг (нужно для маршрутизации) ---
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# --- 4. Настройка WireGuard ---
cd /etc/wireguard
umask 077
wg genkey | tee server_private | wg pubkey > server_public

cat > wg0.conf <<EOF
[Interface]
PrivateKey = $(cat server_private)
Address = 10.0.0.1/13
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $EXT_IF -j MASQUERADE
EOF

# Запуск WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# --- 5. TURN-прокси ---
cd /opt
wget -q -O vk-turn-proxy https://github.com/kiper292/vk-turn-proxy/releases/download/v2.0.2/server-linux-amd64
chmod +x vk-turn-proxy

cat > /etc/systemd/system/vk-turn-proxy.service <<EOF
[Unit]
Description=VK Turn Proxy
After=network.target

[Service]
Type=simple
ExecStart=/opt/vk-turn-proxy -listen 0.0.0.0:$TURN_PORT -connect 127.0.0.1:$WG_PORT
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vk-turn-proxy
systemctl start vk-turn-proxy

# --- 6. Сохраняем правила iptables (чтобы не сбросились при перезагрузке) ---
netfilter-persistent save

# --- 7. Вывод информации для бота ---
PUB_KEY=$(cat /etc/wireguard/server_public)
IP=$(curl -s ifconfig.me)

echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}✅ Нода $NODE_NAME успешно настроена!${NC}"
echo -e "Публичный ключ: ${YELLOW}$PUB_KEY${NC}"
echo -e "IP сервера: ${YELLOW}$IP${NC}"
echo -e "SSH user: root"
echo -e "SSH password: ${YELLOW}$SSH_PASSWORD${NC}"
echo -e "${GREEN}=====================================${NC}"
echo -e "Теперь выполните на сервере бота команду для добавления ноды:"
echo -e "./add_node_to_bot.sh $NODE_NAME $IP root \"$SSH_PASSWORD\" 0"
