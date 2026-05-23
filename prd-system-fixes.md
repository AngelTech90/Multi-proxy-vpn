# PRD — Multi-Proxy VPN System v2.0
**Version:** 2.0  
**Date:** 2026-05-23  
**Status:** Draft — Implementation Planning  
**Supersedes:** PRD v1.0 (2026-05-22)  
**Author:** Derived from architectural review session

---

## 1. Executive Summary

This document specifies two parallel work tracks for the multi-proxy VPN system:

**Track A — Bash hardening:** Four targeted fixes to the existing shell-script architecture (I-07, I-08, I-09, I-12) that close the remaining open issues without requiring a full rebuild. These are tactical, low-risk, and can ship immediately.

**Track B — Docker containerization:** A full redesign of the system using Docker as the isolation primitive instead of Linux network namespaces managed manually. Each VPN tunnel runs in a sub-16 MB Docker container. This track eliminates the entire class of shared-global-state problems (I-11) permanently, replaces the bash orchestration with a declarative `docker-compose.yml`, and makes the system portable across machines.

Track A and Track B are not mutually exclusive. Track A should ship first. Track B is the target architecture for any deployment that needs reliable unattended operation.

---

## 2. Context and Problem Statement

The v1.0 architecture runs 12 OpenVPN tunnels + 12 microsocks SOCKS5 proxies on the host network stack, using Linux policy routing (RPDB) to isolate per-tunnel traffic. Critical bugs (I-01 through I-06, I-10) have been fixed. Four issues remain open:

| ID | Severity | Description |
|----|----------|-------------|
| I-07 | Medium | Gateway detection uses a fixed `sleep 5`; falls back to wrong hardcoded IP |
| I-08 | Medium | Security monitor looks in the wrong directory — is effectively blind |
| I-09 | Low | Debug script tests only 6 of 12 VPNs; wrong country name (`norway`) |
| I-12 | High | `pkill openvpn` skips `--down` scripts; DNS is never cleaned up on stop |

The root cause underlying all of these is I-11: the system's use of shared global kernel state (one iptables mangle table, one `/etc/resolv.conf`, one main routing table) means any single component's failure can cascade into full OS network failure. The bash fixes in Track A reduce the surface area of that failure; Track B eliminates it.

---

## 3. Goals

| ID | Goal | Track |
|----|------|-------|
| G1 | Expose SOCKS5 proxies on `127.0.0.1:1080`–`127.0.0.1:1091` | Both |
| G2 | Each proxy exits through a different VPN IP | Both |
| G3 | Host machine's default internet must never be affected | Both |
| G4 | No paid services beyond free ProtonVPN accounts | Both |
| G5 | System detects failed tunnels and restarts them autonomously | Both |
| G6 | Usable by external tools for IP rotation across accounts | Both |
| G7 | Zero cascading failures — one dead VPN cannot affect others | B only |
| G8 | No hand-managed kernel state — no `ip rule`, no iptables marks | B only |
| G9 | Deployable on a fresh machine with a single command | B only |
| G10 | Container memory ceiling of 32 MB per VPN slot (16 MB target) | B only |

---

## 4. Track A — Bash Hardening

### 4.1 Overview

Four self-contained patches to existing scripts. No new dependencies. No architectural changes. Estimated total implementation time: 2–3 hours.

---

### US-A01: Fix `vpn-security-monitor.sh` VPN_DIR path (I-08)

**Description:** As the system operator, I want the security monitor to actually find VPN configs so it can report real tunnel health.

**Root cause:** Line 13 of `vpn-security-monitor.sh` sets `VPN_DIR="/etc/protonvpn"`. The actual config directory is `/usr/local/bin/ovpn`. `discover_vpns()` globs `${VPN_DIR}/*.ovpn`, finds nothing, and silently falls back to hardcoded stubs. The monitor has never been monitoring the real system.

**Implementation:**

In `vpn-security-monitor.sh`:
```bash
# Before:
VPN_DIR="/etc/protonvpn"

# After:
VPN_DIR="/usr/local/bin/ovpn"
```

Additionally, update `discover_vpns()` to write a runtime state file that maps each slot to its port, pid, and ovpn filename. This state file should be written by `multi-vpn-proxy.sh` at startup and read by the monitor, rather than the monitor re-deriving the mapping from disk. This prevents the monitor from generating a different slot-to-port mapping than the orchestrator if ovpn filenames sort differently.

State file format (`/run/vpn-state/slot-map`):
```
# slot  port  tun   pid_file                      ovpn_file
100     1080  tun0  /run/vpn-state/openvpn-100.pid  usa-01.protonvpn.udp.ovpn
101     1081  tun1  /run/vpn-state/openvpn-101.pid  nl-01.protonvpn.udp.ovpn
...
```

**Acceptance Criteria:**
- [ ] `VPN_DIR` points to `/usr/local/bin/ovpn`
- [ ] `discover_vpns()` reads from `/run/vpn-state/slot-map` if it exists
- [ ] Monitor correctly identifies all 12 slots when the system is running
- [ ] Monitor logs an explicit error (not silence) when no slot-map is found
- [ ] `systemctl status vpn-monitor` shows correct per-slot health after fix

---

### US-A02: Fix `vpn-debug.sh` VPN coverage (I-09)

**Description:** As the system operator, I want `vpn-debug.sh test` to verify all 12 SOCKS5 ports so I get a truthful picture of system health.

**Root cause:** The `test` subcommand hardcodes 6 VPN names with the wrong name for slot 1082 (`norway` instead of `switzerland`). Slots 1086–1091 are never tested. The name-to-port mapping is also a maintenance liability.

**Implementation:**

Replace the hardcoded name loop with a port-range loop. Port numbers are stable and don't require a name mapping:

```bash
cmd_test() {
    echo "Testing all 12 SOCKS5 proxies..."
    local pass=0 fail=0

    for port in $(seq 1080 1091); do
        local result
        # socks5h:// sends DNS through the proxy — validates tunnel DNS too
        result=$(curl --silent --max-time 8 \
            --proxy "socks5h://127.0.0.1:${port}" \
            "https://api.ipify.org" 2>/dev/null)

        if [[ -n "$result" ]]; then
            echo "  [OK]   Port ${port} → exit IP: ${result}"
            ((pass++))
        else
            echo "  [FAIL] Port ${port} → no response"
            ((fail++))
        fi
    done

    echo ""
    echo "Result: ${pass}/12 proxies healthy, ${fail} failed"
    [[ $fail -eq 0 ]]  # exit 0 on full pass, 1 on any failure
}
```

**Acceptance Criteria:**
- [ ] `vpn-debug.sh test` tests ports 1080 through 1091 (all 12)
- [ ] Uses `socks5h://` (DNS-via-proxy) not `socks5://` (local DNS)
- [ ] Prints each port's result individually, not just a summary
- [ ] Returns exit code 0 when all 12 pass, exit code 1 when any fail
- [ ] No hardcoded country names remain in the test command
- [ ] `vpn-debug.sh test` completes in under 30 seconds (8s timeout × 12, sequential)

---

### US-A03: Replace fixed `sleep 5` gateway detection with polling loop (I-07)

**Description:** As the system operator, I want VPN slots to reliably detect their gateway IP so that routing tables are set up correctly on both fast and slow systems.

**Root cause:** `get_vpn_gateway()` does a fixed `sleep 5` then greps the OpenVPN log. On slow systems this is insufficient. On fast systems it wastes startup time. The fallback is a hardcoded `10.96.0.1` which is almost certainly wrong for ProtonVPN's actual gateway and silently creates a blackhole route that looks healthy.

**Implementation:**

Replace `get_vpn_gateway()` with a three-method polling approach:

```bash
get_vpn_gateway() {
    local tun_dev="$1"
    local log_file="$2"
    local max_wait="${3:-30}"   # configurable, default 30s
    local interval=1
    local elapsed=0
    local gw=""

    # Method 1: poll OpenVPN log for route_vpn_gateway (most authoritative)
    while [[ -z "$gw" && $elapsed -lt $max_wait ]]; do
        gw=$(grep -oP '(?<=route_vpn_gateway )\S+' "$log_file" 2>/dev/null \
             | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
        [[ -z "$gw" ]] && sleep $interval && ((elapsed += interval))
    done

    # Method 2: read from kernel routing table for the tun device
    if [[ -z "$gw" ]]; then
        gw=$(ip route show dev "$tun_dev" 2>/dev/null \
             | grep -oP 'via \K[\d.]+' | head -1)
    fi

    # Method 3: read the peer address from ip addr show
    if [[ -z "$gw" ]]; then
        gw=$(ip addr show dev "$tun_dev" 2>/dev/null \
             | grep -oP 'peer \K[\d.]+(?=/)' | head -1)
    fi

    # Fail loudly — never return a wrong address
    if [[ -z "$gw" ]]; then
        log_error "[slot ${tun_dev}] Could not determine VPN gateway after ${elapsed}s."
        log_error "  Checked: log file (${log_file}), ip route, ip addr."
        log_error "  Aborting setup for this slot — will not create blackhole route."
        return 1
    fi

    log_info "[slot ${tun_dev}] Gateway detected: ${gw} (after ${elapsed}s)"
    echo "$gw"
}
```

Callers must propagate failure:
```bash
gw=$(get_vpn_gateway "tun${slot}" "$log_file") || {
    log_error "Skipping slot ${slot} due to gateway detection failure"
    cleanup_vpn "$slot"
    return 1
}
```

The hardcoded fallback `10.96.0.1` must be removed entirely. A wrong fallback is worse than an explicit failure.

**Optional enhancement (recommended):** Add `--script-security 2` to the OpenVPN invocation and an `--up` script that writes `$route_vpn_gateway` to `/run/vpn-state/tun${N}.gw`. The main script reads this file instead of parsing logs. This eliminates the polling entirely and is more reliable because OpenVPN only calls `--up` when the tunnel is fully established.

**Acceptance Criteria:**
- [ ] Hardcoded `10.96.0.1` fallback is removed
- [ ] `get_vpn_gateway()` polls for up to 30 seconds before failing
- [ ] Function returns non-zero on failure, caller skips the slot cleanly
- [ ] Gateway is validated as a dotted-quad IPv4 string before being returned
- [ ] Slow-start scenario (gateway appears after 12s) succeeds on a real system
- [ ] Fast-start scenario (gateway appears in 1s) succeeds without waiting the full 30s
- [ ] Failed gateway detection produces a clear error log, not silent continuation

---

### US-A04: Replace `pkill openvpn` with PID-based shutdown + DNS backup/restore (I-12)

**Description:** As the system operator, I want the system to clean up completely on stop so that DNS and routing are always restored even after an ungraceful shutdown.

**Root cause:** `pkill openvpn` kills all OpenVPN processes without waiting for them to exit. `--down` scripts are not configured, so DNS cleanup never runs. The system has no DNS save/restore mechanism of its own.

**Implementation — three parts:**

**Part 1: Start OpenVPN with `--writepid`:**
```bash
# Add to OpenVPN invocation in setup_vpn_proxy():
--writepid "/run/vpn-state/openvpn-${slot}.pid" \
--script-security 2 \
--up   "/usr/local/bin/vpn-up.sh" \
--down "/usr/local/bin/vpn-down.sh"
```

**Part 2: Per-slot PID-based shutdown:**
```bash
cleanup_vpn_slot() {
    local slot="$1"
    local pid_file="/run/vpn-state/openvpn-${slot}.pid"
    local pid

    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -z "$pid" ]]; then
        log_warn "[slot ${slot}] No PID file found, attempting process search"
        # fallback: find by tun device argument
        pid=$(pgrep -f "openvpn.*tun${slot}" | head -1)
    fi

    if [[ -z "$pid" ]]; then
        log_info "[slot ${slot}] No OpenVPN process found, skipping"
        return 0
    fi

    # SIGTERM — allows --down script to run
    log_info "[slot ${slot}] Sending SIGTERM to PID ${pid}"
    kill -TERM "$pid" 2>/dev/null || true

    # Wait up to 10s for clean exit
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
        sleep 1; ((waited++))
    done

    # SIGKILL only as last resort
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "[slot ${slot}] PID ${pid} did not exit in 10s, sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$pid_file"
    log_info "[slot ${slot}] Shutdown complete (waited ${waited}s)"
}
```

**Part 3: DNS save/restore as belt-and-suspenders:**
```bash
# Called at start, before any OpenVPN is launched:
save_dns_state() {
    mkdir -p /run/vpn-state
    cp /etc/resolv.conf /run/vpn-state/resolv.conf.backup
    log_info "DNS state saved: $(cat /run/vpn-state/resolv.conf.backup | grep nameserver)"
}

# Called at stop, after all slots are cleaned up:
restore_dns_state() {
    if [[ -f /run/vpn-state/resolv.conf.backup ]]; then
        cp /run/vpn-state/resolv.conf.backup /etc/resolv.conf
        log_info "DNS state restored"
        rm -f /run/vpn-state/resolv.conf.backup
    else
        log_warn "No DNS backup found — resolv.conf not restored"
    fi
}
```

This is complementary to `route-nopull` + `pull-filter ignore "dhcp-option DNS"` (already applied): the VPN configs don't touch DNS in the first place, but if anything ever goes wrong, `stop` restores it explicitly.

**Acceptance Criteria:**
- [ ] Each OpenVPN process is started with `--writepid /run/vpn-state/openvpn-${slot}.pid`
- [ ] `stop` uses per-slot PID files, not `pkill openvpn`
- [ ] `stop` waits up to 10s for clean SIGTERM exit before escalating to SIGKILL
- [ ] `/etc/resolv.conf` is saved before start and restored after stop
- [ ] `stop` followed by `cat /etc/resolv.conf` shows the pre-VPN DNS, not ProtonVPN's
- [ ] Stopping a partially-started system (e.g., 4 of 12 slots running) works cleanly
- [ ] Each slot's cleanup is independent — one slot's failure does not abort cleanup of others

---

## 5. Track B — Docker Containerization

### 5.1 Evaluation: Why Docker?

The bash architecture manages isolation through Linux primitives (uidrange rules, fwmark marks, per-slot routing tables). These work, but they are stateful, imperative, and invisible to standard tooling. Any bug in cleanup leaves behind kernel state that the next run inherits. Docker provides the same underlying isolation (namespaces, cgroups) but wraps it in:

- **Declarative configuration** — `docker-compose.yml` describes the desired state; the runtime enforces it
- **Automatic cleanup** — stopping a container releases all its network state atomically
- **Restartability** — `restart: unless-stopped` with health checks replaces the custom monitor daemon
- **Portability** — the entire system moves to a new machine with `git clone` + `docker compose up`
- **Observability** — `docker ps`, `docker logs`, `docker stats` give instant visibility with no custom tooling

The primary concern for this system is memory: 12 containers that are large would be worse than 12 kernel namespaces. This is the central question the evaluation below answers.

---

### 5.2 Container Memory Analysis

A minimal OpenVPN + microsocks container needs:

| Component | Base memory | Notes |
|-----------|------------|-------|
| Alpine Linux base | ~4–5 MB | musl libc, busybox only |
| OpenVPN process | ~3–5 MB RSS | Steady state, one tunnel |
| microsocks process | ~0.5–1 MB RSS | Single-threaded, minimal |
| Kernel overhead per container | ~1–2 MB | netns, cgroup, veth pair state |
| **Total per container** | **~9–13 MB** | **Fits 16 MB target** |

The 16 MB ceiling is achievable. The key constraints:

1. **Base image must be Alpine**, not Debian/Ubuntu. Alpine with musl libc and `openvpn` installed is ~15 MB on disk, ~5 MB runtime RSS.
2. **No init system inside the container.** Use `tini` (200 KB) as PID 1 to reap zombies, not systemd or s6.
3. **microsocks must be compiled statically** or installed from Alpine's apk repo (available as `microsocks`).
4. **No shell scripts inside the container** beyond the entrypoint. The container does one thing: run one VPN + one proxy.

Realistic memory budget at scale:

| Slots | Per-container target | Total host overhead |
|-------|---------------------|---------------------|
| 12 | 16 MB | ~200 MB |
| 24 | 16 MB | ~400 MB |
| 48 | 16 MB | ~800 MB |

For comparison: the bash approach with 12 kernel namespaces uses ~2–6 MB of kernel memory for the namespaces themselves, but the OpenVPN and microsocks processes exist on the host and use the same ~4–6 MB RSS each regardless. Docker adds ~4–7 MB overhead per container for the container runtime, kernel cgroup tracking, and veth pair state — the difference is real but small (~50–80 MB total for 12 containers vs the bare namespace approach).

**The trade-off is worth it.** The operational and reliability gains of Docker outweigh the modest memory difference.

---

### 5.3 Architecture: Docker Proxy Approach

Each VPN slot is a container. The host exposes SOCKS5 ports by mapping the container's bound port to `127.0.0.1:108x`. The container's network is `--cap-add NET_ADMIN` with its own network namespace — OpenVPN creates a `tun0` inside the container's namespace and routes all traffic through it. The host routing table is never touched.

```
[Host]
  127.0.0.1:1080 ──► [Docker port mapping]
                             │
                     [Container: vpn-slot-100]
                         network namespace
                         ├── eth0 (Docker bridge → internet for VPN bootstrap)
                         ├── tun0 (OpenVPN tunnel)
                         ├── microsocks :1080 bound to 0.0.0.0
                         └── default route: via tun0 (after VPN connects)
                             (eth0 used only for OpenVPN handshake traffic)
```

The routing inside the container is simple: before OpenVPN connects, `eth0` is the default route (for the initial VPN handshake). After OpenVPN connects and `tun0` is up, the entrypoint script adds `default via tun0` and removes the `eth0` default. All subsequent traffic (including microsocks-proxied traffic) exits through the VPN.

This is the same pattern used by `docker-openvpn`, `gluetun`, and other VPN container projects. It is well-understood and well-tested.

---

### 5.4 Alternative: Using an Existing VPN Proxy Container (Gluetun)

**Gluetun** (https://github.com/ql701/gluetun) is a purpose-built VPN container that includes a SOCKS5 proxy endpoint. It supports ProtonVPN natively, handles reconnection automatically, exposes a control API, and has a health check endpoint at `:8000/v1/openvpn/status`. Its base image is ~30 MB compressed, ~60 MB runtime RSS — above the 16 MB target but offering significant operational advantages.

| Criterion | Custom Alpine container | Gluetun |
|-----------|------------------------|---------|
| Runtime memory | ~12–16 MB | ~55–65 MB |
| ProtonVPN support | Manual `.ovpn` | Built-in, maintained |
| Auto-reconnect | Entrypoint script | Built-in, tested |
| Health check API | Custom | `GET /v1/openvpn/status` |
| Kill switch (leak prevention) | Manual iptables | Built-in |
| DNS leak prevention | Manual | Built-in |
| Maintenance burden | Owner | Community |
| Portability to other VPN providers | Requires ovpn file changes | Config-only change |

**Recommendation:** For the 12-slot deployment at 16 MB target, use the custom Alpine container — it's achievable and keeps full control over the ProtonVPN credential files and ovpn configs. **For any expansion beyond 24 slots or any deployment where operational simplicity is prioritized over raw memory usage, adopt Gluetun.** The ~45 MB additional RSS per container is a real cost, but the built-in kill switch, DNS leak prevention, and health API eliminate multiple categories of manual work.

---

### 5.5 Docker Compose Design

```yaml
# docker-compose.yml
version: "3.9"

x-vpn-slot: &vpn-slot
  build:
    context: ./docker/vpn-slot
    dockerfile: Dockerfile
  restart: unless-stopped
  cap_add:
    - NET_ADMIN
  devices:
    - /dev/net/tun
  mem_limit: 32m
  memswap_limit: 32m
  healthcheck:
    test: ["CMD", "curl", "-sf",
           "--proxy", "socks5h://127.0.0.1:1080",
           "--max-time", "8",
           "https://api.ipify.org"]
    interval: 45s
    timeout: 10s
    retries: 3
    start_period: 30s
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"

services:
  vpn-100:
    <<: *vpn-slot
    volumes:
      - ./ovpn/usa-01.protonvpn.udp.ovpn:/etc/vpn/config.ovpn:ro
      - ./credentials/creds-100.txt:/etc/vpn/credentials.txt:ro
    ports:
      - "127.0.0.1:1080:1080"

  vpn-101:
    <<: *vpn-slot
    volumes:
      - ./ovpn/nl-01.protonvpn.udp.ovpn:/etc/vpn/config.ovpn:ro
      - ./credentials/creds-101.txt:/etc/vpn/credentials.txt:ro
    ports:
      - "127.0.0.1:1081:1080"

  # ... vpn-102 through vpn-111 follow the same pattern
```

The `x-vpn-slot` anchor defines all shared configuration: restart policy, capabilities, device access, memory ceiling, health check, and log rotation. Each slot overrides only its ovpn file, credentials file, and host port mapping.

**Key design decisions:**

- `mem_limit: 32m` is the hard ceiling; containers that exceed it are OOM-killed and restarted automatically. Set `memswap_limit: 32m` to prevent swap use.
- `restart: unless-stopped` replaces the custom monitor daemon for crash recovery.
- The health check uses `socks5h://` (DNS-through-proxy) to validate the full tunnel including DNS, not just that the process is running.
- `devices: /dev/net/tun` grants the container access to create tun interfaces without full `--privileged`.
- `cap_add: NET_ADMIN` allows the entrypoint to add/remove routes inside the container namespace.
- Port mapping binds only to `127.0.0.1` — the SOCKS5 ports are not exposed on the host's public interface.

---

### 5.6 Container Dockerfile

```dockerfile
# docker/vpn-slot/Dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    openvpn \
    microsocks \
    curl \
    tini

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
```

```bash
#!/bin/sh
# docker/vpn-slot/entrypoint.sh
set -e

OVPN_CONFIG="/etc/vpn/config.ovpn"
CREDS_FILE="/etc/vpn/credentials.txt"
SOCKS_PORT="${SOCKS_PORT:-1080}"
VPN_TIMEOUT="${VPN_TIMEOUT:-60}"

log() { echo "[$(date -Iseconds)] $*"; }

# Append credential file reference to ovpn config
TEMP_OVPN=$(mktemp /tmp/vpn.XXXXXX.ovpn)
cp "$OVPN_CONFIG" "$TEMP_OVPN"
cat >> "$TEMP_OVPN" <<EOF
auth-user-pass $CREDS_FILE
route-nopull
pull-filter ignore "dhcp-option DNS"
ping 10
ping-restart 60
EOF

# Start OpenVPN in background
log "Starting OpenVPN..."
openvpn --config "$TEMP_OVPN" \
        --dev tun0 \
        --script-security 2 \
        --up /usr/local/bin/vpn-connected.sh \
        --log /tmp/openvpn.log \
        --writepid /tmp/openvpn.pid \
        --daemon

# Wait for tun0 to appear (OpenVPN connected)
log "Waiting for tun0..."
elapsed=0
while ! ip link show tun0 >/dev/null 2>&1; do
    sleep 1; elapsed=$((elapsed + 1))
    if [ $elapsed -ge $VPN_TIMEOUT ]; then
        log "ERROR: tun0 did not appear after ${VPN_TIMEOUT}s"
        log "OpenVPN log:"
        cat /tmp/openvpn.log
        exit 1
    fi
done

# Get VPN gateway (poll routing table)
GW=""
for _ in $(seq 1 15); do
    GW=$(ip route show dev tun0 2>/dev/null | grep -oP 'via \K[\d.]+' | head -1)
    [ -n "$GW" ] && break
    sleep 1
done

if [ -z "$GW" ]; then
    log "ERROR: Could not determine VPN gateway"
    exit 1
fi
log "VPN gateway: $GW"

# Route all container traffic through VPN
ip route del default 2>/dev/null || true
ip route add default via "$GW" dev tun0
log "Default route set via tun0 ($GW)"

# Start microsocks (foreground, becomes PID 1's child)
log "Starting microsocks on :${SOCKS_PORT}"
exec microsocks -p "$SOCKS_PORT"
```

Note: `exec microsocks` replaces the entrypoint process with microsocks, so Docker's PID tracking and signal forwarding work correctly. `tini` as PID 1 reaps any zombie processes from the brief OpenVPN daemon and gateway detection phases.

---

### 5.7 Kill Switch (Leak Prevention)

The entrypoint should add an iptables kill switch before starting OpenVPN to prevent any traffic from leaving through `eth0` once the VPN is established. This prevents IP leaks if the VPN disconnects and tun0 disappears:

```bash
# Add to entrypoint.sh before starting OpenVPN:
# Allow established connections (for VPN handshake on eth0)
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Allow traffic on tun0 (VPN tunnel)
iptables -A OUTPUT -o tun0 -j ACCEPT
# Allow OpenVPN's UDP port on eth0 (for initial handshake + re-auth)
iptables -A OUTPUT -o eth0 -p udp --dport 1194 -j ACCEPT
iptables -A OUTPUT -o eth0 -p udp --dport 51820 -j ACCEPT
# Block everything else on eth0
iptables -A OUTPUT -o eth0 -j REJECT
```

This is the "kill switch" pattern standard in VPN containers. If tun0 goes down, `eth0` is blocked, so traffic to microsocks fails loudly rather than leaking through the unprotected interface. In the bash architecture, implementing this requires surgical iptables management per-slot; in the container, it's 6 lines in the entrypoint and scoped to that container's namespace.

---

### 5.8 User Stories — Track B

---

### US-B01: Docker image build and smoke test

**Description:** As the system operator, I want a single Docker image that runs one OpenVPN + microsocks pair so I can validate the approach before deploying all 12.

**Acceptance Criteria:**
- [ ] `docker build -t vpn-slot ./docker/vpn-slot` completes successfully
- [ ] `docker images vpn-slot` shows image size under 25 MB compressed
- [ ] Running the image with a valid `.ovpn` + credentials produces a working SOCKS5 proxy
- [ ] `curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org` returns an IP different from the host's public IP
- [ ] `docker stats --no-stream` shows memory usage under 32 MB while the tunnel is active
- [ ] Container exits non-zero (and Docker restarts it) if OpenVPN fails to connect within 60s

---

### US-B02: docker-compose.yml for all 12 slots

**Description:** As the system operator, I want to start and stop all 12 VPN proxy slots with a single command.

**Acceptance Criteria:**
- [ ] `docker compose up -d` starts all 12 containers
- [ ] `docker compose ps` shows all 12 containers as `healthy` within 2 minutes of startup
- [ ] `docker compose down` stops all 12 containers and cleans up ports
- [ ] Each container's SOCKS5 port is bound only to `127.0.0.1`, not `0.0.0.0`
- [ ] All 12 SOCKS5 ports return different exit IPs when tested in sequence
- [ ] No container's failure causes any other container to restart or fail
- [ ] Host machine's `/etc/resolv.conf` is identical before and after `compose up` + `compose down`
- [ ] Host machine's default internet route is identical before and after

---

### US-B03: Memory ceiling enforcement

**Description:** As the system operator, I want each container hard-limited to 32 MB of memory so 12 containers cannot exhaust host RAM.

**Acceptance Criteria:**
- [ ] `mem_limit: 32m` set on each container in `docker-compose.yml`
- [ ] `memswap_limit: 32m` set to prevent swap usage
- [ ] `docker stats` shows each container's `MEM USAGE / LIMIT` as `X.X MiB / 32MiB`
- [ ] A container that exceeds its memory ceiling is OOM-killed by Docker (logged as `OOMKilled`) and restarted automatically
- [ ] Total memory footprint for all 12 containers is under 400 MB per `docker stats`

---

### US-B04: Health check and automatic recovery

**Description:** As the system operator, I want failed VPN tunnels to recover automatically without manual intervention, replacing the `vpn-security-monitor.sh` daemon.

**Acceptance Criteria:**
- [ ] Health check interval is 45 seconds (matching the existing monitor)
- [ ] A container is marked `unhealthy` after 3 consecutive failed health checks
- [ ] Docker restarts an `unhealthy` container automatically via `restart: unless-stopped`
- [ ] `docker compose ps` shows health status for each container in real time
- [ ] A container that fails to reconnect 5 times within 10 minutes enters an exponential backoff
- [ ] Host alert (log message + optional webhook) fires when any container enters `unhealthy` state

---

### US-B05: Kill switch verification

**Description:** As the system operator, I want to confirm that no traffic leaks through the unprotected `eth0` interface when the VPN tunnel drops.

**Acceptance Criteria:**
- [ ] With the container running, `docker exec vpn-100 iptables -L OUTPUT` shows the kill switch rules
- [ ] Manually stopping tun0 inside the container (`docker exec vpn-100 ip link set tun0 down`) causes `curl` through the SOCKS5 port to fail (not return the host's real IP)
- [ ] Container health check transitions to `unhealthy` within 45–135 seconds of tun0 going down
- [ ] Container restarts and returns to `healthy` automatically within 3 minutes

---

### US-B06: Credential file security

**Description:** As the system operator, I want credential files to be passed to containers without embedding them in the Docker image.

**Acceptance Criteria:**
- [ ] Credential files are mounted as read-only volumes, not baked into the image
- [ ] `docker history vpn-slot` shows no credential file content in image layers
- [ ] `docker inspect vpn-100` shows the credential mount as `:ro`
- [ ] Revoking credentials requires only replacing the host-side file and restarting the container, not rebuilding the image
- [ ] `.dockerignore` excludes `credentials/` from the build context

---

## 6. Migration Path

Track A and Track B can coexist during transition. The recommended sequence:

1. **Ship Track A fixes** (1–2 days). This stabilizes the existing bash system and closes all open issues.
2. **Build and test the Docker image** on one slot (US-B01). This validates the container approach without committing to full migration.
3. **Run Docker and bash side-by-side** on different port ranges temporarily (bash on 1080–1085, Docker on 1086–1091) to compare reliability under real load.
4. **Full cutover to Docker** once the Docker slots have run cleanly for 72 hours. The bash system's `stop` command tears down the remaining slots.
5. **Deprecate the bash orchestrator.** Keep the bash scripts in the repo tagged as `v1-legacy` but stop maintaining them for new functionality.

---

## 7. Non-Goals

- No GUI or web dashboard for monitoring (CLI tooling only: `docker compose ps`, `docker stats`)
- No VPN provider other than ProtonVPN free tier in this revision
- No IPv6 support (ProtonVPN free tier does not provide IPv6 endpoints on all servers)
- No traffic load balancing across slots (slots are independent; load balancing is the responsibility of the calling tool)
- No automatic credential rotation or account creation
- No Kubernetes deployment (out of scope; `docker compose` is sufficient for the 12-slot use case)

---

## 8. Technical Constraints

| Constraint | Detail |
|-----------|--------|
| Target host OS | Ubuntu 22.04 LTS or later; kernel ≥ 5.15 |
| Docker version | ≥ 24.0 (for compose v2 and health check format) |
| Host RAM minimum | 1 GB available after OS overhead |
| `/dev/net/tun` | Must exist on host and be accessible to Docker |
| ProtonVPN free tier | One simultaneous connection per account; 12 slots require 12 accounts |
| No `--privileged` | Containers use only `NET_ADMIN` + `/dev/net/tun` device, not full privilege |

---

## 9. Open Questions

| ID | Question | Impact |
|----|----------|--------|
| OQ-1 | Does ProtonVPN rate-limit or suspend free accounts that reconnect more than N times per hour? If yes, the 60s `ping-restart` may need to be increased. | High — affects container restart behavior |
| OQ-2 | Can the iptables kill switch rules coexist with Docker's own iptables rules inside the container network namespace? Docker may pre-populate the container's iptables with NAT rules on container start. | High — affects kill switch reliability |
| OQ-3 | Does Alpine's packaged `openvpn` version support all the `.ovpn` directives used by ProtonVPN free tier configs? ProtonVPN uses TLS 1.2 + cipher negotiation that older OpenVPN versions handle differently. | Medium — verify with `apk info openvpn` version check |
| OQ-4 | Should the Docker health check use an external endpoint (`api.ipify.org`) or an internal endpoint (OpenVPN's own `--ping` mechanism)? External calls add latency and create external dependency; internal checks don't validate end-to-end connectivity. | Medium — affects health check design |
| OQ-5 | For the Gluetun evaluation: is 55–65 MB per container acceptable if it reduces maintenance burden? This is a deployment-context question requiring operator input. | Low for 12 slots, High for 48+ slots |

---

## 10. Success Metrics

| Metric | Current baseline | Target (Track A) | Target (Track B) |
|--------|-----------------|-----------------|-----------------|
| Mean time between host reboots | ~24–48h under load | > 2 weeks | Indefinite |
| Failed VPN slots requiring manual restart | Frequent | Rare (< 1/day) | Zero (auto-recover) |
| Time to full system restart after crash | Manual, variable | < 5 min | < 3 min (Docker restart policy) |
| Host `/etc/resolv.conf` corrupted after stop | Frequent | Never | Never (physically isolated) |
| Memory per VPN slot (process RSS) | Same as Docker | Same | < 32 MB |
| Operator intervention per day | Daily | < Weekly | < Monthly |

---

## 11. References

- PRD v1.0 (2026-05-22) — original architecture, issues I-01 through I-12
- Alpine Linux package index: https://pkgs.alpinelinux.org (verify `openvpn`, `microsocks` versions)
- Gluetun project: https://github.com/ql701/gluetun
- Docker compose spec (mem_limit, healthcheck): https://docs.docker.com/compose/compose-file/
- tini (PID 1 init for containers): https://github.com/krallin/tini
- OpenVPN `--script-security`, `--up`, `--down`, `--writepid`: https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
- microsocks: https://github.com/rofl0r/microsocks

---

*Issues I-07, I-08, I-09, I-12 are addressed in Track A. Issue I-11 (shared global state) is resolved by Track B. Track A can ship independently. Track B supersedes the need for Track A in any new deployment.*
