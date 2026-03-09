#!/bin/bash

# Control script for VPN Security Monitor

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PID_FILE="/var/run/vpn-security-monitor.pid"
LOG_FILE="/var/log/protonvpn/security-monitor.log"
VPN_SCRIPT="/usr/local/bin/multi-vpn-proxy.sh"
MONITOR_SCRIPT="/usr/local/bin/vpn-security-monitor.sh"

status() {
    if [ -f "${PID_FILE}" ]; then
        PID=$(cat "${PID_FILE}")
        if ps -p ${PID} > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} Security monitor is running (PID: ${PID})"
            echo ""
            echo "Last security check:"
            tail -15 "${LOG_FILE}" 2>/dev/null | grep -E "(Real IP|Protected|LEAK|check results)" || tail -5 "${LOG_FILE}"
            return 0
        else
            echo -e "${RED}✗${NC} PID file exists but process not running"
            rm -f "${PID_FILE}"
            return 1
        fi
    else
        echo -e "${RED}✗${NC} Security monitor is not running"
        return 1
    fi
}

start() {
    if status > /dev/null 2>&1; then
        echo "Security monitor already running"
        return 1
    fi
    
    echo "Starting security monitor..."
    ${MONITOR_SCRIPT} --daemon
    sleep 2
    status
}

stop() {
    if [ -f "${PID_FILE}" ]; then
        PID=$(cat "${PID_FILE}")
        echo "Stopping security monitor (PID: ${PID})..."
        kill ${PID} 2>/dev/null || true
        rm -f "${PID_FILE}"
        sleep 2
        echo "Stopped"
    else
        echo "Security monitor not running"
    fi
}

restart() {
    stop
    sleep 2
    start
}

logs() {
    if [ -f "${LOG_FILE}" ]; then
        tail -f "${LOG_FILE}"
    else
        echo "No log file found: ${LOG_FILE}"
    fi
}

check_now() {
    echo "Running immediate security check..."
    ${MONITOR_SCRIPT} --once
}

stats() {
    if [ -f "${LOG_FILE}" ]; then
        echo "=== Security Monitor Statistics ==="
        echo ""
        echo "Total checks:"
        grep -c "Starting security check" "${LOG_FILE}" 2>/dev/null || echo "0"
        echo ""
        echo "Leaks detected:"
        grep -c "SECURITY LEAK" "${LOG_FILE}" 2>/dev/null || echo "0"
        echo ""
        echo "Restarts:"
        grep -c "RESTARTING VPN SYSTEM" "${LOG_FILE}" 2>/dev/null || echo "0"
        echo ""
        echo "Last 10 events:"
        tail -10 "${LOG_FILE}"
    else
        echo "No log file found"
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs
        ;;
    check)
        check_now
        ;;
    stats)
        stats
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|check|stats}"
        echo ""
        echo "Commands:"
        echo "  start   - Start security monitor daemon"
        echo "  stop    - Stop security monitor daemon"
        echo "  restart - Restart security monitor"
        echo "  status  - Show monitor status and last check"
        echo "  logs    - Follow security monitor logs"
        echo "  check   - Run immediate security check"
        echo "  stats   - Show statistics"
        exit 1
        ;;
esac
