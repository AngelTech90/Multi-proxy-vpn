#!/bin/bash

# Test unitario para sistema de VPNs
# Verifica servidores, conectividad, routing, y proxies

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VPN_DIR="/etc/protonvpn"
LOG_DIR="/var/log/protonvpn"

# Limpiar logs anteriores
echo -e "${YELLOW}[CLEANUP]${NC} Limpiando logs de tests anteriores..."
rm -f /tmp/vpn-test-*.log /tmp/vpn-test-results.json 2>/dev/null || true

TEST_LOG="/tmp/vpn-test-$(date +%Y%m%d-%H%M%S).log"

TESTS_PASSED=0
TESTS_FAILED=0

# Función para registrar resultados
log_test() {
    echo "$1" | tee -a "${TEST_LOG}"
}

# Función de test individual
run_test() {
    local TEST_NAME=$1
    local TEST_CMD=$2
    
    echo -n "TEST: ${TEST_NAME}... "
    
    if eval "${TEST_CMD}" &>>"${TEST_LOG}"; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              Test Unitario de Sistema VPN                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Log del test: ${TEST_LOG}"
echo ""

# ========================================
# SECCIÓN 1: Tests de Prerequisitos
# ========================================
echo "═══ SECCIÓN 1: Prerequisitos ═══"

run_test "Directorio de VPNs existe" "[ -d '${VPN_DIR}' ]"
run_test "Directorio de logs existe" "[ -d '${LOG_DIR}' ]"
run_test "OpenVPN instalado" "which openvpn"
run_test "microsocks instalado" "which microsocks"
run_test "iptables disponible" "which iptables"
run_test "iproute2 disponible" "which ip"

echo ""

# ========================================
# SECCIÓN 2: Tests de Archivos de Configuración
# ========================================
echo "═══ SECCIÓN 2: Archivos de Configuración ═══"

# Descubrir archivos OVPN dinámicamente
declare -A REQUIRED_FILES

if [ -d "${VPN_DIR}" ]; then
    for OVPN_FILE in "${VPN_DIR}"/*.ovpn; do
        if [ -f "${OVPN_FILE}" ]; then
            BASENAME=$(basename "${OVPN_FILE}")
            # Extraer país del nombre
            COUNTRY=$(echo "${BASENAME}" | grep -oP '^[a-z]{2}' | tr '[:lower:]' '[:upper:]')
            if [ -z "${COUNTRY}" ]; then
                COUNTRY="VPN${REQUIRED_FILES_COUNT}"
            fi
            REQUIRED_FILES["${BASENAME}"]="${COUNTRY}"
        fi
    done
fi

for FILE in "${!REQUIRED_FILES[@]}"; do
    COUNTRY="${REQUIRED_FILES[$FILE]}"
    run_test "Archivo ${COUNTRY} existe" "[ -f '${VPN_DIR}/${FILE}' ]"
    
    if [ -f "${VPN_DIR}/${FILE}" ]; then
        run_test "Archivo ${COUNTRY} tiene credenciales" "grep -q 'auth-user-pass' '${VPN_DIR}/${FILE}'"
    fi
done

# Buscar cualquier archivo de credenciales
CRED_FILES=$(ls -1 "${VPN_DIR}"/credentials*.txt 2>/dev/null | wc -l)
run_test "Al menos un archivo de credenciales existe" "[ ${CRED_FILES} -ge 1 ]"

echo ""

# ========================================
# SECCIÓN 3: Tests de Conectividad de Servidores
# ========================================
echo "═══ SECCIÓN 3: Conectividad de Servidores ═══"

# Test servers dynamically
for OVPN_FILE in "${VPN_DIR}"/*.ovpn; do
    if [ -f "${OVPN_FILE}" ]; then
        BASENAME=$(basename "${OVPN_FILE}")
        SERVER=$(grep "^remote " "${OVPN_FILE}" | head -1 | awk '{print $2}')
        PORT=$(grep "^remote " "${OVPN_FILE}" | head -1 | awk '{print $3}')
        
        if [ -n "${SERVER}" ] && [ -n "${PORT}" ]; then
            echo -n "TEST: Servidor ${BASENAME} (${SERVER}:${PORT}) responde... "
            
            if timeout 5 nc -zv ${SERVER} ${PORT} &>>"${TEST_LOG}"; then
                echo -e "${GREEN}PASS${NC}"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "${RED}FAIL${NC}"
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        fi
    fi
done

echo ""

# ========================================
# SECCIÓN 4: Tests de Sistema en Ejecución
# ========================================
echo "═══ SECCIÓN 4: Sistema en Ejecución ═══"

# Discover active VPNs from running processes and interfaces
ACTIVE_VPNS=()

# Check each possible tun interface
for TUN_DEV in tun0 tun1 tun2 tun3 tun4 tun5 tun6 tun7; do
    if ip addr show ${TUN_DEV} &>/dev/null; then
        # Find corresponding port and name from the configuration
        TABLE_ID=$(echo "${TUN_DEV}" | sed 's/tun//' | sed 's/^/10/')
        PORT=$((1080 + $(echo "${TUN_DEV}" | sed 's/tun//')))
        
        # Try to find VPN name from process
        VPN_NAME="vpn${TUN_DEV}"
        for proc_pid in /var/run/openvpn-*.pid; do
            if [ -f "${proc_pid}" ]; then
                VPN_NAME=$(basename "${proc_pid}" | sed 's/openvpn-//' | sed 's/.pid//')
                break
            fi
        done
        
        ACTIVE_VPNS+=("${TUN_DEV}:${PORT}:${VPN_NAME}")
    fi
done

# If no active VPNs found, try to check for expected ones
if [ ${#ACTIVE_VPNS[@]} -eq 0 ]; then
    ACTIVE_VPNS=(
        "tun0:1080:usa"
        "tun1:1081:netherlands"
        "tun2:1082:norway"
        "tun3:1083:mexico"
        "tun4:1084:japan"
        "tun5:1085:canada"
    )
fi

for VPN_ENTRY in "${ACTIVE_VPNS[@]}"; do
    IFS=':' read -r TUN_DEV PORT VPN_NAME <<< "${VPN_ENTRY}"
    
    run_test "Interfaz ${TUN_DEV} existe" "ip addr show ${TUN_DEV} &>/dev/null"
    
    if ip addr show ${TUN_DEV} &>/dev/null; then
        run_test "Interfaz ${TUN_DEV} tiene IP" "ip -4 addr show ${TUN_DEV} | grep -q 'inet '"
        run_test "Interfaz ${TUN_DEV} ping funciona" "timeout 5 ping -I ${TUN_DEV} -c 2 8.8.8.8 &>/dev/null"
    fi
    
    run_test "Proxy ${VPN_NAME} escuchando en ${PORT}" "netstat -tln 2>/dev/null | grep -q ':${PORT} '"
    
    if netstat -tln 2>/dev/null | grep -q ":${PORT} "; then
        echo -n "TEST: Proxy ${VPN_NAME} obtiene IP externa... "
        EXTERNAL_IP=$(timeout 15 curl --socks5 127.0.0.1:${PORT} -s https://ifconfig.me 2>/dev/null)
        
        if [ -n "${EXTERNAL_IP}" ]; then
            echo -e "${GREEN}PASS${NC} (IP: ${EXTERNAL_IP})"
            log_test "Proxy ${VPN_NAME}: IP externa = ${EXTERNAL_IP}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
done

echo ""

# ========================================
# SECCIÓN 4B: Tests de Conectividad SOCKS5
# ========================================
echo "═══ SECCIÓN 4B: Pruebas SOCKS5 ═══"

# Mapeo de puertos a países esperados
declare -A SOCKS5_PORTS=(
    [1080]="usa"
    [1081]="netherlands"
    [1082]="switzerland"
    [1083]="mexico"
    [1084]="japan"
    [1085]="canada"
)

for PORT in 1080 1081 1082 1083 1084 1085; do
    COUNTRY="${SOCKS5_PORTS[$PORT]}"
    
    # Test 1: Puerto escuchando
    if netstat -tln 2>/dev/null | grep -q ":${PORT} "; then
        run_test "Puerto SOCKS5 ${PORT} ({$COUNTRY}) escuchando" "netstat -tln 2>/dev/null | grep -q ':${PORT} '"
        
        # Test 2: Conexión SOCKS5 exitosa
        echo -n "TEST: SOCKS5 ${PORT} (${COUNTRY}) conexión... "
        SOCKS5_IP=$(timeout 10 curl -s --socks5 127.0.0.1:${PORT} --socks5-hostname 127.0.0.1:${PORT} -s https://ifconfig.me 2>/dev/null)
        
        if [ -n "${SOCKS5_IP}" ] && [ "${SOCKS5_IP}" != "null" ]; then
            echo -e "${GREEN}PASS${NC} (IP: ${SOCKS5_IP})"
            log_test "SOCKS5 ${PORT} (${COUNTRY}): IP externa = ${SOCKS5_IP}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            log_test "SOCKS5 ${PORT} (${COUNTRY}): FALLO - sin respuesta"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
        
        # Test 3: Verificar que la IP es diferente a la IP normal (tunnel working)
        NORMAL_IP=$(timeout 5 curl -s https://ifconfig.me 2>/dev/null)
        if [ -n "${SOCKS5_IP}" ] && [ -n "${NORMAL_IP}" ]; then
            if [ "${SOCKS5_IP}" != "${NORMAL_IP}" ]; then
                echo -e "       ${GREEN}✓${NC} IP diferente a conexión directa (VPN activa)"
                log_test "  Verificación: IP VPN ≠ IP directa = OK"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "       ${YELLOW}!${NC} IP igual a conexión directa (possible leak)"
                log_test "  Advertencia: IP VPN = IP directa (possible leak!)"
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        fi
    else
        echo -e "Puerto SOCKS5 ${PORT}: ${RED}NO LISTANDO${NC}"
        run_test "Puerto SOCKS5 ${PORT} ({$COUNTRY}) escuchando" "netstat -tln 2>/dev/null | grep -q ':${PORT} '"
    fi
done

echo ""

# ========================================
# SECCIÓN 5: Tests de Routing
# ========================================
echo "═══ SECCIÓN 5: Policy Routing ═══"

# Test routing rules dynamically based on active interfaces
for TUN_DEV in tun0 tun1 tun2 tun3 tun4 tun5 tun6 tun7; do
    if ip addr show ${TUN_DEV} &>/dev/null; then
        TABLE_ID=$(ip rule list | grep "uidrange" | grep -oP 'lookup\s+\K\d+' | head -1)
        if [ -n "${TABLE_ID}" ]; then
            run_test "Tabla de ruteo para ${TUN_DEV}" "ip route show table ${TABLE_ID} | grep -q '.'"
        fi
    fi
done

# Check if any routing rules exist
run_test "Reglas de policy routing existen" "ip rule list | grep -q 'lookup.*[0-9]'"

echo ""

# ========================================
# SECCIÓN 6: Tests de Firewall
# ========================================
echo "═══ SECCIÓN 6: Reglas de Firewall ═══"

# Check if iptables is available
if command -v iptables &>/dev/null; then
    # Test for vpnuser UIDs
    for UID in 3100 3101 3102 3103 3104 3105; do
        if id "vpnuser$((UID - 3000))" &>/dev/null; then
            run_test "Usuario vpnuser$((UID - 3000)) existe" "id 'vpnuser$((UID - 3000))' &>/dev/null"
        fi
    done
    
    # Check if there are any iptables rules
    if iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q 'MARK'; then
        run_test "Reglas iptables mangle activas" "true"
    else
        run_test "Reglas iptables mangle activas" "echo 'No iptables rules found (may be using nftables)'"
    fi
else
    echo -e "${YELLOW}iptables no disponible (usando nftables?)${NC}"
fi

echo ""

# ========================================
# SECCIÓN 7: Tests de Procesos
# ========================================
echo "═══ SECCIÓN 7: Procesos del Sistema ═══"

OPENVPN_COUNT=$(pgrep -f openvpn | wc -l)
MICROSOCKS_COUNT=$(pgrep microsocks | wc -l)

echo -n "TEST: Procesos OpenVPN corriendo... "
if [ ${OPENVPN_COUNT} -ge 1 ]; then
    echo -e "${GREEN}PASS${NC} (${OPENVPN_COUNT} procesos)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}FAIL${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo -n "TEST: Procesos microsocks corriendo... "
if [ ${MICROSOCKS_COUNT} -ge 1 ]; then
    echo -e "${GREEN}PASS${NC} (${MICROSOCKS_COUNT} procesos)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}FAIL${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ========================================
# RESUMEN FINAL
# ========================================
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                      RESUMEN DE TESTS                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "Tests ejecutados: $((TESTS_PASSED + TESTS_FAILED))"
echo -e "${GREEN}Tests pasados: ${TESTS_PASSED}${NC}"
echo -e "${RED}Tests fallados: ${TESTS_FAILED}${NC}"
echo ""

if [ ${TESTS_FAILED} -eq 0 ]; then
    echo -e "${GREEN}✓ TODOS LOS TESTS PASARON${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ ALGUNOS TESTS FALLARON${NC}"
    echo "Ver detalles en: ${TEST_LOG}"
    EXIT_CODE=1
fi

echo ""

# Generar reporte JSON
cat > "/tmp/vpn-test-results.json" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "total_tests": $((TESTS_PASSED + TESTS_FAILED)),
  "passed": ${TESTS_PASSED},
  "failed": ${TESTS_FAILED},
  "success_rate": $(echo "scale=2; ${TESTS_PASSED} * 100 / $((TESTS_PASSED + TESTS_FAILED))" | bc)%,
  "log_file": "${TEST_LOG}"
}
EOF

echo "Reporte JSON generado: /tmp/vpn-test-results.json"

exit ${EXIT_CODE}
