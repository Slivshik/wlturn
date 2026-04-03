#!/bin/bash
# Добавление ноды в базу данных бота

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ $# -lt 4 ]; then
    echo -e "${RED}Использование:${NC}"
    echo "  $0 <имя_ноды> <ip> <ssh_user> <ssh_pass> [maint]"
    echo "Пример:"
    echo "  $0 SE-1 95.216.xxx.xxx root mypassword 0"
    exit 1
fi

NODE_NAME=$1
IP=$2
SSH_USER=$3
SSH_PASS=$4
MAINT=${5:-0}

# Проверка, существует ли база данных
if [ ! -f /root/vpn_bot.db ]; then
    echo -e "${RED}База данных бота не найдена! Убедитесь, что бот установлен.${NC}"
    exit 1
fi

sqlite3 /root/vpn_bot.db "INSERT OR REPLACE INTO servers (name, ip, ssh_user, ssh_pass, maint) VALUES ('$NODE_NAME', '$IP', '$SSH_USER', '$SSH_PASS', $MAINT);"
echo -e "${GREEN}✅ Нода $NODE_NAME добавлена в БД бота${NC}"

# Опционально: обновить hardcoded ключи в коде бота
read -p "Обновить публичный ключ в коде бота? (y/n): " UPDATE_KEY
if [[ "$UPDATE_KEY" == "y" ]]; then
    echo "Получаем публичный ключ с сервера..."
    if command -v sshpass &> /dev/null; then
        PUB_KEY=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$IP" "cat /etc/wireguard/server_public" 2>/dev/null)
        if [ -n "$PUB_KEY" ]; then
            sed -i "/hardcoded_keys = {/a \        \"$NODE_NAME\": \"$PUB_KEY\"," /root/vpn_bot.py
            echo -e "${GREEN}✅ Публичный ключ добавлен в код бота${NC}"
            systemctl restart vpnbot
        else
            echo -e "${RED}Не удалось получить ключ. Добавьте вручную.${NC}"
        fi
    else
        echo -e "${RED}Установите sshpass: apt install sshpass${NC}"
    fi
fi
