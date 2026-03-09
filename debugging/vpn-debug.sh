#!/bin/bash

# Debugging script - Lee logs del sistema VPN
# Ubicación: ./debugging/vpn-debug.sh

LOG_DIR="/var/log/protonvpn"
RUN_DIR="/var/run"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  VPN Debug - Analizador de Logs y Estado del Sistema           ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Función para mostrar logs de una VPN específica
show_vpn_logs() {
    local VPN_NAME=$1
    local LOG_FILE="${LOG_DIR}/${VPN_NAME}-openvpn.log"
    
    if [ -f "${LOG_FILE}" ]; then
        echo -e "${YELLOW}[${VPN_NAME}]${NC} - Últimas 30 líneas del log:"
        echo "─────────────────────────────────────────────────"
        tail -30 "${LOG_FILE}"
        echo "─────────────────────────────────────────────────"
    else
        echo -e "${RED}[${VPN_NAME}]${NC} - Log no encontrado: ${LOG_FILE}"
    fi
}

# Función para mostrar status de una VPN
show_vpn_status() {
    local VPN_NAME=$1
    local PID_FILE="${RUN_DIR}/openvpn-${VPN_NAME}.pid"
    local PROXY_PID="${RUN_DIR}/microsocks-${VPN_NAME}.pid"
    
    echo -e "${YELLOW}[${VPN_NAME}]${NC}"
    
    if [ -f "${PID_FILE}" ]; then
        local PID=$(cat "${PID_FILE}")
        if ps -p "${PID}" > /dev/null 2>&1; then
            echo -e "  OpenVPN: ${GREEN}✓ Corriendo${NC} (PID: ${PID})"
        else
            echo -e "  OpenVPN: ${RED}✗ Muerto (stale PID)${NC}"
        fi
    else
        echo -e "  OpenVPN: ${RED}✗ No iniciado${NC}"
    fi
    
    if [ -f "${PROXY_PID}" ]; then
        local PROXY_PID_VAL=$(cat "${PROXY_PID}")
        if ps -p "${PROXY_PID_VAL}" > /dev/null 2>&1; then
            echo -e "  Microsocks: ${GREEN}✓ Corriendo${NC} (PID: ${PROXY_PID_VAL})"
        else
            echo -e "  Microsocks: ${RED}✗ Muerto (stale PID)${NC}"
        fi
    else
        echo -e "  Microsocks: ${RED}✗ No iniciado${NC}"
    fi
}

# Menú principal
case "${1}" in
    logs)
        if [ -n "${2}" ]; then
            show_vpn_logs "${2}"
        else
            echo "Mostrando logs de todas las VPNs..."
            for log in "${LOG_DIR}"/*-openvpn.log; do
                if [ -f "${log}" ]; then
                    VPN_NAME=$(basename "${log}" | sed 's/-openvpn.log//')
                    show_vpn_logs "${VPN_NAME}"
                    echo ""
                fi
            done
        fi
        ;;
        
    status)
        echo "Estado de todas las VPNs:"
        echo ""
        
        # Buscar VPNs activas basándose en archivos PID
        for pid_file in "${RUN_DIR}"/openvpn-*.pid; do
            if [ -f "${pid_file}" ]; then
                VPN_NAME=$(basename "${pid_file}" | sed 's/openvpn-//' | sed 's/.pid//')
                show_vpn_status "${VPN_NAME}"
                echo ""
            fi
        done
        
        if [ ! -f "${RUN_DIR}"/openvpn-*.pid 2>/dev/null ]; then
            echo -e "${RED}No hay VPNs activas${NC}"
        fi
        ;;
        
    network)
        echo "Configuración de red:"
        echo ""
        echo "Interfaces tun activas:"
        ip addr show | grep -E '^([0-9]+: tun)' | sed 's/:/ - /'
        echo ""
        echo "Tablas de routing VPN:"
        ip rule list | grep -E '(lookup|fwmark|uidrange)' | grep -v 'local'
        ;;
        
    test)
        echo "Probando conectividad de cada VPN..."
        echo ""
        
        # Puerto base para VPNs
        declare -A VPN_PORTS=(
            ["usa"]=1080
            ["netherlands"]=1081
            ["norway"]=1082
            ["mexico"]=1083
            ["japan"]=1084
            ["canada"]=1085
        )
        
        for VPN in usa netherlands norway mexico japan canada; do
            PORT=${VPN_PORTS[$VPN]}
            echo -n "Testing ${VPN} (puerto ${PORT})... "
            
            if timeout 5 curl -s --socks5 127.0.0.1:${PORT} -s https://ifconfig.me > /dev/null 2>&1; then
                IP=$(timeout 5 curl -s --socks5 127.0.0.1:${PORT} -s https://ifconfig.me)
                echo -e "${GREEN}✓${NC} IP: ${IP}"
            else
                echo -e "${RED}✗${NC}"
            fi
        done
        ;;
        
    all)
        echo "=== ANÁLISIS COMPLETO ==="
        echo ""
        $0 status
        echo ""
        $0 network
        echo ""
        $0 test
        ;;
        
    *)
        echo "Uso: $0 {logs|status|network|test|all} [vpn_name]"
        echo ""
        echo "Comandos:"
        echo "  logs [vpn]   - Mostrar logs (de todas o una específica)"
        echo "  status       - Mostrar estado de procesos"
        echo "  network      - Mostrar configuración de red"
        echo "  test         - Probar conectividad de proxies"
        echo "  all          - Análisis completo"
        exit 1
        ;;
esac
