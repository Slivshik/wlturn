#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "${EUID}" -ne 0 ]]; then
  echo -e "${RED}Run as root${NC}"
  exit 1
fi

echo -e "${GREEN}=== VPN Node API in-place upgrade ===${NC}"

if [[ ! -f /etc/vpn-node-api.env ]]; then
  echo -e "${RED}/etc/vpn-node-api.env not found.${NC}"
  echo "Install first with install_node_api.sh"
  exit 1
fi

# shellcheck disable=SC1091
source /etc/vpn-node-api.env

API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8787}"
NODE_NAME="${NODE_NAME:-node}"
WG_PORT="${WG_PORT:-51820}"
TURN_PORT="${TURN_PORT:-56000}"
CMD_TIMEOUT="${CMD_TIMEOUT:-12}"

read -r -p "Keep existing token? [Y/n]: " KEEP_TOKEN
KEEP_TOKEN="${KEEP_TOKEN:-Y}"
if [[ "${KEEP_TOKEN}" =~ ^[Nn]$ ]]; then
  NEW_TOKEN="$(openssl rand -hex 32)"
  sed -i "s|^VPN_NODE_API_TOKEN=.*$|VPN_NODE_API_TOKEN=${NEW_TOKEN}|" /etc/vpn-node-api.env
  echo -e "${YELLOW}New token generated.${NC}"
fi

mkdir -p /opt/vpn-node-api
cat > /opt/vpn-node-api/requirements.txt <<'REQ'
fastapi==0.115.6
uvicorn==0.32.1
REQ

python3 -m venv /opt/vpn-node-api/.venv
/opt/vpn-node-api/.venv/bin/pip install --upgrade pip >/dev/null
/opt/vpn-node-api/.venv/bin/pip install -r /opt/vpn-node-api/requirements.txt >/dev/null

cat > /opt/vpn-node-api/app.py <<'PY'
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

app = FastAPI(title="vpn-node-api", version="1.1.0")
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

if ! grep -q '^API_HOST=' /etc/vpn-node-api.env; then
  echo "API_HOST=${API_HOST}" >> /etc/vpn-node-api.env
fi
if ! grep -q '^API_PORT=' /etc/vpn-node-api.env; then
  echo "API_PORT=${API_PORT}" >> /etc/vpn-node-api.env
fi
if ! grep -q '^NODE_NAME=' /etc/vpn-node-api.env; then
  echo "NODE_NAME=${NODE_NAME}" >> /etc/vpn-node-api.env
fi
if ! grep -q '^WG_PORT=' /etc/vpn-node-api.env; then
  echo "WG_PORT=${WG_PORT}" >> /etc/vpn-node-api.env
fi
if ! grep -q '^TURN_PORT=' /etc/vpn-node-api.env; then
  echo "TURN_PORT=${TURN_PORT}" >> /etc/vpn-node-api.env
fi
if ! grep -q '^CMD_TIMEOUT=' /etc/vpn-node-api.env; then
  echo "CMD_TIMEOUT=${CMD_TIMEOUT}" >> /etc/vpn-node-api.env
fi

chmod 600 /etc/vpn-node-api.env
systemctl daemon-reload
systemctl enable vpn-node-api
systemctl restart vpn-node-api

sleep 2
if ! systemctl is-active --quiet vpn-node-api; then
  echo -e "${RED}vpn-node-api failed to start. Check: journalctl -u vpn-node-api -n 200${NC}"
  exit 1
fi

echo -e "${GREEN}✅ Upgrade complete.${NC}"
echo -e "Check: curl -H 'X-API-Token: <TOKEN>' http://127.0.0.1:${API_PORT}/health"
