#!/bin/bash

# Security Monitor - Detects IP leaks and proxy connectivity issues
# Checks every 45 seconds: first connectivity, then IP leaks
# Auto-restarts individual VPNs if they lose connectivity or leak IP

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VPN_DIR="/etc/protonvpn"
LOG_FILE="/var/log/protonvpn/security-monitor.log"
CHECK_INTERVAL=45
PING_TIMEOUT=12
RESTART_COOLDOWN=300
LAST_RESTART_FILE="/tmp/vpn-last-restart"
VPN_SCRIPT="/usr/local/bin/multi-vpn-proxy.sh"

# Dynamic VPN discovery
declare -A VPNS
declare -A VPN_TUN

discover_vpns() {
    # Default ports and TUN devices
    VPNS["usa"]=1080;         VPN_TUN["usa"]="tun0"
    VPNS["netherlands"]=1081; VPN_TUN["netherlands"]="tun1"
    VPNS["switzerland"]=1082; VPN_TUN["switzerland"]="tun2"
    VPNS["mexico"]=1083;      VPN_TUN["mexico"]="tun3"
    VPNS["japan"]=1084;       VPN_TUN["japan"]="tun4"
    VPNS["canada"]=1085;      VPN_TUN["canada"]="tun5"
    VPNS["us2"]=1086;         VPN_TUN["us2"]="tun6"
    VPNS["us3"]=1087;         VPN_TUN["us3"]="tun7"
    VPNS["us4"]=1088;         VPN_TUN["us4"]="tun8"
    VPNS["mx2"]=1089;         VPN_TUN["mx2"]="tun9"
    VPNS["us5"]=1090;         VPN_TUN["us5"]="tun10"
    VPNS["nl2"]=1091;         VPN_TUN["nl2"]="tun11"
    
    # Try to discover from running processes
    if [ -d "${VPN_DIR}" ]; then
        echo "Discovered VPNs from ${VPN_DIR}:"
        for ovpn in "${VPN_DIR}"/*.ovpn; do
            if [ -f "${ovpn}" ]; then
                name=$(basename "${ovpn}" | cut -d'-' -f1)
                echo "  - ${name}"
            fi
        done
    fi
}

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

get_real_ip() {
    timeout 10 curl -s https://ifconfig.me 2>/dev/null || \
    timeout 10 curl -s https://api.ipify.org 2>/dev/null || \
    timeout 10 curl -s https://icanhazip.com 2>/dev/null
}

get_proxy_ip() {
    local PORT=$1
    timeout 10 curl --socks5 127.0.0.1:${PORT} -s https://ifconfig.me 2>/dev/null || \
    timeout 10 curl --socks5 127.0.0.1:${PORT} -s https://api.ipify.org 2>/dev/null || \
    timeout 10 curl --socks5 127.0.0.1:${PORT} -s https://icanhazip.com 2>/dev/null
}

check_restart_cooldown() {
    if [ -f "${LAST_RESTART_FILE}" ]; then
        local LAST_RESTART=$(cat "${LAST_RESTART_FILE}")
        local NOW=$(date +%s)
        local ELAPSED=$((NOW - LAST_RESTART))
        
        if [ ${ELAPSED} -lt ${RESTART_COOLDOWN} ]; then
            log_msg "⚠️  COOLDOWN: Last restart was ${ELAPSED}s ago (need ${RESTART_COOLDOWN}s)"
            return 1
        fi
    fi
    return 0
}

restart_vpn_system() {
    log_msg "🔄 RESTARTING VPN SYSTEM"
    
    date +%s > "${LAST_RESTART_FILE}"
    
    # Stop all VPNs
    ${VPN_SCRIPT} stop >> "${LOG_FILE}" 2>&1 || true
    
    sleep 10
    
    # Kill any remaining processes
    pkill -9 openvpn 2>/dev/null || true
    pkill -9 microsocks 2>/dev/null || true
    
    # Clean up interfaces
    for i in {0..10}; do
        ip link set tun${i} down 2>/dev/null || true
        ip link del tun${i} 2>/dev/null || true
    done
    
    sleep 5
    
    # Start system
    ${VPN_SCRIPT} start >> "${LOG_FILE}" 2>&1 || true
    
    log_msg "✅ VPN SYSTEM RESTARTED"
    
    sleep 60
}

# Restart individual VPN in background (non-blocking)
restart_vpn_individual() {
    local VPN_NAME=$1
    local VPN_TUN_DEV=${VPN_TUN[$VPN_NAME]}
    
    log_msg "🔄 Restarting individual VPN: ${VPN_NAME} (${VPN_TUN_DEV})"
    
    # Run restart in background to not block the monitoring cycle
    (
        ${VPN_SCRIPT} spec restart ${VPN_NAME} >> "${LOG_FILE}" 2>&1
        if [ $? -eq 0 ]; then
            log_msg "✅ VPN ${VPN_NAME} restarted successfully"
        else
            log_msg "❌ Failed to restart VPN ${VPN_NAME}"
        fi
    ) &
    
    log_msg "🚀 Restart initiated for ${VPN_NAME} in background"
}

# Check connectivity for all VPNs - non-blocking restart if fails
check_connectivity() {
    log_msg "📡 Starting connectivity check (timeout: ${PING_TIMEOUT}s per VPN)"
    
    local FAILED_VPNS=0
    local CONNECTIVITY_ISSUES=()
    
    for VPN_NAME in "${!VPNS[@]}"; do
        local TUN_DEV=${VPN_TUN[$VPN_NAME]}
        local PORT=${VPNS[$VPN_NAME]}
        
        echo -n "  [CONN] ${VPN_NAME} (${TUN_DEV})... "
        
        # Check if interface exists
        if ! ip addr show "${TUN_DEV}" &>/dev/null; then
            echo -e "${RED}NO TUN${NC}"
            log_msg "⚠️  ${VPN_NAME}: Interface ${TUN_DEV} not found - restarting"
            restart_vpn_individual "${VPN_NAME}"
            FAILED_VPNS=$((FAILED_VPNS + 1))
            CONNECTIVITY_ISSUES+=("${VPN_NAME}: no tun")
            continue
        fi
        
        # Ping test through VPN tunnel (12s timeout)
        if timeout ${PING_TIMEOUT} ping -I "${TUN_DEV}" -c 2 8.8.8.8 &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
            log_msg "✓ ${VPN_NAME}: Connectivity OK"
        else
            echo -e "${RED}TIMEOUT${NC}"
            log_msg "⚠️  ${VPN_NAME}: No connectivity (${PING_TIMEOUT}s timeout) - restarting"
            restart_vpn_individual "${VPN_NAME}"
            FAILED_VPNS=$((FAILED_VPNS + 1))
            CONNECTIVITY_ISSUES+=("${VPN_NAME}: no ping")
        fi
    done
    
    echo ""
    if [ ${FAILED_VPNS} -gt 0 ]; then
        log_msg "📊 Connectivity check: ${FAILED_VPNS} VPNs failed - restarts initiated"
    else
        log_msg "📊 Connectivity check: All VPNs responding"
    fi
    
    return ${FAILED_VPNS}
}

check_vpn_health() {
    log_msg "🔍 Starting IP leak check cycle"
    
    local REAL_IP=$(get_real_ip)
    
    if [ -z "${REAL_IP}" ]; then
        log_msg "⚠️  WARNING: Could not determine real IP"
        return 0
    fi
    
    log_msg "🏠 Real IP: ${REAL_IP}"
    
    local LEAKS_DETECTED=0
    local FAILED_CHECKS=0
    
    # Check each VPN proxy - non-blocking restart if leak detected
    for VPN_NAME in "${!VPNS[@]}"; do
        local PORT=${VPNS[$VPN_NAME]}
        
        echo -n "  [LEAK] ${VPN_NAME} (port ${PORT})... "
        
        local PROXY_IP=$(get_proxy_ip ${PORT})
        
        if [ -z "${PROXY_IP}" ]; then
            echo -e "${YELLOW}TIMEOUT${NC}"
            log_msg "⚠️  ${VPN_NAME}: Connection timeout (leak check)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        elif [ "${PROXY_IP}" == "${REAL_IP}" ]; then
            echo -e "${RED}LEAK DETECTED!${NC}"
            log_msg "🚨 SECURITY LEAK: ${VPN_NAME} exposing real IP ${REAL_IP} - restarting"
            restart_vpn_individual "${VPN_NAME}"
            LEAKS_DETECTED=$((LEAKS_DETECTED + 1))
        else
            echo -e "${GREEN}OK (${PROXY_IP})${NC}"
            log_msg "✓ ${VPN_NAME}: Protected (${PROXY_IP})"
        fi
    done
    
    echo ""
    if [ ${LEAKS_DETECTED} -gt 0 ] || [ ${FAILED_CHECKS} -gt 0 ]; then
        log_msg "📊 Leak check: ${LEAKS_DETECTED} leaks, ${FAILED_CHECKS} timeouts - restarts initiated"
        return 1
    else
        log_msg "📊 Leak check: All VPNs healthy - no leaks detected"
        return 0
    fi
}

main() {
    discover_vpns
    
    log_msg "================================================"
    log_msg "🛡️  VPN Security Monitor Started"
    log_msg "Check interval: ${CHECK_INTERVAL} seconds"
    log_msg "Ping timeout: ${PING_TIMEOUT} seconds"
    log_msg "Restart cooldown: ${RESTART_COOLDOWN} seconds"
    log_msg "================================================"
    
    if [ "$1" != "--no-initial-delay" ]; then
        log_msg "⏳ Initial delay: waiting 60 seconds for VPNs to stabilize..."
        sleep 60
    fi
    
    while true; do
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║          VPN Monitor Cycle - $(date '+%H:%M:%S')                    ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        
        # Step 1: Check connectivity (ping test through tunnel)
        echo "━━━ Step 1: Connectivity Check ━━━"
        check_connectivity
        
        echo ""
        
        # Step 2: Check IP leaks
        echo "━━━ Step 2: IP Leak Detection ━━━"
        check_vpn_health
        
        echo ""
        log_msg "⏸️  Next full check in ${CHECK_INTERVAL} seconds..."
        sleep ${CHECK_INTERVAL}
    done
}

trap 'log_msg "🛑 Security Monitor stopped"; exit 0' SIGTERM SIGINT

case "$1" in
    --once)
        discover_vpns
        log_msg "Running single security check"
        get_real_ip > /dev/null
        check_vpn_health
        ;;
    --daemon)
        main --no-initial-delay >> "${LOG_FILE}" 2>&1 &
        echo $! > /var/run/vpn-security-monitor.pid
        echo "Security monitor started as daemon (PID: $!)"
        ;;
    *)
        main
        ;;
esac
