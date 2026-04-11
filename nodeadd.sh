#!/usr/bin/env bash
set -euo pipefail

# Universal node add/update script for vpn_bot.db.
# Works for any node name/country (RU/SE/DE/US/etc).

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DB_PATH="${DB_PATH:-/root/vpn_bot.db}"

usage() {
  echo -e "${RED}Usage:${NC}"
  echo "  $0 <name> <ip> <ssh_user> <ssh_pass> [maint] [api_url] [api_token] [api_enabled]"
  echo
  echo "Examples:"
  echo "  $0 SE-1 95.217.10.10 root pass123 0"
  echo "  $0 SE-1 95.217.10.10 root pass123 0 http://95.217.10.10:8787 token123 1"
  echo
  echo "Notes:"
  echo "  - maint: 0 or 1 (default 0)"
  echo "  - api_enabled: 0 or 1 (default auto: 1 if api_url+api_token set)"
}

if [[ $# -lt 4 ]]; then
  usage
  exit 1
fi

NODE_NAME="$1"
IP="$2"
SSH_USER="$3"
SSH_PASS="$4"
MAINT="${5:-0}"
API_URL="${6:-}"
API_TOKEN="${7:-}"
API_ENABLED="${8:-}"

if [[ -z "${API_ENABLED}" ]]; then
  if [[ -n "${API_URL}" && -n "${API_TOKEN}" ]]; then
    API_ENABLED=1
  else
    API_ENABLED=0
  fi
fi

if [[ ! -f "${DB_PATH}" ]]; then
  echo -e "${RED}Database not found: ${DB_PATH}${NC}"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo -e "${RED}sqlite3 is required${NC}"
  exit 1
fi

# Migrate servers table if needed (ignore duplicate-column errors).
sqlite3 "${DB_PATH}" "ALTER TABLE servers ADD COLUMN api_url TEXT;" || true
sqlite3 "${DB_PATH}" "ALTER TABLE servers ADD COLUMN api_token TEXT;" || true
sqlite3 "${DB_PATH}" "ALTER TABLE servers ADD COLUMN api_enabled INTEGER DEFAULT 0;" || true

sqlite3 "${DB_PATH}" \
  "INSERT OR REPLACE INTO servers (name, ip, ssh_user, ssh_pass, api_url, api_token, api_enabled, maint)
   VALUES ('$NODE_NAME', '$IP', '$SSH_USER', '$SSH_PASS', '$API_URL', '$API_TOKEN', $API_ENABLED, $MAINT);"

echo -e "${GREEN}✅ Node saved:${NC} ${YELLOW}${NODE_NAME}${NC}"
echo "IP: ${IP}"
echo "SSH: ${SSH_USER}"
echo "Maint: ${MAINT}"
echo "API URL: ${API_URL:-<empty>}"
echo "API enabled: ${API_ENABLED}"

echo
echo -e "${YELLOW}Current row:${NC}"
sqlite3 -header -column "${DB_PATH}" \
  "SELECT name, ip, ssh_user, maint, api_url, api_enabled FROM servers WHERE name='${NODE_NAME}';"
