#!/bin/bash
# Full reset + build + test cycle for Docker VPN implementation
# Usage: ./docker-test.sh

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker/docker-compose.yml"

echo "=== 1. STOP OLD CONTAINERS ==="
sudo docker-compose --file "${COMPOSE_FILE}" down 2>/dev/null || true
sudo docker rm -f $(sudo docker ps -aq --filter "name=vpn-" 2>/dev/null) 2>/dev/null || true

echo "=== 2. BUILD IMAGE ==="
sudo docker build -t multi-vpn-proxy:latest "${PROJECT_DIR}/docker"

echo "=== 3. START CONTAINERS ==="
sudo docker-compose --file "${COMPOSE_FILE}" up -d

echo "=== 4. WAIT 65s FOR OPENVPN ==="
sleep 65

echo "=== 5. STATUS ==="
sudo docker-compose --file "${COMPOSE_FILE}" ps

echo ""
echo "=== 6. PORT TESTS ==="
PASS=0
FAIL=0

for port in 1080 1081 1082 1083 1084 1085 1086 1087 1088 1089 1090 1091; do
    printf "Port %d: " ${port}
    IP=$(timeout 15 curl --socks5 127.0.0.1:${port} -s https://ifconfig.me 2>/dev/null) || true
    if [ -n "${IP}" ]; then
        echo -e "\033[0;32mOK\033[0m — ${IP}"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "═══════════════════════════════════════"
echo -e "Results: \033[0;32m${PASS} OK\033[0m / \033[0;31m${FAIL} FAIL\033[0m"
echo "═══════════════════════════════════════"

# Detailed FAIL check — get logs for all failed ports
if [ ${FAIL} -gt 0 ]; then
    echo ""
    echo "=== FAILED PORT LOGS ==="
    for port in 1080 1081 1082 1083 1084 1085 1086 1087 1088 1089 1090 1091; do
        IP=$(timeout 5 curl --socks5 127.0.0.1:${port} -s https://ifconfig.me 2>/dev/null) || true
        if [ -z "${IP}" ]; then
            # Find container name for this port
            NAME=$(sudo docker-compose --file "${COMPOSE_FILE}" ps --format '{{.Names}}' 2>/dev/null | grep -E ":${port}->" | head -1)
            if [ -n "${NAME}" ]; then
                echo "--- ${NAME} ---"
                sudo docker logs --tail 10 "${NAME}" 2>&1 | grep -E "Error|ERROR|fail|FAIL|denied|DENIED|not permitted" || echo "(no errors in log)"
            fi
        fi
    done
fi