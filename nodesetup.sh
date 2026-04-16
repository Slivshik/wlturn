#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Запустите скрипт от root (sudo).${NC}"
    exit 1
fi

echo -e "${GREEN}=== Установка VPN-ноды (WireGuard + TURN + API) ===${NC}"

# ---------------------------------------------------------------------------
# Сбор параметров
# ---------------------------------------------------------------------------
read -r -p "Имя ноды (например, RU-1): " NODE_NAME
read -r -p "Пароль для SSH (для экстренного доступа, если API откажет): " SSH_PASSWORD
read -r -p "Порт WireGuard [51820]: " WG_PORT
WG_PORT="${WG_PORT:-51820}"
read -r -p "Порт TURN прокси [56000]: " TURN_PORT
TURN_PORT="${TURN_PORT:-56000}"
read -r -p "Порт API [8787]: " API_PORT
API_PORT="${API_PORT:-8787}"
read -r -p "Хост для привязки API [0.0.0.0]: " API_HOST
API_HOST="${API_HOST:-0.0.0.0}"
read -r -p "API токен (оставьте пустым для авто-генерации): " API_TOKEN
if [[ -z "${API_TOKEN}" ]]; then
    API_TOKEN="$(openssl rand -hex 32)"
    echo -e "${YELLOW}Сгенерирован токен: ${API_TOKEN}${NC}"
fi

# Определяем внешний интерфейс
EXT_IF=$(ip route | grep default | awk '{print $5}')
echo -e "${YELLOW}Внешний интерфейс: $EXT_IF${NC}"

# ---------------------------------------------------------------------------
# 1. Установка системных пакетов
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Установка пакетов...${NC}"
apt update -y
apt upgrade -y
apt install -y wireguard net-tools curl iptables-persistent \
               python3 python3-venv python3-pip

# ---------------------------------------------------------------------------
# 2. Базовая защита SSH (на случай сбоя iptables)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[2/7] Резервирование SSH-доступа...${NC}"
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
netfilter-persistent save

# ---------------------------------------------------------------------------
# 3. Включение IP-форвардинга
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[3/7] Включение IP forwarding...${NC}"
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ---------------------------------------------------------------------------
# 4. Настройка WireGuard с ПРАВИЛЬНОЙ подсетью 10.0.0.0/13
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Настройка WireGuard...${NC}"
cd /etc/wireguard
umask 077

# Генерируем ключи, если ещё нет
if [[ ! -f server_private ]]; then
    wg genkey | tee server_private | wg pubkey > server_public
fi
SERVER_PRIVATE=$(cat server_private)
SERVER_PUBLIC=$(cat server_public)

# Создаём конфиг wg0.conf с подсетью, совместимой с ботом
cat > wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address = 10.0.0.1/13
ListenPort = ${WG_PORT}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${EXT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${EXT_IF} -j MASQUERADE
EOF

# Запускаем WireGuard
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# Проверка, что SSH всё ещё слушается (защита от блокировки)
sleep 5
if ! ss -tln | grep -q ":22 "; then
    echo -e "${RED}ОШИБКА: SSH порт 22 перестал слушаться! Откат WireGuard...${NC}"
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o ${EXT_IF} -j MASQUERADE 2>/dev/null || true
    netfilter-persistent save
    echo -e "${RED}Откат выполнен. Проверьте конфигурацию сети вручную.${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Установка TURN-прокси (vk-turn-proxy)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[5/7] Установка TURN прокси...${NC}"
cd /opt
if [[ ! -f vk-turn-proxy ]]; then
    wget -q -O vk-turn-proxy https://github.com/kiper292/vk-turn-proxy/releases/download/v2.0.2/server-linux-amd64
    chmod +x vk-turn-proxy
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
systemctl restart vk-turn-proxy

# ---------------------------------------------------------------------------
# 6. Установка Node API (управление без SSH)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[6/7] Установка Node API...${NC}"

# Создаём системного пользователя
id -u vpnnodeapi >/dev/null 2>&1 || useradd --system --home /opt/vpn-node-api --shell /usr/sbin/nologin vpnnodeapi

mkdir -p /opt/vpn-node-api
cd /opt/vpn-node-api

# Python зависимости
cat > requirements.txt <<'REQ'
fastapi==0.115.6
uvicorn==0.32.1
REQ

python3 -m venv .venv
.venv/bin/pip install --upgrade pip >/dev/null
.venv/bin/pip install -r requirements.txt >/dev/null

# Код API (тот же, что был предоставлен)
cat > app.py <<'PY'
import asyncio
import os
import re
import subprocess
from typing import Dict, List

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

API_TOKEN = os.getenv("VPN_NODE_API_TOKEN", "")
WG_PORT = int(os.getenv("WG_PORT", "51820"))
TURN_PORT = int(os.getenv("TURN_PORT", "56000"))
NODE_NAME = os.getenv("NODE_NAME", "node")
CMD_TIMEOUT = int(os.getenv("CMD_TIMEOUT", "10"))

app = FastAPI(title="vpn-node-api", version="1.0.0")
wg_lock = asyncio.Lock()


def _run(cmd: List[str], timeout: int = CMD_TIMEOUT) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {err[:300]}")
    return (proc.stdout or "").strip()


def _check_auth(token: str | None) -> None:
    if not API_TOKEN:
        raise HTTPException(status_code=500, detail="Server token is not configured")
    if token != API_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")


def _svc_active(name: str) -> bool:
    try:
        out = _run(["systemctl", "is-active", name], timeout=5).strip()
        return out in ("active", "activating")
    except Exception:
        return False


def _ports_state() -> Dict[str, bool]:
    out = _run(["bash", "-lc", "ss -ulnp 2>/dev/null; ss -tlnp 2>/dev/null"], timeout=5)
    wg_ok = bool(re.search(rf":{WG_PORT}\b", out))
    turn_ok = bool(re.search(rf":{TURN_PORT}\b", out))
    return {"wg_port_ok": wg_ok, "turn_port_ok": turn_ok}


class PeerUpsert(BaseModel):
    public_key: str = Field(min_length=44, max_length=44)
    ip: str = Field(pattern=r"^10\.\d+\.\d+\.\d+$")


class PeerRemove(BaseModel):
    public_key: str = Field(min_length=44, max_length=44)


class RestartReq(BaseModel):
    service: str


@app.get("/health")
def health(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    wg_if = False
    try:
        ifaces = _run(["wg", "show", "interfaces"], timeout=5)
        wg_if = "wg0" in ifaces.split()
    except Exception:
        wg_if = False

    ports = _ports_state()
    payload = {
        "ok": wg_if and ports["wg_port_ok"],
        "node": NODE_NAME,
        "wg_interface_ok": wg_if,
        "wg_service_ok": _svc_active("wg-quick@wg0"),
        "turn_service_ok": _svc_active("vk-turn-proxy"),
        "wg_port_ok": ports["wg_port_ok"],
        "turn_port_ok": ports["turn_port_ok"],
    }
    return payload


@app.get("/wg/transfer")
def wg_transfer(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "transfer"], timeout=8)
    data = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            try:
                data.append({
                    "public_key": parts[0],
                    "rx": int(parts[1]),
                    "tx": int(parts[2]),
                })
            except ValueError:
                continue
    return {"items": data}


@app.get("/wg/latest-handshakes")
def latest_handshakes(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "latest-handshakes"], timeout=8)
    data = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                data.append({"public_key": parts[0], "ts": int(parts[1])})
            except ValueError:
                continue
    return {"items": data}


@app.get("/wg/public-key")
def wg_public_key(x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    out = _run(["wg", "show", "wg0", "public-key"], timeout=6).strip()
    return {"public_key": out}


@app.post("/wg/peer/upsert")
async def wg_peer_upsert(payload: PeerUpsert, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    async with wg_lock:
        _run(["wg", "set", "wg0", "peer", payload.public_key, "allowed-ips", f"{payload.ip}/32"], timeout=10)
    return {"ok": True}


@app.post("/wg/peer/remove")
async def wg_peer_remove(payload: PeerRemove, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    async with wg_lock:
        _run(["wg", "set", "wg0", "peer", payload.public_key, "remove"], timeout=10)
    return {"ok": True}


@app.post("/service/restart")
def restart_service(payload: RestartReq, x_api_token: str | None = Header(default=None)):
    _check_auth(x_api_token)
    allowed = {"wg-quick@wg0", "vk-turn-proxy"}
    if payload.service not in allowed:
        raise HTTPException(status_code=400, detail="Service is not allowed")
    _run(["systemctl", "restart", payload.service], timeout=20)
    return {"ok": True, "service": payload.service}
PY

# Файл окружения для API
cat > /etc/vpn-node-api.env <<EOF
VPN_NODE_API_TOKEN=${API_TOKEN}
WG_PORT=${WG_PORT}
TURN_PORT=${TURN_PORT}
NODE_NAME=${NODE_NAME}
CMD_TIMEOUT=12
EOF
chmod 600 /etc/vpn-node-api.env

# Systemd-сервис для API
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
systemctl restart vpn-node-api

sleep 2
if ! systemctl is-active --quiet vpn-node-api; then
    echo -e "${RED}Ошибка: vpn-node-api не запустился. Проверьте journalctl -u vpn-node-api${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Сохраняем правила iptables
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[7/7] Сохранение правил iptables...${NC}"
netfilter-persistent save

# ---------------------------------------------------------------------------
# Итоговая информация
# ---------------------------------------------------------------------------
PUB_IP="$(curl -fsS ifconfig.me || echo "Не удалось определить")"

echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}✅ Установка завершена успешно!${NC}"
echo -e "Имя ноды:        ${YELLOW}${NODE_NAME}${NC}"
echo -e "Публичный IP:    ${YELLOW}${PUB_IP}${NC}"
echo -e "WG публичный ключ: ${YELLOW}${SERVER_PUBLIC}${NC}"
echo -e "SSH пароль:      ${YELLOW}${SSH_PASSWORD}${NC}"
echo -e "API URL:         ${YELLOW}http://${PUB_IP}:${API_PORT}${NC}"
echo -e "API токен:       ${YELLOW}${API_TOKEN}${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "🔐 Сохраните токен в надёжном месте!"
echo -e "Для добавления ноды в бота используйте переменные окружения:"
echo -e "  ${YELLOW}API_URL_${NODE_NAME^^}=http://${PUB_IP}:${API_PORT}${NC}"
echo -e "  ${YELLOW}API_TOKEN_${NODE_NAME^^}=${API_TOKEN}${NC}"
echo -e "  ${YELLOW}API_ONLY=1${NC}  (рекомендуется)"
echo ""
echo -e "Проверка работы API:"
echo -e "curl -H 'X-API-Token: ${API_TOKEN}' http://${PUB_IP}:${API_PORT}/health"
