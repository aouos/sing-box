#!/usr/bin/env bash
#
# sing-box installer — VLESS-Reality (TCP)
# Supports: Ubuntu 20+ / Debian 11+ (x86_64 / arm64)
# Install: bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
# Manage:  sb
#

set -euo pipefail

WORK_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
CONFIG_FILE="${WORK_DIR}/config.json"
INFO_FILE="${WORK_DIR}/info.dat"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SCRIPT_LINK="/usr/local/bin/sb"

G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'
R='\033[0;31m'; W='\033[1;37m'; N='\033[0m'

info() { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
err()  { echo -e "  ${R}✗${N} $*"; exit 1; }
line() { echo -e "${C}─────────────────────────────────────────────────${N}"; }

# ======================== Helpers ========================

get_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me https://ip.sb; do
        ip=$(curl -4 -s --connect-timeout 5 "$url" 2>/dev/null || true)
        [[ -n "$ip" ]] && { SERVER_IP="$ip"; return; }
    done
    [[ -n "${SERVER_IP:-}" ]] || err "Failed to detect public IPv4"
}

random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        ss -tunlp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
    done
}

show_qr() { command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 -m 2 "$1" 2>/dev/null || true; }

# ======================== Install ========================

install_deps() {
    echo -e "\n${W}▶ Installing dependencies${N}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl jq tar gzip qrencode vnstat >/dev/null 2>&1
    systemctl enable --now vnstat >/dev/null 2>&1 || true
    info "Dependencies ready"
}

install_singbox() {
    echo -e "\n${W}▶ Installing sing-box${N}"
    local VER
    VER=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    [[ -z "$VER" || "$VER" == "null" ]] && \
        VER=$(curl -fsSL "https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box" 2>/dev/null \
              | grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+",' | head -1 | tr -d '",')
    [[ -z "$VER" ]] && err "Failed to fetch version"

    local ARCH
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *)       err "Unsupported arch: $(uname -m)" ;;
    esac

    local TMP="/tmp/sb-install-$$"
    mkdir -p "$TMP"
    info "Downloading v${VER} ..."
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz" \
        -o "${TMP}/sb.tar.gz" || err "Download failed"
    tar -xzf "${TMP}/sb.tar.gz" -C "$TMP"
    cp -f "$(find "$TMP" -name sing-box -type f | head -1)" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$TMP"
    info "sing-box v${VER} installed"
}

setup_config() {
    echo -e "\n${W}▶ Generating config${N}"
    umask 077
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    UUID=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local KP
    KP=$("$BIN_PATH" generate reality-keypair)
    PRIVATE_KEY=$(echo "$KP" | awk '/PrivateKey/{print $NF}')
    PUBLIC_KEY=$(echo "$KP" | awk '/PublicKey/{print $NF}')
    SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    REALITY_SNI="www.icloud.com"
    VLESS_PORT=$(random_port)

    cat > "$CONFIG_FILE" << EOF
{
    "log": { "level": "info", "timestamp": true },
    "dns": { "servers": [{ "type": "local", "tag": "local" }] },
    "inbounds": [{
        "type": "vless",
        "tag": "vless-reality",
        "listen": "0.0.0.0",
        "listen_port": ${VLESS_PORT},
        "users": [{ "name": "user", "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
        "tls": {
            "enabled": true,
            "server_name": "${REALITY_SNI}",
            "reality": {
                "enabled": true,
                "handshake": { "server": "${REALITY_SNI}", "server_port": 443 },
                "private_key": "${PRIVATE_KEY}",
                "short_id": ["${SHORT_ID}"]
            }
        }
    }],
    "outbounds": [{ "type": "direct", "tag": "direct" }],
    "route": { "default_domain_resolver": "local" }
}
EOF

    if "$BIN_PATH" check -c "$CONFIG_FILE" 2>/tmp/sb-check.log; then
        info "Config validated"
    else
        cat /tmp/sb-check.log; rm -f /tmp/sb-check.log
        err "Config validation failed"
    fi
    chmod 600 "$CONFIG_FILE"
}

enable_bbr() {
    echo -e "\n${W}▶ Enabling BBR${N}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        info "BBR already enabled"; return
    fi
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null \
        || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null \
        || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr \
        && info "BBR enabled" || warn "BBR setup failed"
}

start_service() {
    echo -e "\n${W}▶ Starting service${N}"
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=sing-box proxy service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box --now >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet sing-box && info "sing-box is running" || err "Start failed → journalctl -u sing-box"
}

save_and_link() {
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"
    {
        printf 'UUID=%q\n'        "$UUID"
        printf 'VLESS_PORT=%q\n'  "$VLESS_PORT"
        printf 'PUBLIC_KEY=%q\n'  "$PUBLIC_KEY"
        printf 'PRIVATE_KEY=%q\n' "$PRIVATE_KEY"
        printf 'SHORT_ID=%q\n'    "$SHORT_ID"
        printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
        printf 'SERVER_IP=%q\n'   "$SERVER_IP"
        printf 'VLESS_LINK=%q\n'  "$VLESS_LINK"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

show_link() {
    echo ""
    line
    echo -e "  ${C}VLESS-Reality (TCP) · Port ${VLESS_PORT}${N}"
    line
    echo -e "  ${G}${VLESS_LINK}${N}"
    show_qr "$VLESS_LINK"
    line
}

install_shortcut() {
    local SB_URL="https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh"
    local SRC=""
    [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]] && SRC=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ -n "$SRC" && -s "$SRC" ]]; then
        cp -f "$SRC" "${WORK_DIR}/manage.sh"
    else
        curl -fsSL "$SB_URL" -o "${WORK_DIR}/manage.sh" || err "Failed to download script"
    fi
    chmod +x "${WORK_DIR}/manage.sh"
    printf '#!/bin/bash\nbash /etc/sing-box/manage.sh menu\n' > "$SCRIPT_LINK"
    chmod +x "$SCRIPT_LINK"
    info "Shortcut installed: sb"
}

# ======================== Menu ========================

show_menu() {
    [[ $EUID -eq 0 ]] || err "Please run as root"
    [[ -f "$INFO_FILE" ]] && source "$INFO_FILE" || err "Not installed"

    # Auto-detect IP change
    local OLD_IP="$SERVER_IP"
    get_ip 2>/dev/null || true
    if [[ "$OLD_IP" != "$SERVER_IP" ]]; then
        warn "IP changed: ${OLD_IP} → ${SERVER_IP}"
        save_and_link; info "Link updated"
    fi

    local ST
    systemctl is-active --quiet sing-box 2>/dev/null && ST="${G}● Running${N}" || ST="${R}● Stopped${N}"

    clear
    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${W}║            sing-box Dashboard                       ║${N}"
    echo -e "${W}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${W}║${N}  Status: ${ST}          IP: ${C}${SERVER_IP}${N}"
    echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    echo -e "  ${W}1.${N} Show link & QR code"
    echo -e "  ${W}2.${N} Traffic stats"
    echo -e "  ${W}3.${N} Live logs"
    echo -e "  ${W}4.${N} Refresh IP"
    echo ""
    echo -e "  ${R}0.${N} Uninstall"
    echo ""
    read -rp "  Select [0-4]: " choice
    echo ""

    case "$choice" in
        1) show_link
           echo -e "  ${Y}Paste the link or scan QR code to import${N}\n" ;;
        2) command -v vnstat &>/dev/null || { warn "vnstat not installed"; return; }
           echo ""; vnstat; echo ""; vnstat -d 2>/dev/null | tail -n 15; echo "" ;;
        3) echo -e "  ${Y}Ctrl+C to exit${N}\n"; journalctl -u sing-box -f --no-pager -n 50 ;;
        4) local OLD_IP2="$SERVER_IP"; get_ip
           if [[ "$OLD_IP2" == "$SERVER_IP" ]]; then
               info "IP unchanged: ${SERVER_IP}"
           else
               save_and_link
               info "IP updated: ${OLD_IP2} → ${SERVER_IP}"
               show_link
           fi ;;
        0) read -rp "  Confirm uninstall? [y/N]: " yn
           [[ "$yn" == [yY] ]] || return
           systemctl stop sing-box 2>/dev/null || true
           systemctl disable sing-box 2>/dev/null || true
           rm -rf "$WORK_DIR" "$SERVICE_FILE" "$BIN_PATH" "$SCRIPT_LINK"
           systemctl daemon-reload
           info "Uninstalled" ;;
        *) warn "Invalid option" ;;
    esac
}

# ======================== Entry ========================

if [[ "${1:-}" == "menu" ]]; then show_menu; exit 0; fi
if [[ -f "$CONFIG_FILE" && -f "$INFO_FILE" && "${1:-}" != "install" ]]; then show_menu; exit 0; fi

# ======================== Fresh Install ========================

[[ $EUID -eq 0 ]] || err "Please run as root"

echo ""
echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${W}║  sing-box Installer — VLESS-Reality (TCP)           ║${N}"
echo -e "${W}║  No domain · No certificate · Zero config           ║${N}"
echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"

install_deps
get_ip
install_singbox
setup_config
enable_bbr
start_service
save_and_link
install_shortcut

echo ""
echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${W}║            ✓ Deployment Complete                     ║${N}"
echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
show_link
echo -e "  ${Y}Paste the link or scan QR code to import${N}"
echo -e "  ${Y}Type ${W}sb${Y} to open the dashboard${N}"
line
echo ""
