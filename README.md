# VPN Multi-Proxy System v1.0

Portable VPN system with automatic security monitoring and multiple SOCKS5 proxies.

## Project Structure

```
VPN-Setup/
├── ovpn/                  # Put your .ovpn and credentials*.txt files here
│   ├── *.ovpn           # ProtonVPN configuration files
│   ├── credentials.txt   # Account 1 (for 2 VPNs)
│   ├── credentials-2.txt # Account 2 (for 2 VPNs)
│   └── credentials-3.txt # Account 3 (for 2 VPNs)
├── config/               # Future config files
├── testing/             # Unit tests
├── debugging/            # Debug scripts
├── deployment/            # Security monitor scripts
├── multi-vpn-proxy.sh   # Main VPN proxy script
└── setup.sh             # Installation script
```

## Quick Start

1. **Prepare files:**
```bash
# Add your ProtonVPN credentials to ovpn/ directory
# Each credentials file = 2 VPN connections (ProtonVPN limit)
cp ~/Downloads/*.ovpn ovpn/
echo "your_username" > ovpn/credentials.txt
echo "your_password" >> ovpn/credentials.txt
```

2. **Run setup:**
```bash
cd VPN-Setup
sudo ./setup.sh full
```

3. **Start system:**
```bash
sudo /usr/local/bin/multi-vpn-proxy.sh start
```

## Adding New VPNs

Simply add more files to the `ovpn/` directory:

```bash
# Add more .ovpn files
cp ~/Downloads/*.ovpn ovpn/

# Add more credentials (if needed)
cp your_credentials ovpn/credentials-4.txt

# Re-run setup
sudo ./setup.sh full
```

The system automatically:
- Discovers all .ovpn files
- Assigns credentials by pairs (every 2 VPNs = 1 credentials file)
- Creates users and routing tables

## Commands

```bash
# Main system
sudo /usr/local/bin/multi-vpn-proxy.sh start    # Start all VPNs
sudo /usr/local/bin/multi-vpn-proxy.sh stop     # Stop all VPNs
sudo /usr/local/bin/multi-vpn-proxy.sh status   # Check status
sudo /usr/local/bin/multi-vpn-proxy.sh test     # Test connections

# Debugging
sudo /usr/local/bin/vpn-debug.sh status         # Debug status
sudo /usr/local/bin/vpn-debug.sh test           # Test proxies

# Security monitor
sudo /usr/local/bin/vpn-monitor-control.sh status   # Monitor status
sudo /usr/local/bin/vpn-security-monitor.sh start    # Start monitor

# Run tests
sudo /usr/local/bin/vpn-unit-test.sh
```

## How It Works

Each VPN gets:
- Unique port (1080, 1081, 1082, etc.)
- Unique routing table (100, 101, 102, etc.)
- Unique tun device (tun0, tun1, tun2, etc.)
- Unique user (vpnuser100, vpnuser101, etc.)

Traffic is routed through policy routing:
- Each proxy user (vpnuserXXX) has its own routing table
- Traffic from each SOCKS5 proxy goes through its own VPN

## Features

- ✅ Auto-discovery of VPN configurations
- ✅ Dynamic port and routing assignment
- ✅ Automatic credentials integration
- ✅ Security monitoring
- ✅ Multiple account support (2 connections per account)
- ✅ Portable across Linux distributions
- ✅ SOCKS5 proxy for each VPN

## Testing

```bash
# Test all proxies
for p in 1080 1081 1082 1083 1084 1085; do
    echo -n "Puerto $p: "
    curl -s --socks5 127.0.0.1:$p https://ifconfig.me
done
```

## Troubleshooting

If VPNs don't connect properly:
```bash
# Check routing rules
ip rule list | grep uidrange

# Check interfaces
ip addr show | grep tun

# Restart with clean state
sudo /usr/local/bin/multi-vpn-proxy.sh restart
```

## Credits

Based on ProtonVPN and OpenVPN.
