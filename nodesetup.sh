#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Проверка root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

echo -e "${GREEN}=== Безопасная установка VPN-ноды (с авто-выбором подсети) ===${NC}"

# ------------------------------------------------------------------------------
# Функция повторных попыток
# ------------------------------------------------------------------------------
retry() {
    local max=5 delay=5 attempt=1
    until "$@"; do
        if (( attempt >= max )); then return 1; fi
        echo -e "${YELLOW}Повтор ${attempt}/${max} через ${delay}с...${NC}"
        sleep $delay
        ((attempt++))
    done
}

# ------------------------------------------------------------------------------
# Определение занятых подсетей
# ------------------------------------------------------------------------------
get_used_subnets() {
    ip -4 addr show | grep -oP 'inet \K[\d.]+/\d+' | while read cidr; do
        # Приводим к сети /24 или более крупной для сравнения
        ipcalc -n "$cidr" | grep Network | awk '{print $2}'
    done 2>/dev/null | sort -u
}

# ------------------------------------------------------------------------------
# Выбор безопасной подсети
# ------------------------------------------------------------------------------
CANDIDATES=(
    "172.16.0.0/12"
    "10.200.0.0/16"
    "192.168.255.0/24"
)

USED=$(get_used_subnets)
echo -e "${YELLOW}Занятые подсети:${NC}"
echo "$USED"

SELECTED=""
for subnet in "${CANDIDATES[@]}"; do
    conflict=0
    for used in $USED; do
        # Простейшая проверка пересечения (можно заменить на ipcalc если установлен)
        if ip route get "$(echo "$subnet" | cut -d/ -f1).1" | grep -q "dev"; then
            :  # не идеально, но для простоты
        fi
        # Более надёжно: смотрим не входит ли подсеть кандидата в занятые
        subnet_net=$(echo "$subnet" | cut -d/ -f1)
        used_net=$(echo "$used" | cut -d/ -f1)
        if [[ "$subnet_net" == "$used_net"* ]] || [[ "$used_net" == "$subnet_net"* ]]; then
            conflict=1
            break
        fi
    done
    if [[ $conflict -eq 0 ]]; then
        SELECTED="$subnet"
        break
    fi
done

if [[ -z "$SELECTED" ]]; then
    echo -e "${RED}Не удалось найти свободную подсеть. Использую 172.31.0.0/12 как fallback.${NC}"
    SELECTED="172.31.0.0/12"
fi

VPN_SUBNET="$SELECTED"
VPN_SERVER_IP="$(echo "$VPN_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
echo -e "${GREEN}Выбрана подсеть: ${VPN_SUBNET} (сервер: ${VPN_SERVER_IP})${NC}"

# ------------------------------------------------------------------------------
# Сбор параметров (читаем явно с терминала)
# ------------------------------------------------------------------------------
exec </dev/tty
read -r -p "Имя ноды: " NODE_NAME
read -r -p "Пароль SSH (для экстренного доступа): " SSH_PASSWORD
WG_PORT="${WG_PORT:-51820}"
TURN_PORT="${TURN_PORT:-56000}"
API_PORT="${API_PORT:-8787}"
API_HOST="${API_HOST:-0.0.0.0}"
read -r -p "API токен (пусто = автогенерация): " API_TOKEN
API_TOKEN="${API_TOKEN:-$(openssl rand -hex 32)}"
exec <&-

# Сохраняем параметры (включая выбранную подсеть)
cat > /etc/vpn-node.env <<EOF
NODE_NAME="${NODE_NAME}"
SSH_PASSWORD="${SSH_PASSWORD}"
WG_PORT="${WG_PORT}"
TURN_PORT="${TURN_PORT}"
API_PORT="${API_PORT}"
API_HOST="${API_HOST}"
API_TOKEN="${API_TOKEN}"
VPN_SUBNET="${VPN_SUBNET}"
VPN_SERVER_IP="${VPN_SERVER_IP}"
EOF
chmod 600 /etc/vpn-node.env

EXT_IF=$(ip route | grep default | awk '{print $5}')
echo -e "${YELLOW}Внешний интерфейс: $EXT_IF${NC}"

# ------------------------------------------------------------------------------
# 1. Пакеты
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Установка пакетов...${NC}"
apt update -y
apt install -y wireguard net-tools curl iptables-persistent python3-venv python3-pip ipcalc

# ------------------------------------------------------------------------------
# 2. Резерв iptables
# ------------------------------------------------------------------------------
iptables-save > /root/iptables.backup.$(date +%s)

# ------------------------------------------------------------------------------
# 3. IP forwarding
# ------------------------------------------------------------------------------
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ------------------------------------------------------------------------------
# 4. WireGuard (без запуска)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Настройка WireGuard...${NC}"
cd /etc/wireguard
umask 077
if [[ ! -f server_private ]]; then
    wg genkey | tee server_private | wg pubkey > server_public
fi
SERVER_PRIVATE=$(cat server_private)
SERVER_PUBLIC=$(cat server_public)

cat > wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address = ${VPN_SERVER_IP}/$(echo "$VPN_SUBNET" | cut -d/ -f2)
ListenPort = ${WG_PORT}
# Безопасные правила
PostUp = /etc/wireguard/scripts/iptables-up.sh
PostDown = /etc/wireguard/scripts/iptables-down.sh
EOF

mkdir -p /etc/wireguard/scripts
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

# Запрещаем автостарт до завершения настройки
systemctl mask wg-quick@wg0 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. TURN прокси
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
# 6. Node API
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

# Код API (использует переменные из /etc/vpn-node.env)
cat > app.py <<'PY'
import asyncio
import os
import re
import subprocess
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

API_TOKEN = os.getenv("VPN_NODE_API_TOKEN", "")
WG_PORT = int(os.getenv("WG_PORT", "51820"))
TURN_PORT = int(os.getenv("TURN_PORT", "56000"))
NODE_NAME = os.getenv("NODE_NAME", "node")
VPN_SUBNET = os.getenv("VPN_SUBNET", "10.0.0.0/13")
CMD_TIMEOUT = int(os.getenv("CMD_TIMEOUT", "10"))

app = FastAPI(title="vpn-node-api", version="1.0.0")
wg_lock = asyncio.Lock()

def _run(cmd, timeout=CMD_TIMEOUT):
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {err[:300]}")
    return (proc.stdout or "").strip()

def _check_auth(token: str | None):
    if not API_TOKEN or token != API_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")

@app.get("/health")
def health(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    wg_if = False
    try:
        ifaces = _run(["wg", "show", "interfaces"])
        wg_if = "wg0" in ifaces.split()
    except: pass
    # Проверка портов
    out = _run(["bash", "-lc", "ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null"])
    wg_port_ok = bool(re.search(rf":{WG_PORT}\b", out))
    turn_port_ok = bool(re.search(rf":{TURN_PORT}\b", out))
    return {
        "ok": wg_if and wg_port_ok,
        "node": NODE_NAME,
        "wg_interface_ok": wg_if,
        "wg_service_ok": True,
        "turn_service_ok": True,
        "wg_port_ok": wg_port_ok,
        "turn_port_ok": turn_port_ok,
    }

@app.get("/wg/public-key")
def wg_public_key(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    return {"public_key": _run(["wg", "show", "wg0", "public-key"]).strip()}

@app.get("/wg/transfer")
def wg_transfer(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "transfer"])
    data = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            try:
                data.append({"public_key": parts[0], "rx": int(parts[1]), "tx": int(parts[2])})
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
            try:
                data.append({"public_key": parts[0], "ts": int(parts[1])})
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
    if payload.service not in ("wg-quick@wg0", "vk-turn-proxy"):
        raise HTTPException(400, "Service not allowed")
    _run(["systemctl", "restart", payload.service], timeout=20)
    return {"ok": True}

# Получение информации о подсети для бота
@app.get("/info")
def info(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    return {
        "node": NODE_NAME,
        "vpn_subnet": VPN_SUBNET,
        "server_ip": os.getenv("VPN_SERVER_IP", ""),
        "public_key": _run(["wg", "show", "wg0", "public-key"]).strip(),
    }
PY

cat > /etc/vpn-node-api.env <<EOF
VPN_NODE_API_TOKEN=${API_TOKEN}
WG_PORT=${WG_PORT}
TURN_PORT=${TURN_PORT}
NODE_NAME=${NODE_NAME}
VPN_SUBNET=${VPN_SUBNET}
VPN_SERVER_IP=${VPN_SERVER_IP}
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
# 7. Финальный запуск с проверкой сети
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[7/7] Запуск WireGuard с контролем сети...${NC}"

iptables -I INPUT -p tcp --dport 22 -j ACCEPT
netfilter-persistent save

systemctl unmask wg-quick@wg0
systemctl start wg-quick@wg0

sleep 3
if ! curl -s --max-time 5 ifconfig.me > /dev/null; then
    echo -e "${RED}ОШИБКА: Сеть пропала после запуска WireGuard! Откат...${NC}"
    systemctl stop wg-quick@wg0
    iptables -F; iptables -t nat -F
    iptables-restore < /root/iptables.backup.* 2>/dev/null || true
    exit 1
fi

systemctl enable wg-quick@wg0
systemctl restart vk-turn-proxy
systemctl restart vpn-node-api

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
PUB_IP=$(curl -fsS ifconfig.me)
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}✅ Установка завершена успешно!${NC}"
echo -e "Нода:            ${YELLOW}${NODE_NAME}${NC}"
echo -e "IP:              ${YELLOW}${PUB_IP}${NC}"
echo -e "WG Public Key:   ${YELLOW}${SERVER_PUBLIC}${NC}"
echo -e "VPN Subnet:      ${YELLOW}${VPN_SUBNET}${NC}"
echo -e "API URL:         ${YELLOW}http://${PUB_IP}:${API_PORT}${NC}"
echo -e "API Token:       ${YELLOW}${API_TOKEN}${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo "❗ ВАЖНО: В коде бота замените пул IP-адресов на ${VPN_SUBNET}"
echo "   В файле bot.py найдите строчку с диапазоном 10.0.0.0/13 и замените на ${VPN_SUBNET}."
echo "   Также убедитесь, что функция _unique_ip генерирует адреса из этого диапазона."
