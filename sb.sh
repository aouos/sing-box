#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════
#  sing-box 一键部署 — VLESS-Reality(TCP) + Hysteria2(UDP 端口跳跃)
#  适用: Ubuntu 20+ / Debian 11+ / CentOS 8+ (x86_64 / arm64)
#  客户端: Shadowrocket (iOS) / v2rayNG (Android)
#
#  安装: bash <(curl -fsSL https://your-host/sb.sh)
#  管理: sb
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ======================== 全局常量 ========================
WORK_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
CONFIG_FILE="${WORK_DIR}/config.json"
INFO_FILE="${WORK_DIR}/info.dat"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SUB_DIR="${WORK_DIR}/sub"
SCRIPT_LINK="/usr/local/bin/sb"

# ======================== 颜色 ========================
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'
C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

info()    { echo -e "  ${G}✓${N} $*"; }
warn()    { echo -e "  ${Y}⚠${N} $*"; }
err()     { echo -e "  ${R}✗${N} $*"; exit 1; }
title()   { echo -e "\n${W}▶ $*${N}"; }
line()    { echo -e "${C}─────────────────────────────────────────────────${N}"; }

# ======================== 检测环境 ========================
check_root() { if [[ $EUID -ne 0 ]]; then err "请使用 root 运行"; fi; }

detect_arch() {
    case "$(uname -m)" in
        x86_64)  SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        armv7l)  SB_ARCH="armv7" ;;
        *)       err "不支持的架构: $(uname -m)" ;;
    esac
}

get_ip() {
    SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null \
             || curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null \
             || curl -4 -s --connect-timeout 5 https://ip.sb 2>/dev/null || echo "")
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org 2>/dev/null || echo "")
        if [[ -n "$SERVER_IP" ]]; then SERVER_IP="[$SERVER_IP]"; fi
    fi
    if [[ -z "$SERVER_IP" ]]; then err "无法获取公网 IP"; fi
}

random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! ss -tunlp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# ======================== 安装依赖 ========================
install_deps() {
    title "安装依赖"
    if command -v apt-get &>/dev/null; then
        apt-get update -y -qq >/dev/null 2>&1
        apt-get install -y -qq curl wget jq openssl tar gzip iptables python3 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget jq openssl tar gzip iptables python3 >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget jq openssl tar gzip iptables python3 >/dev/null 2>&1
    fi
    info "依赖就绪"
}

# ======================== 安装 sing-box ========================
install_singbox() {
    title "安装 sing-box"
    local VER
    VER=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    if [[ -z "$VER" || "$VER" == "null" ]]; then
        VER=$(curl -fsSL "https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box" 2>/dev/null \
              | grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+",' | head -1 | tr -d '",')
    fi
    if [[ -z "$VER" ]]; then err "获取版本号失败"; fi

    local URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz"
    local TMP="/tmp/sb-install-$$"
    mkdir -p "$TMP"
    info "下载 v${VER} ..."
    curl -fsSL "$URL" -o "${TMP}/sb.tar.gz" || err "下载失败"
    tar -xzf "${TMP}/sb.tar.gz" -C "$TMP"
    cp -f "$(find "$TMP" -name sing-box -type f | head -1)" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$TMP"
    info "sing-box v${VER} 安装完成"
}

# ======================== 生成凭证 ========================
generate_creds() {
    title "生成密钥与凭证"
    mkdir -p "$WORK_DIR" "$SUB_DIR" "${WORK_DIR}/cert"

    UUID=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local KP
    KP=$("$BIN_PATH" generate reality-keypair)
    PRIVATE_KEY=$(echo "$KP" | awk '/PrivateKey/{print $NF}')
    PUBLIC_KEY=$(echo "$KP" | awk '/PublicKey/{print $NF}')
    SHORT_ID=$(openssl rand -hex 8)
    HY2_PASS=$(openssl rand -base64 16)
    REALITY_SNI="www.microsoft.com"

    # 端口
    VLESS_PORT=$(random_port)
    HY2_PORT=$(random_port)
    SUB_PORT=$(random_port)
    SUB_TOKEN=$(openssl rand -hex 16)

    # Hysteria2 端口跳跃范围
    HY2_HOPPING_START=20000
    HY2_HOPPING_END=40000

    # 自签证书
    openssl ecparam -genkey -name prime256v1 -out "${WORK_DIR}/cert/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${WORK_DIR}/cert/key.pem" \
        -out "${WORK_DIR}/cert/cert.pem" -subj "/CN=bing.com" 2>/dev/null

    info "UUID: ${UUID}"
    info "VLESS 端口: ${VLESS_PORT} (TCP)"
    info "HY2 实际端口: ${HY2_PORT} (UDP), 跳跃范围: ${HY2_HOPPING_START}-${HY2_HOPPING_END}"
}

# ======================== 配置文件 ========================
generate_config() {
    title "生成配置"
    cat > "$CONFIG_FILE" << EOF
{
    "log": { "level": "info", "timestamp": true },
    "dns": {
        "servers": [
            { "type": "tls", "tag": "google", "server": "8.8.8.8" },
            { "type": "local", "tag": "local" }
        ]
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "::",
            "listen_port": ${VLESS_PORT},
            "users": [
                {
                    "name": "user",
                    "uuid": "${UUID}",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${REALITY_SNI}",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "${REALITY_SNI}",
                        "server_port": 443
                    },
                    "private_key": "${PRIVATE_KEY}",
                    "short_id": ["${SHORT_ID}"]
                }
            }
        },
        {
            "type": "hysteria2",
            "tag": "hy2",
            "listen": "::",
            "listen_port": ${HY2_PORT},
            "users": [
                {
                    "name": "user",
                    "password": "${HY2_PASS}"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "bing.com",
                "certificate_path": "${WORK_DIR}/cert/cert.pem",
                "key_path": "${WORK_DIR}/cert/key.pem"
            }
        }
    ],
    "outbounds": [
        { "type": "direct", "tag": "direct" }
    ],
    "route": {
        "default_domain_resolver": "local"
    }
}
EOF
    if "$BIN_PATH" check -c "$CONFIG_FILE" 2>/tmp/sb-check.log; then
        info "配置验证通过"
    else
        warn "配置验证失败:"
        cat /tmp/sb-check.log
        rm -f /tmp/sb-check.log
        err "请检查配置"
    fi
}

# ======================== 端口跳跃 ========================
setup_port_hopping() {
    title "配置 Hysteria2 端口跳跃"

    # 清理旧规则 (忽略报错)
    iptables  -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true

    # 新规则: UDP 20000-40000 → 实际 HY2 端口
    iptables  -t nat -A PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true
    ip6tables -t nat -A PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true

    # 持久化
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi

    # 开机恢复脚本
    write_hopping_script

    info "UDP ${HY2_HOPPING_START}-${HY2_HOPPING_END} → :${HY2_PORT} 端口跳跃已启用"
}

write_hopping_script() {
    cat > "${WORK_DIR}/port-hopping.sh" << HEOF
#!/bin/bash
# 端口跳跃 DNAT 规则
iptables  -t nat -C PREROUTING -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j DNAT --to-destination :${HY2_PORT} 2>/dev/null || \
iptables  -t nat -A PREROUTING -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j DNAT --to-destination :${HY2_PORT}
ip6tables -t nat -C PREROUTING -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j DNAT --to-destination :${HY2_PORT} 2>/dev/null || \
ip6tables -t nat -A PREROUTING -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j DNAT --to-destination :${HY2_PORT}

# 防火墙 INPUT 放行规则
iptables  -C INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT
ip6tables -C INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT
iptables  -C INPUT -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j ACCEPT 2>/dev/null || iptables  -I INPUT -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j ACCEPT
ip6tables -C INPUT -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j ACCEPT
iptables  -C INPUT -p udp --dport ${HY2_PORT} -j ACCEPT 2>/dev/null || iptables  -I INPUT -p udp --dport ${HY2_PORT} -j ACCEPT
ip6tables -C INPUT -p udp --dport ${HY2_PORT} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${HY2_PORT} -j ACCEPT
iptables  -C INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT
ip6tables -C INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport ${SUB_PORT} -j ACCEPT
HEOF
    chmod +x "${WORK_DIR}/port-hopping.sh"
}

# ======================== 防火墙 ========================
setup_firewall() {
    title "配置防火墙"
    local cmds=(
        "-I INPUT -p tcp --dport $VLESS_PORT -j ACCEPT"
        "-I INPUT -p udp --dport ${HY2_HOPPING_START}:${HY2_HOPPING_END} -j ACCEPT"
        "-I INPUT -p udp --dport $HY2_PORT -j ACCEPT"
        "-I INPUT -p tcp --dport $SUB_PORT -j ACCEPT"
    )
    for c in "${cmds[@]}"; do
        iptables  $c 2>/dev/null || true
        ip6tables $c 2>/dev/null || true
    done

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$VLESS_PORT"/tcp >/dev/null 2>&1 || true
        ufw allow "${HY2_HOPPING_START}:${HY2_HOPPING_END}"/udp >/dev/null 2>&1 || true
        ufw allow "$SUB_PORT"/tcp >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$VLESS_PORT"/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${HY2_HOPPING_START}-${HY2_HOPPING_END}"/udp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="$SUB_PORT"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    info "防火墙已配置"
}

# ======================== BBR ========================
enable_bbr() {
    title "开启 BBR"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        info "BBR 已启用"; return
    fi
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && info "BBR 已开启" || warn "BBR 开启失败"
}

# ======================== systemd ========================
create_service() {
    title "启动服务"
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=sing-box proxy service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=/etc/sing-box/port-hopping.sh
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
    systemctl is-active --quiet sing-box && info "sing-box 运行中" || err "启动失败 → journalctl -u sing-box"
}

# ======================== 生成链接 ========================
generate_links() {
    local IP="${SERVER_IP//[\[\]]/}"

    # VLESS-Reality (TCP)
    VLESS_LINK="vless://${UUID}@${IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"

    # Hysteria2 (UDP 端口跳跃)
    HY2_LINK="hysteria2://${HY2_PASS}@${IP}:${HY2_PORT}?sni=bing.com&insecure=1&mport=${HY2_HOPPING_START}-${HY2_HOPPING_END}#Hysteria2"

    echo "$VLESS_LINK" > "${SUB_DIR}/vless.txt"
    echo "$HY2_LINK"   > "${SUB_DIR}/hy2.txt"

    # 通用 Base64 订阅
    printf "%s\n%s" "$VLESS_LINK" "$HY2_LINK" | base64 -w 0 > "${SUB_DIR}/sub.txt"
}

# ======================== 订阅服务 ========================
setup_sub_server() {
    title "启动订阅服务"
    cat > "${WORK_DIR}/sub_server.py" << 'PYEOF'
#!/usr/bin/env python3
import http.server, sys, os
PORT, TOKEN, DIR = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == f"/{TOKEN}":
            fp = os.path.join(DIR, "sub.txt")
            if os.path.isfile(fp):
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Profile-Update-Interval", "6")
                self.send_header("Subscription-Userinfo",
                    "upload=0; download=0; total=107374182400; expire=0")
                self.end_headers()
                with open(fp, "rb") as f: self.wfile.write(f.read())
                return
        self.send_response(404); self.end_headers(); self.wfile.write(b"404")
http.server.HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF

    cat > /etc/systemd/system/sing-box-sub.service << SUBEOF
[Unit]
Description=sing-box subscription
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 ${WORK_DIR}/sub_server.py ${SUB_PORT} ${SUB_TOKEN} ${SUB_DIR}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
SUBEOF
    systemctl daemon-reload
    systemctl enable sing-box-sub --now >/dev/null 2>&1
    sleep 1
    systemctl is-active --quiet sing-box-sub && info "订阅服务端口: ${SUB_PORT}" || warn "订阅服务未启动"
}

# ======================== 保存配置 ========================
save_info() {
    cat > "$INFO_FILE" << EOF
UUID="${UUID}"
VLESS_PORT="${VLESS_PORT}"
HY2_PORT="${HY2_PORT}"
HY2_HOPPING_START="${HY2_HOPPING_START}"
HY2_HOPPING_END="${HY2_HOPPING_END}"
HY2_PASS="${HY2_PASS}"
PUBLIC_KEY="${PUBLIC_KEY}"
PRIVATE_KEY="${PRIVATE_KEY}"
SHORT_ID="${SHORT_ID}"
REALITY_SNI="${REALITY_SNI}"
SERVER_IP="${SERVER_IP}"
SUB_PORT="${SUB_PORT}"
SUB_TOKEN="${SUB_TOKEN}"
VLESS_LINK="${VLESS_LINK}"
HY2_LINK="${HY2_LINK}"
EOF
    chmod 600 "$INFO_FILE"
}

# ======================== 显示结果 ========================
show_result() {
    local IP="${SERVER_IP//[\[\]]/}"
    local SUB_URL="http://${IP}:${SUB_PORT}/${SUB_TOKEN}"

    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${W}║            ✓ 部署完成                                ║${N}"
    echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    line
    echo -e "  ${C}VLESS-Reality │ TCP${N}"
    line
    echo -e "  ${G}${VLESS_LINK}${N}"
    echo ""
    line
    echo -e "  ${C}Hysteria2 │ UDP 端口跳跃 ${HY2_HOPPING_START}-${HY2_HOPPING_END}${N}"
    line
    echo -e "  ${G}${HY2_LINK}${N}"
    echo ""
    line
    echo -e "  ${C}通用订阅 │ Shadowrocket / v2rayNG${N}"
    line
    echo -e "  ${G}${SUB_URL}${N}"
    echo ""
    line
    echo -e "  ${Y}输入 ${W}sb${Y} 进入管理菜单${N}"
    line
    echo ""
}

# ================================================================
#                       管理菜单
# ================================================================

load_info() { if [[ -f "$INFO_FILE" ]]; then source "$INFO_FILE"; fi; }

# 检测 IP 变化并自动更新链接
check_ip_change() {
    local OLD_IP="$SERVER_IP"
    local NEW_IP
    NEW_IP=$(curl -4 -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$NEW_IP" ]]; then
        NEW_IP=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")
        if [[ -n "$NEW_IP" ]]; then NEW_IP="[$NEW_IP]"; fi
    fi
    if [[ -z "$NEW_IP" ]]; then return; fi

    local OLD_CLEAN="${OLD_IP//[\[\]]/}"
    local NEW_CLEAN="${NEW_IP//[\[\]]/}"
    if [[ "$OLD_CLEAN" != "$NEW_CLEAN" ]]; then
        warn "检测到 IP 变化: ${OLD_CLEAN} → ${NEW_CLEAN}"
        SERVER_IP="$NEW_IP"
        generate_links
        save_info
        systemctl restart sing-box-sub 2>/dev/null || true
        info "链接和订阅已自动更新"
    fi
}

show_menu() {
    load_info
    check_ip_change
    local IP="${SERVER_IP//[\[\]]/}"
    local SB_VER=$("$BIN_PATH" version 2>/dev/null | awk '/version/{print $NF}' || echo "?")
    local ST
    systemctl is-active --quiet sing-box 2>/dev/null && ST="${G}● 运行中${N}" || ST="${R}● 已停止${N}"

    clear
    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${W}║            sing-box 管理面板                        ║${N}"
    echo -e "${W}╠══════════════════════════════════════════════════════╣${N}"
    echo -e "${W}║${N}  内核: ${C}v${SB_VER}${N}          状态: ${ST}            ${W}║${N}"
    echo -e "${W}║${N}  IP:   ${C}${SERVER_IP}${N}"
    echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    echo -e "  ${W}1.${N} 查看节点链接"
    echo -e "  ${W}2.${N} 查看订阅地址"
    echo -e "  ${W}3.${N} 重新生成 UUID"
    echo -e "  ${W}4.${N} 修改 VLESS 端口"
    echo -e "  ${W}5.${N} 修改 HY2 端口 & 跳跃范围"
    echo -e "  ${W}6.${N} 修改 Reality 伪装域名"
    echo -e "  ${W}7.${N} 更新 sing-box 内核"
    echo -e "  ${W}8.${N} 重启服务"
    echo -e "  ${W}9.${N} 查看实时日志"
    echo -e "  ${W}10.${N} 服务状态详情"
    echo -e "  ${W}11.${N} 刷新 IP 并更新链接"
    echo ""
    echo -e "  ${R}0.${N} 卸载"
    echo ""
    read -rp "  请选择 [0-11]: " choice
    echo ""

    case "$choice" in
        1)  cmd_links ;;
        2)  cmd_sub ;;
        3)  cmd_regen_uuid ;;
        4)  cmd_vless_port ;;
        5)  cmd_hy2_port ;;
        6)  cmd_sni ;;
        7)  cmd_update ;;
        8)  cmd_restart ;;
        9)  cmd_log ;;
        10) cmd_status ;;
        11) cmd_refresh_ip ;;
        0)  cmd_uninstall ;;
        *)  warn "无效选项" ;;
    esac
}

cmd_links() {
    load_info
    echo ""
    line
    echo -e "  ${C}VLESS-Reality (TCP)${N}"
    line
    echo ""
    echo -e "  ${G}${VLESS_LINK}${N}"
    echo ""
    line
    echo -e "  ${C}Hysteria2 (UDP 端口跳跃)${N}"
    line
    echo ""
    echo -e "  ${G}${HY2_LINK}${N}"
    echo ""
}

cmd_sub() {
    load_info
    local IP="${SERVER_IP//[\[\]]/}"
    echo ""
    line
    echo -e "  ${C}通用订阅地址 (Shadowrocket / v2rayNG)${N}"
    line
    echo ""
    echo -e "  ${G}http://${IP}:${SUB_PORT}/${SUB_TOKEN}${N}"
    echo ""
    echo -e "  ${Y}Shadowrocket: 首页 → 右上角 + → 类型选「Subscribe」→ 粘贴地址${N}"
    echo -e "  ${Y}v2rayNG: 左上角 ≡ → 订阅分组设置 → 右上角 + → 粘贴地址${N}"
    echo ""
}

cmd_regen_uuid() {
    load_info
    local NEW_UUID
    NEW_UUID=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    jq --arg u "$NEW_UUID" \
        '(.inbounds[] | select(.tag=="vless-reality") | .users[0].uuid) = $u' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    UUID="$NEW_UUID"
    get_ip
    generate_links
    save_info
    systemctl restart sing-box sing-box-sub 2>/dev/null || true

    info "UUID 已更新: ${NEW_UUID}"
    echo ""
    cmd_links
}

cmd_vless_port() {
    load_info
    read -rp "  输入新端口 (当前 ${VLESS_PORT}): " np
    if [[ -z "$np" ]]; then return; fi
    if ss -tunlp 2>/dev/null | grep -q ":${np} "; then warn "端口 $np 被占用"; return; fi

    jq --argjson p "$np" \
        '(.inbounds[] | select(.tag=="vless-reality") | .listen_port) = $p' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    iptables -I INPUT -p tcp --dport "$np" -j ACCEPT 2>/dev/null || true
    VLESS_PORT="$np"
    get_ip; generate_links; save_info
    systemctl restart sing-box sing-box-sub 2>/dev/null || true
    info "VLESS 端口 → ${np}"
    cmd_links
}

cmd_hy2_port() {
    load_info
    read -rp "  HY2 监听端口 (当前 ${HY2_PORT}): " np
    read -rp "  跳跃起始 (当前 ${HY2_HOPPING_START}): " ns
    read -rp "  跳跃结束 (当前 ${HY2_HOPPING_END}): " ne
    np=${np:-$HY2_PORT}; ns=${ns:-$HY2_HOPPING_START}; ne=${ne:-$HY2_HOPPING_END}

    jq --argjson p "$np" \
        '(.inbounds[] | select(.tag=="hy2") | .listen_port) = $p' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 删旧规则
    iptables  -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START}:${HY2_HOPPING_END}" -j DNAT --to-destination ":${HY2_PORT}" 2>/dev/null || true

    HY2_PORT="$np"; HY2_HOPPING_START="$ns"; HY2_HOPPING_END="$ne"

    # 加新规则
    iptables  -t nat -A PREROUTING -p udp --dport "${ns}:${ne}" -j DNAT --to-destination ":${np}" 2>/dev/null || true
    ip6tables -t nat -A PREROUTING -p udp --dport "${ns}:${ne}" -j DNAT --to-destination ":${np}" 2>/dev/null || true
    iptables  -I INPUT -p udp --dport "${ns}:${ne}" -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p udp --dport "${ns}:${ne}" -j ACCEPT 2>/dev/null || true

    write_hopping_script
    get_ip; generate_links; save_info
    systemctl restart sing-box sing-box-sub 2>/dev/null || true
    info "HY2 端口: ${np}, 跳跃: ${ns}-${ne}"
    cmd_links
}

cmd_sni() {
    load_info
    echo -e "  ${Y}常用伪装域名: www.microsoft.com  www.apple.com  www.amazon.com  www.cloudflare.com${N}"
    read -rp "  新伪装域名 (当前 ${REALITY_SNI}): " ns
    if [[ -z "$ns" ]]; then return; fi

    jq --arg s "$ns" '
        (.inbounds[] | select(.tag=="vless-reality") | .tls.server_name) = $s |
        (.inbounds[] | select(.tag=="vless-reality") | .tls.reality.handshake.server) = $s
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    REALITY_SNI="$ns"
    get_ip; generate_links; save_info
    systemctl restart sing-box sing-box-sub 2>/dev/null || true
    info "SNI → ${ns}"
    cmd_links
}

cmd_update() {
    detect_arch
    install_singbox
    systemctl restart sing-box
    info "内核已更新"
}

cmd_refresh_ip() {
    load_info
    local OLD_IP="${SERVER_IP//[\[\]]/}"
    get_ip
    local NEW_IP="${SERVER_IP//[\[\]]/}"
    if [[ "$OLD_IP" == "$NEW_IP" ]]; then
        info "IP 未变化: ${NEW_IP}"
        return
    fi
    generate_links
    save_info
    systemctl restart sing-box-sub 2>/dev/null || true
    info "IP 已更新: ${OLD_IP} → ${NEW_IP}"
    echo ""
    cmd_links
}

cmd_restart() {
    systemctl restart sing-box sing-box-sub 2>/dev/null || true
    sleep 1
    systemctl is-active --quiet sing-box && info "服务已重启" || warn "重启异常"
}

cmd_log() {
    echo -e "  ${Y}Ctrl+C 退出${N}\n"
    journalctl -u sing-box -f --no-pager -n 50
}

cmd_status() {
    echo ""
    systemctl status sing-box --no-pager 2>/dev/null
    echo ""
    systemctl status sing-box-sub --no-pager 2>/dev/null
    echo ""
}

cmd_uninstall() {
    read -rp "  确认卸载? [y/N]: " yn
    if [[ "$yn" != [yY] ]]; then return; fi

    load_info
    iptables  -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START:-20000}:${HY2_HOPPING_END:-40000}" \
        -j DNAT --to-destination ":${HY2_PORT:-0}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_HOPPING_START:-20000}:${HY2_HOPPING_END:-40000}" \
        -j DNAT --to-destination ":${HY2_PORT:-0}" 2>/dev/null || true

    systemctl stop sing-box sing-box-sub 2>/dev/null || true
    systemctl disable sing-box sing-box-sub 2>/dev/null || true
    rm -rf "$WORK_DIR" "$SERVICE_FILE" /etc/systemd/system/sing-box-sub.service
    rm -f "$BIN_PATH" "$SCRIPT_LINK"
    systemctl daemon-reload
    info "卸载完成"
}

# ======================== sb 快捷命令 ========================
install_shortcut() {
    # bash <(curl ...) 时 $0 是临时管道, 无法复制, 改为从 GitHub 下载
    local SB_URL="https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh"
    if [[ -f "$0" ]]; then
        cp -f "$0" "${WORK_DIR}/manage.sh"
    else
        curl -fsSL "$SB_URL" -o "${WORK_DIR}/manage.sh" || cp -f "$0" "${WORK_DIR}/manage.sh" 2>/dev/null || true
    fi
    chmod +x "${WORK_DIR}/manage.sh"

    cat > "$SCRIPT_LINK" << 'SBEOF'
#!/bin/bash
bash /etc/sing-box/manage.sh menu
SBEOF
    chmod +x "$SCRIPT_LINK"
    info "管理命令已安装: sb"
}

# ================================================================
#                         入口
# ================================================================

if [[ "${1:-}" == "menu" ]]; then
    show_menu
    exit 0
fi

if [[ -f "$CONFIG_FILE" && -f "$INFO_FILE" && "${1:-}" != "install" ]]; then
    show_menu
    exit 0
fi

# ====================== 全新安装 ======================
main() {
    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${W}║  sing-box 一键部署                                  ║${N}"
    echo -e "${W}║  VLESS-Reality (TCP) + Hysteria2 (UDP 端口跳跃)     ║${N}"
    echo -e "${W}║  无需域名 · 无需证书 · 零配置                       ║${N}"
    echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
    echo ""

    check_root
    detect_arch
    install_deps
    get_ip
    install_singbox
    generate_creds
    generate_config
    setup_port_hopping
    setup_firewall
    enable_bbr
    create_service
    generate_links
    setup_sub_server
    save_info
    install_shortcut
    show_result
}

main
