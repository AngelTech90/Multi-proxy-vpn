#!/bin/bash

# Security Monitor - Detects IP leaks and auto-restarts VPN system
# Checks every 150 seconds if any proxy is leaking real IP

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VPN_DIR="/etc/protonvpn"
LOG_FILE="/var/log/protonvpn/security-monitor.log"
CHECK_INTERVAL=150
RESTART_COOLDOWN=300
LAST_RESTART_FILE="/tmp/vpn-last-restart"
VPN_SCRIPT="/usr/local/bin/multi-vpn-proxy.sh"

# Dynamic VPN discovery
declare -A VPNS

discover_vpns() {
    # Default ports if can't discover
    VPNS["usa"]=1080
    VPNS["netherlands"]=1081
    VPNS["switzerland"]=1082
    VPNS["mexico"]=1083
    VPNS["japan"]=1084
    VPNS["canada"]=1085
    
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

check_vpn_health() {
    log_msg "🔍 Starting security check cycle"
    
    local REAL_IP=$(get_real_ip)
    
    if [ -z "${REAL_IP}" ]; then
        log_msg "⚠️  WARNING: Could not determine real IP"
        return 0
    fi
    
    log_msg "🏠 Real IP: ${REAL_IP}"
    
    local LEAKS_DETECTED=0
    local FAILED_CHECKS=0
    local LEAKING_VPNS=()
    
    # Check each VPN proxy
    for VPN_NAME in "${!VPNS[@]}"; do
        local PORT=${VPNS[$VPN_NAME]}
        
        echo -n "  Checking ${VPN_NAME} (port ${PORT})... "
        
        local PROXY_IP=$(get_proxy_ip ${PORT})
        
        if [ -z "${PROXY_IP}" ]; then
            echo -e "${YELLOW}TIMEOUT${NC}"
            log_msg "⚠️  ${VPN_NAME}: Connection timeout"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        elif [ "${PROXY_IP}" == "${REAL_IP}" ]; then
            echo -e "${RED}LEAK DETECTED!${NC}"
            log_msg "🚨 SECURITY LEAK: ${VPN_NAME} exposing real IP ${REAL_IP}"
            LEAKS_DETECTED=$((LEAKS_DETECTED + 1))
            LEAKING_VPNS+=("${VPN_NAME}")
        else
            echo -e "${GREEN}OK (${PROXY_IP})${NC}"
            log_msg "✓ ${VPN_NAME}: Protected (${PROXY_IP})"
        fi
    done
    
    echo ""
    log_msg "📊 Check results: ${LEAKS_DETECTED} leaks, ${FAILED_CHECKS} timeouts"
    
    if [ ${LEAKS_DETECTED} -gt 0 ]; then
        log_msg "🚨 CRITICAL: IP LEAK DETECTED in ${LEAKING_VPNS[*]}"
        
        if check_restart_cooldown; then
            restart_vpn_system
            return 1
        else
            log_msg "⚠️  Restart skipped due to cooldown"
            return 0
        fi
    elif [ ${FAILED_CHECKS} -ge 4 ]; then
        log_msg "⚠️  WARNING: ${FAILED_CHECKS}/6 VPNs not responding"
        
        if check_restart_cooldown; then
            restart_vpn_system
            return 1
        else
            log_msg "⚠️  Restart skipped due to cooldown"
            return 0
        fi
    else
        log_msg "✅ All VPNs healthy - no leaks detected"
        return 0
    fi
}

main() {
    discover_vpns
    
    log_msg "================================================"
    log_msg "🛡️  VPN Security Monitor Started"
    log_msg "Check interval: ${CHECK_INTERVAL} seconds"
    log_msg "Restart cooldown: ${RESTART_COOLDOWN} seconds"
    log_msg "================================================"
    
    if [ "$1" != "--no-initial-delay" ]; then
        log_msg "⏳ Initial delay: waiting 60 seconds for VPNs to stabilize..."
        sleep 60
    fi
    
    while true; do
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║          VPN Security Check - $(date '+%H:%M:%S')                    ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        
        check_vpn_health
        
        echo ""
        log_msg "⏸️  Next check in ${CHECK_INTERVAL} seconds..."
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
