# ── Stage 1: Build microsocks ──────────────────────────────────────────────────
FROM alpine:3.19 AS builder

RUN apk add --no-cache git gcc musl-dev make

RUN git clone --depth 1 https://github.com/rofl0r/microsocks /src/microsocks \
 && cd /src/microsocks \
 && make \
 && install -m 755 microsocks /usr/local/bin/microsocks

# ── Stage 2: Runtime image ────────────────────────────────────────────────────
FROM alpine:3.19

RUN apk add --no-cache \
        openvpn \
        iptables \
        ip6tables \
        curl \
        bash \
        iproute2

COPY --from=builder /usr/local/bin/microsocks /usr/local/bin/microsocks

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV VPN_NAME=""   \
    OVPN_FILE=""  \
    CREDS_FILE="" \
    PROXY_PORT=1080

EXPOSE 1080

ENTRYPOINT ["/entrypoint.sh"]
