# PRD — Multi-Proxy VPN System
**Version:** 1.0  
**Date:** 2026-05-22  
**Status:** Draft — Architectural Review  

---

## 1. Executive Summary

This document describes the full context, architecture, known failure modes, and research roadmap for a **local multi-proxy VPN system** built on top of OpenVPN + microsocks. The system's goal is to expose multiple **SOCKS5 proxy ports on localhost** (1080–1091), each tunneled through a different VPN exit node (ProtonVPN free tier), enabling IP rotation for outgoing traffic without affecting the host machine's own internet connection.

The system currently works, but fails eventually — and in the worst cases, **destroys the OS network stack entirely**, requiring a full reboot. This PRD documents why that happens and what needs to change to either fix it or replace it with a more solid alternative built on the same fundamentals.

---

## 2. Project Goals

| Goal | Description |
|------|-------------|
| **G1 — Local proxy ports** | Expose SOCKS5 proxies on `127.0.0.1:1080` through `127.0.0.1:1091` |
| **G2 — IP isolation** | Each proxy must exit through a different VPN IP (different country/node) |
| **G3 — Host transparency** | The host machine's default internet must NEVER be affected by the VPN tunnels |
| **G4 — Free & accessible** | No paid services beyond a free ProtonVPN account. All tooling is OSS |
| **G5 — Self-healing** | The system should detect failed tunnels and restart them autonomously |
| **G6 — Account rotation support** | The proxy pool must be usable by external tools for distributing traffic across multiple identities |

---

## 3. Current Architecture

### 3.1 Component Map

```
[Host Machine]
│
├── multi-vpn-proxy.sh          # Orchestrator — starts/stops everything
│   ├── discover_vpn_servers()  # Detects available .ovpn files
│   ├── setup_vpn_proxy()       # Launches one OpenVPN + microsocks pair
│   ├── configure_routing_v3()  # Sets up policy routing per VPN
│   └── cleanup_vpn()           # Tears down one VPN cleanly
│
├── setup.sh                    # Installer — copies files, creates users, deps
│
├── deployment/
│   ├── vpn-security-monitor.sh # Daemon — checks connectivity + IP leaks every 45s
│   └── vpn-monitor-control.sh  # CLI wrapper for the monitor daemon
│
├── debugging/
│   └── vpn-debug.sh            # Manual inspection of logs, routes, pids
│
└── ovpn/                       # Source .ovpn files + credentials
    ├── *.protonvpn.udp.ovpn    # 12 VPN configs (USA, NL, CH, MX, JP, CA + variants)
    └── credentials*.txt        # ProtonVPN credentials (6 pairs of accounts)
```

### 3.2 Traffic Flow (When Working Correctly)

```
[App / Script]
    │
    │  connects to SOCKS5 127.0.0.1:1080
    ▼
[microsocks — running as vpnuser100 (UID 3100)]
    │
    │  traffic originates from UID 3100
    ▼
[iptables mangle OUTPUT]
    │  MARK packet with fwmark=100
    ▼
[ip rule: uidrange 3100-3100 → lookup table 100]
[ip rule: fwmark 100 → lookup table 100]
    │
    ▼
[ip route table 100]
    │  default via <VPN_GW> dev tun0
    ▼
[OpenVPN tun0] → [ProtonVPN Server USA] → [Internet]
```

### 3.3 Policy Routing Tables

| Table ID | Name        | Port | TUN  | UID  |
|----------|-------------|------|------|------|
| 100      | usa         | 1080 | tun0 | 3100 |
| 101      | netherlands | 1081 | tun1 | 3101 |
| 102      | switzerland | 1082 | tun2 | 3102 |
| 103      | mexico      | 1083 | tun3 | 3103 |
| 104      | japan       | 1084 | tun4 | 3104 |
| 105      | canada      | 1085 | tun5 | 3105 |
| 106      | us2         | 1086 | tun6 | 3106 |
| 107      | us3         | 1087 | tun7 | 3107 |
| 108      | us4         | 1088 | tun8 | 3108 |
| 109      | mx2         | 1089 | tun9 | 3109 |
| 110      | us5         | 1090 | tun10| 3110 |
| 111      | nl2         | 1091 | tun11| 3111 |

---

## 4. Architectural Problems — Deep Analysis

### 4.1 CRITICAL — `iptables -t mangle -F OUTPUT` (Nuclear Option)

**Location:** `multi-vpn-proxy.sh` → `start` block (was line 488, now commented out after fix)  
**Location 2:** `setup.sh` → `cleanup_system()` (was line 174, now fixed)

**What it does:** `-F` (Flush) wipes the **entire `OUTPUT` chain** of the `mangle` table.

**Why it breaks everything:**  
The `mangle OUTPUT` chain is not exclusive to this project. Docker, libvirt/KVM, systemd-networkd, WireGuard, and other system daemons write their own packet marks here to route their traffic correctly. When you flush this chain:

1. Docker containers lose their NAT rules — internal traffic can't reach the host
2. Other VPN software (if any) loses its marks
3. The OS itself can have systemd-resolved or NetworkManager marks wiped

**The insidious part:** These other services don't re-apply their rules automatically. They assume their rules are permanent. So after a flush, those services keep running but their traffic goes nowhere, causing a "the network is up but nothing works" scenario. This is why a **reboot fixes it** — systemd re-initializes everything from scratch on boot.

**Fix applied:** Replaced `-F OUTPUT` with surgical per-UID rule deletion:
```bash
iptables -t mangle -D OUTPUT -m owner --uid-owner ${PROXY_UID} -j MARK --set-mark ${ROUTE_TABLE}
```

---

### 4.2 CRITICAL — OpenVPN DNS Hijacking

**Location:** `setup_vpn_proxy()` — the `.ovpn` file preparation block

**What it does:** ProtonVPN's `.ovpn` configs include `dhcp-option DNS` push directives. When OpenVPN connects, it calls its `--up` script (or the system's resolvconf/systemd-resolved hook) and **rewrites `/etc/resolv.conf`** to point at ProtonVPN's DNS servers.

**Why it breaks everything:**  
With 12 simultaneous VPN connections, each one tries to claim DNS ownership. The last one to connect "wins" and writes its DNS to `/etc/resolv.conf`. When any VPN disconnects (gracefully or not), the DNS entry it wrote is now pointing at a dead server. The OS can't resolve any domain name. This manifests as "I have no internet" when the actual network layer is fine.

**Proof:** After a VPN crash, run `cat /etc/resolv.conf`. You'll see ProtonVPN DNS IPs (like `10.8.0.1`) that are no longer reachable.

**Fix applied:** Added `route-nopull` and `pull-filter ignore "dhcp-option DNS"` to the temp `.ovpn` file:
```bash
echo "route-nopull" >> "${TEMP_OVPN}"
echo "pull-filter ignore \"dhcp-option DNS\"" >> "${TEMP_OVPN}"
```

`route-nopull` is the key directive — it tells OpenVPN to **ignore all server-pushed routes and DHCP options**, leaving the host routing table completely untouched. The script then manually sets up exactly the routes it needs via `configure_routing_v3()`.

---

### 4.3 HIGH — Route Leak into the `main` Table

**Location:** `configure_routing_v3()` and OpenVPN's own route injection

**What it does:** Even with `pull-filter ignore "redirect-gateway"` (the original approach), ProtonVPN still pushes **specific host routes** (like the route to its own gateway, e.g., `185.x.x.x/32 via <gateway>`). These go into the **main routing table**, not the VPN-specific one.

**Why it breaks the connection:**  
After running 12 VPNs, your main table accumulates dozens of zombie routes. When VPNs restart or fail, the gateways those routes point to no longer exist. The kernel tries to use those routes for legitimate traffic and drops packets. This is a **slow degradation** — the system works at first and gets progressively worse.

**Root cause:** The previous partial fix (`pull-filter ignore "redirect-gateway"`) only ignores the default route push, not the specific gateway routes.

**Fix:** `route-nopull` eliminates ALL server-pushed routes, preventing any contamination of the main table. The `configure_routing_v3()` function then adds only what's needed to the VPN-specific table.

---

### 4.4 HIGH — `set -e` + Cleanup Sequence = Self-Destruction

**Location:** `setup.sh` → `full` command flow

**What happens:**
1. `full` runs `cleanup_system()` — kills all VPNs, wipes `/usr/local/bin/ovpn/`
2. This temporarily disrupts DNS/network (see 4.2)
3. `install_dependencies()` runs `apt-get update`
4. `apt-get update` fails because network is momentarily broken
5. `set -e` kills the script instantly
6. `integrate_credentials()` never runs — files never get copied back
7. `/usr/local/bin/ovpn/` stays empty
8. `multi-vpn-proxy.sh` discovers 0 VPNs

**Fix applied:** Made `apt-get` non-fatal with `|| log_warn "..."` so the script continues even if the package manager has a hiccup.

---

### 4.5 MEDIUM — Cleanup Range Desync

**Location:** `setup.sh` → `cleanup_system()` and `setup_directories()`

**Original code:** Loops from 100 to 105. Project has 12 VPNs (100–111).

**Impact:** Running `setup.sh full` leaves zombie `vpnuser` accounts (106–111), orphaned `iptables` marks, and stale `ip rule` entries for the extra VPN slots. These accumulate across multiple installs and can cause UID conflicts on reinstall.

**Fix applied:** Extended all loops to `seq 100 111` and corrected the UID arithmetic (`$((3000 + i))` instead of the broken `${i}300` pattern).

---

### 4.6 MEDIUM — Race Condition in Gateway Detection

**Location:** `get_vpn_gateway()` — uses a fixed `sleep 5` then parses the OpenVPN log

**What it does:** Waits 5 seconds for OpenVPN to write the `route_gateway` line to its log, then greps for it. Falls back to parsing `ip addr show` for the `peer` address. Falls back again to a hardcoded `10.96.0.1`.

**Why it's fragile:**
- On slow systems or loaded networks, 5 seconds is not enough
- If ProtonVPN changes its log format, the grep fails silently
- The hardcoded fallback `10.96.0.1` is almost certainly wrong and will create a non-functional route

**Impact:** VPN connects successfully (tun interface is up) but `configure_routing_v3()` adds a `default via 10.96.0.1` route that goes nowhere. The VPN is "running" but all traffic through it is blackholed.

---

### 4.7 MEDIUM — Security Monitor Wrong VPN_DIR

**Location:** `vpn-security-monitor.sh` line 13

```bash
VPN_DIR="/etc/protonvpn"   # WRONG
```

The actual VPN directory used everywhere else is `/usr/local/bin/ovpn`. This means the monitor's `discover_vpns()` dynamic discovery from `.ovpn` files never finds anything — it silently falls back to its hardcoded defaults only.

---

### 4.8 LOW — vpn-debug.sh Outdated VPN List

**Location:** `debugging/vpn-debug.sh` → `test` command, line 118–125

Hardcodes only 6 VPNs (`usa`, `netherlands`, `norway`, `mexico`, `japan`, `canada`) with `norway` mapped to port 1082, while the actual system uses `switzerland` on 1082. The debug tool tests the wrong things, giving false confidence.

---

### 4.9 LOW — Duplicate Block in setup_vpn_proxy()

**Location:** `multi-vpn-proxy.sh` lines 233–240 (before fix)

The `sed -i "/^dev /d"` + `echo "dev ${TUN_DEV}"` + `echo "pull-filter..."` block was copy-pasted twice identically. The second run would append a second `dev` line to the config (the first `sed` run deleted the original, and the second run just re-added it again). This caused OpenVPN to see `dev` defined twice — behavior is undefined and depends on OpenVPN version.

**Fix applied:** Collapsed into a single, correct block with `route-nopull`.

---

## 5. Why the Network Breaks Permanently (The Full Failure Chain)

Here is the complete sequence of events that leads to a full OS network failure:

```
1. User runs `./multi-vpn-proxy.sh start`
   └─ cleanup block runs `iptables -t mangle -F OUTPUT`
      └─ [SILENT DAMAGE] Docker/systemd rules wiped

2. OpenVPN connects for each VPN
   └─ OpenVPN's up-scripts modify /etc/resolv.conf
      └─ [SILENT DAMAGE] DNS now points at VPN servers

3. System runs for a while — proxies work

4. One VPN drops (ProtonVPN free tier disconnects often)
   └─ OpenVPN daemon dies
      └─ tun interface disappears
         └─ Routes pointing to that tun are now dead
            └─ [VISIBLE] Proxy on that port stops working

5. Security monitor detects failure, calls `spec restart <vpn>`
   └─ Which calls `setup_vpn_proxy()` again
      └─ Which runs a new OpenVPN
         └─ Which again tries to modify DNS

6. User runs `./multi-vpn-proxy.sh stop` to clean up
   └─ `pkill openvpn` kills all OpenVPN daemons instantly (no graceful shutdown)
      └─ OpenVPN's `--down` scripts never run
         └─ /etc/resolv.conf still points at dead VPN DNS
            └─ [VISIBLE] No DNS resolution — "no internet"

7. User runs `start` again
   └─ `iptables -t mangle -F OUTPUT` runs again
      └─ [CUMULATIVE DAMAGE] Whatever Docker/systemd re-added is wiped again

8. Eventually: DNS broken + main routing table full of zombie routes
   + iptables mangle chain empty = complete network failure
   └─ Only fix: REBOOT
```

---

## 6. Possible Fixes (Prioritized)

### Fix Priority 1 — Already Applied
- [x] Replace `iptables -F OUTPUT` with surgical rule deletion
- [x] Add `route-nopull` + `pull-filter ignore "dhcp-option DNS"` to `.ovpn`
- [x] Fix cleanup range (100 → 111) and UID arithmetic in `setup.sh`
- [x] Make `apt-get` non-fatal in `setup.sh`
- [x] Add `rt_tables` entries for tables 106–111

### Fix Priority 2 — Still Needed
- [ ] Fix `vpn-security-monitor.sh` `VPN_DIR` from `/etc/protonvpn` → `/usr/local/bin/ovpn`
- [ ] Fix `vpn-debug.sh` test command (add missing 6 VPNs, fix `norway` → `switzerland`)
- [ ] Replace fixed `sleep 5` in `get_vpn_gateway()` with a polling loop that reads the log
- [ ] Add a fallback to `ip route show dev <tun>` for gateway detection

### Fix Priority 3 — Architectural
- [ ] Add DNS state save/restore: backup `/etc/resolv.conf` before start, restore on stop
- [ ] Use `--script-security 2` with a proper `--up`/`--down` script pair to manage DNS cleanly
- [ ] Replace `pkill openvpn` with PID-based kills to ensure `--down` scripts run
- [ ] Add `iptables -t mangle -S` state check before start to detect pre-existing conflicting rules

---

## 7. Alternative Architecture — Clean Rebuild Proposal

If the current system is deemed too fragile, here is a cleaner architecture using the same fundamentals (OpenVPN + policy routing) but with better isolation guarantees.

### 7.1 Core Insight

The current system's problems come from **shared global state**: one iptables mangle table, one `/etc/resolv.conf`, one main routing table. The fix is to make each VPN tunnel a **completely isolated network namespace**.

### 7.2 Network Namespace Architecture

```
[Host netns — default]
│   /etc/resolv.conf → untouched
│   main routing table → untouched
│   iptables → untouched
│
├── netns: vpn-usa
│   ├── lo + veth-usa (peer: veth-usa-host)
│   ├── tun0 (OpenVPN)
│   ├── own resolv.conf → VPN DNS (contained)
│   └── microsocks listening on veth-usa-host IP:1080
│
├── netns: vpn-netherlands
│   ├── lo + veth-nl
│   ├── tun1 (OpenVPN)
│   └── microsocks on veth-nl-host IP:1081
│
└── ... (x12)
```

**Key advantage:** Each VPN lives in its own kernel namespace. It **cannot** touch the host's routing table, DNS, or iptables — physically impossible. Killing one VPN namespace has zero effect on the others or the host.

**Tools required:** `ip netns` (already in iproute2, already a dependency), `veth` pairs (kernel built-in), OpenVPN (already installed), microsocks (already installed).

### 7.3 Alternative: Containers (Docker/Podman)

Each VPN runs in a container with its own network stack. The container exposes its microsocks port to the host. Complete isolation guaranteed by the container runtime.

**Downside:** Requires Docker/Podman installed. More overhead. But trivially reproducible and portable.

---

## 8. Fundamental Research Questions

These are the questions that must be answered to build a truly stable version of this system:

### Networking Fundamentals
1. **How does Linux policy routing (RPDB — Routing Policy Database) interact with iptables marks?** Specifically: what is the precedence order between `ip rule` uidrange and fwmark rules when both match the same packet?
2. **What does `route-nopull` do exactly at the OpenVPN protocol level?** Does it suppress the `PUSH_REPLY` processing entirely or only route-related options?
3. **Which system hooks does OpenVPN call on connect/disconnect?** (`--up`, `--down`, `/etc/openvpn/update-resolv-conf`, `resolvconf`, `systemd-resolved` DBus calls?) Which ones fire even when killed with `SIGKILL` vs `SIGTERM`?
4. **How does the Linux kernel handle packets when a `tun` device referenced in a routing rule disappears?** Does it fall through to the next rule, or does it drop the packet with `EHOSTUNREACH`?
5. **What is the exact behavior of `iptables -t mangle` marks across network namespaces?** Are marks namespace-scoped or global?

### Security Monitor Design
6. **What is the minimum reliable method to detect that an OpenVPN tunnel is fully functional** (not just that the process is running and the tun interface exists) **without making an external HTTP request?** (Hint: look at ICMP through the tunnel, BGP keepalives, or OpenVPN's own `--ping` directive)
7. **How can the monitor detect that a restart loop is occurring** (VPN connects, fails, restarts, repeat) **and escalate to a full system restart instead of individual VPN restarts?**

### Architecture Alternatives
8. **What are the actual Linux kernel syscalls involved in `ip rule add uidrange`?** Is this implemented via `SO_MARK` + netfilter, or is it a dedicated RPDB feature? (Relevant: `man 7 ip`, `man 8 ip-rule`)
9. **Can OpenVPN be configured to use a pre-created `tun` device** (`--dev-node`) instead of creating its own? This would allow the tun device to be created inside a network namespace before OpenVPN starts, eliminating namespace setup complexity.
10. **What is the resource overhead of 12 simultaneous network namespaces vs. 12 policy routing tables?** Which approach scales better to 24 or 48 tunnels?

### ProtonVPN Free Tier Specifics
11. **What is ProtonVPN's session timeout for free accounts?** Do they use periodic re-authentication that could explain spontaneous disconnections?
12. **Does ProtonVPN's free tier enforce a single active connection per account?** If so, running 12 tunnels requires 12 separate accounts — which the current `credentials*.txt` setup implies. What is the reliability of this approach at scale?

---

## 9. Open Issues Inventory

| ID | Severity | Location | Description | Status |
|----|----------|----------|-------------|--------|
| I-01 | CRITICAL | `multi-vpn-proxy.sh` | `iptables -F OUTPUT` wipes global chain | ✅ Fixed |
| I-02 | CRITICAL | `multi-vpn-proxy.sh` | OpenVPN hijacks DNS via `dhcp-option DNS` | ✅ Fixed |
| I-03 | HIGH | `multi-vpn-proxy.sh` | Route leak into main table | ✅ Fixed (via `route-nopull`) |
| I-04 | HIGH | `setup.sh` | `set -e` + apt failure = files never copied | ✅ Fixed |
| I-05 | HIGH | `setup.sh` | Cleanup loop only covers 100–105, not 100–111 | ✅ Fixed |
| I-06 | HIGH | `setup.sh` | Wrong UID arithmetic `${i}300` vs `$((3000+i))` | ✅ Fixed |
| I-07 | MEDIUM | `multi-vpn-proxy.sh` | Gateway detection with fixed `sleep 5` is fragile | 🔲 Open |
| I-08 | MEDIUM | `vpn-security-monitor.sh` | Wrong `VPN_DIR` path | 🔲 Open |
| I-09 | LOW | `vpn-debug.sh` | Outdated VPN list (6 of 12, wrong `norway`) | 🔲 Open |
| I-10 | LOW | `multi-vpn-proxy.sh` | Duplicate `sed`/`echo` block for `.ovpn` prep | ✅ Fixed |
| I-11 | ARCHITECTURAL | All | Shared global state (DNS, iptables) = cascading failures | 🔲 Research needed |
| I-12 | ARCHITECTURAL | All | `pkill openvpn` prevents `--down` scripts from cleaning up DNS | 🔲 Open |

---

## 10. References

### Linux Networking
- `man 8 ip-rule` — Policy routing rules (RPDB)
- `man 8 ip-route` — Routing tables
- `man 8 iptables` — netfilter/iptables
- `man 7 namespaces` — Linux network namespaces
- [Linux Advanced Routing & Traffic Control (LARTC)](https://lartc.org/howto/) — The definitive guide to policy routing
- [Kernel docs: net/core/filter.c](https://www.kernel.org/doc/html/latest/networking/filter.html) — Packet filtering internals

### OpenVPN
- [OpenVPN man page](https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/) — `--route-nopull`, `--pull-filter`, `--up`, `--down`, `--script-security`
- [OpenVPN Wiki: Routing](https://community.openvpn.net/openvpn/wiki/Routing) — How OpenVPN interacts with the OS routing table
- [update-resolv-conf](https://github.com/alfredopalhares/openvpn-update-resolv-conf) — The standard script for DNS management with OpenVPN

### microsocks
- [microsocks GitHub](https://github.com/rofl0r/microsocks) — Minimal SOCKS5 server used as the proxy layer

### Alternative Tools
- `tun2socks` — Converts a TUN device into a SOCKS5 proxy (alternative to microsocks + policy routing)
- `gvisor` / `netstack` — Userspace network stack (alternative to kernel netns for isolation)
- `slirp4netns` — Userspace networking for rootless containers

---

*This document reflects the state of the system as of 2026-05-22. Issues I-01 through I-06 and I-10 have been addressed in the current session. Issues I-07 through I-09 and I-11 through I-12 remain open for future work.*
