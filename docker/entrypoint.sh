#!/bin/sh
set -e

# ── Paths ──────────────────────────────────────────────────────────────────────
VPN_DIR="/vpn/ovpn"
OVPN_SRC="${VPN_DIR}/${OVPN_FILE}"
CREDS_SRC="${VPN_DIR}/${CREDS_FILE}"
OVPN_TMP="/tmp/vpn.ovpn"
VPN_LOG="/var/log/vpn.log"

# ── Validation ─────────────────────────────────────────────────────────────────
if [ -z "${OVPN_FILE}" ]; then
    echo "[ERROR] OVPN_FILE env var is not set" >&2
    exit 1
fi

if [ ! -f "${OVPN_SRC}" ]; then
    echo "[ERROR] OVPN config not found: ${OVPN_SRC}" >&2
    exit 1
fi

if [ -z "${CREDS_FILE}" ]; then
    echo "[ERROR] CREDS_FILE env var is not set" >&2
    exit 1
fi

if [ ! -f "${CREDS_SRC}" ]; then
    echo "[ERROR] Credentials file not found: ${CREDS_SRC}" >&2
    exit 1
fi

echo "[INFO] VPN_NAME   : ${VPN_NAME}"
echo "[INFO] OVPN_FILE  : ${OVPN_FILE}"
echo "[INFO] CREDS_FILE : ${CREDS_FILE}"
echo "[INFO] PROXY_PORT : ${PROXY_PORT}"

# ── Kill switch (applied BEFORE VPN connects) ──────────────────────────────────
echo "[INFO] Applying iptables kill switch..."

# Flush existing rules
iptables -F
iptables -X
iptables -Z

# Default policies: drop everything outbound, drop forward
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Allow loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related (responses to our allowed traffic)
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow OpenVPN UDP outbound — ProtonVPN uses 1194 and 443
iptables -A OUTPUT -p udp --dport 1194 -j ACCEPT
iptables -A OUTPUT -p udp --dport 443  -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443  -j ACCEPT

# Allow all traffic through tun0 once it comes up
iptables -A INPUT  -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

# Block IPv6 entirely — leak prevention
ip6tables -P INPUT   DROP
ip6tables -P OUTPUT  DROP
ip6tables -P FORWARD DROP

echo "[INFO] Kill switch active — all non-VPN traffic blocked"

# ── Prepare OpenVPN config ─────────────────────────────────────────────────────
echo "[INFO] Preparing VPN config..."

cp "${OVPN_SRC}" "${OVPN_TMP}"

# Remove any existing dev directive and pin to tun0
sed -i '/^dev /d' "${OVPN_TMP}"
echo "dev tun0" >> "${OVPN_TMP}"

# Prevent container from pulling routes into the host netns
echo "route-nopull" >> "${OVPN_TMP}"

# No DNS hijacking inside container
echo 'pull-filter ignore "dhcp-option DNS"' >> "${OVPN_TMP}"

# Allow openvpn to run external scripts if needed
echo "script-security 2" >> "${OVPN_TMP}"

echo "[INFO] VPN config written to ${OVPN_TMP}"

# ── Start OpenVPN ──────────────────────────────────────────────────────────────
echo "[INFO] Starting OpenVPN (daemon)..."

openvpn \
    --config "${OVPN_TMP}" \
    --log    "${VPN_LOG}"  \
    --verb   4             \
    --daemon

# ── Wait for tun0 ─────────────────────────────────────────────────────────────
echo "[INFO] Waiting for tun0 interface (timeout: 60s)..."

ELAPSED=0
until ip addr show tun0 > /dev/null 2>&1; do
    if [ "${ELAPSED}" -ge 60 ]; then
        echo "[ERROR] tun0 did not appear after 60s. Last VPN log:" >&2
        tail -n 30 "${VPN_LOG}" >&2
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "[INFO] tun0 is up after ${ELAPSED}s"
ip addr show tun0

# ── Signal handling ────────────────────────────────────────────────────────────
cleanup() {
    echo "[INFO] Signal received — shutting down..."

    VPN_PID="$(pgrep openvpn || true)"
    if [ -n "${VPN_PID}" ]; then
        echo "[INFO] Sending SIGTERM to openvpn (pid ${VPN_PID})..."
        kill -TERM "${VPN_PID}" 2>/dev/null || true

        WAIT=0
        while kill -0 "${VPN_PID}" 2>/dev/null && [ "${WAIT}" -lt 5 ]; do
            sleep 1
            WAIT=$((WAIT + 1))
        done

        if kill -0 "${VPN_PID}" 2>/dev/null; then
            echo "[WARN] openvpn did not exit — sending SIGKILL..."
            kill -KILL "${VPN_PID}" 2>/dev/null || true
        fi
    fi

    echo "[INFO] Shutdown complete"
    exit 0
}

trap cleanup TERM INT

# ── Start microsocks (background) + watchdog loop as PID 1 ────────────────────
echo "[INFO] Starting microsocks on 0.0.0.0:${PROXY_PORT}..."
microsocks -i 0.0.0.0 -p "${PROXY_PORT}" &
SOCKS_PID=$!

# Wait — keeps PID 1 alive and responsive to signals
wait $SOCKS_PID
