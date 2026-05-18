#!/bin/bash
set -e
VPN_DIR="/tmp/ovpn_test"
OVPN_DIR="$(pwd)/ovpn"
mkdir -p "${VPN_DIR}"
cp "${OVPN_DIR}"/*.ovpn "${VPN_DIR}/"
OVPN_FILES=($(ls -1 "${VPN_DIR}"/*.ovpn))
echo "Files found: ${#OVPN_FILES[@]}"
