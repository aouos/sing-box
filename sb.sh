#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════
#  sing-box 一键部署 — VLESS-Reality(TCP) + Hysteria2(UDP)
#  适用: Ubuntu 20+ / Debian 11+ / CentOS 8+ (x86_64 / arm64)
#  客户端: Shadowrocket / v2rayNG / sing-box (全平台)
#
#  安装: bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
#  管理: sb
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ======================== 全局常量 ========================
WORK_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
CONFIG_FILE="${WORK_DIR}/config.json"
INFO_FILE="${WORK_DIR}/info.dat"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SCRIPT_LINK="/usr/local/bin/sb"

# ======================== 颜色 ========================
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

info()    { echo -e "  ${G}✓${N} $*"; }
warn()    { echo -e "  ${Y}⚠${N} $*"; }
err()     { echo -e "  ${R}✗${N} $*"; exit 1; }
title()   { echo -e "\n${W}▶ $*${N}"; }
line()    { echo -e "${C}─────────────────────────────────────────────────${N}"; }

# ======================== 工具函数 ========================
check_root() { [[ $EUID -eq 0 ]] || err "请使用 root 运行"; }

valid_port() {
    local p=$1
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

valid_host() {
    local h=$1
    (( ${#h} <= 253 )) || return 1
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

jq_edit() {
    # 首次修改前留一份备份, 由 apply_change 决定提交或回滚
    [[ -f "${CONFIG_FILE}.bak" ]] || cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    local filter=$1; shift
    jq "$@" "$filter" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        armv7l)  SB_ARCH="armv7" ;;
        *)       err "不支持的架构: $(uname -m)" ;;
    esac
}

fetch_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me https://ip.sb; do
        ip=$(curl -4 -s --connect-timeout 5 "$url" 2>/dev/null || true)
        [[ -n "$ip" ]] && { echo "$ip"; return; }
    done
}

get_ip() {
    SERVER_IP=$(fetch_ip)
    [[ -n "$SERVER_IP" ]] || err "无法获取公网 IPv4"
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

show_qr() {
    command -v qrencode &>/dev/null || return 0
    qrencode -t ANSIUTF8 -m 2 "$1" 2>/dev/null || true
}

firewall_open() {
    local proto=$1 port=$2
    iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

firewall_close() {
    local proto=$1 port=$2
    [[ -z "$port" || "$port" == "0" ]] && return 0
    iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    if command -v ufw &>/dev/null; then
        ufw --force delete allow "${port}/${proto}" </dev/null >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ======================== 安装依赖 ========================
install_deps() {
    title "安装依赖"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl wget jq openssl tar gzip iptables iproute2 qrencode vnstat >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q epel-release >/dev/null 2>&1 || true
        dnf install -y -q curl wget jq openssl tar gzip iptables iproute qrencode vnstat >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q epel-release >/dev/null 2>&1 || true
        yum install -y -q curl wget jq openssl tar gzip iptables iproute qrencode vnstat >/dev/null 2>&1
    fi
    systemctl enable --now vnstat >/dev/null 2>&1 || true
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
    mkdir -p "${WORK_DIR}/cert"

    UUID=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local KP
    KP=$("$BIN_PATH" generate reality-keypair)
    PRIVATE_KEY=$(echo "$KP" | awk '/PrivateKey/{print $NF}')
    PUBLIC_KEY=$(echo "$KP" | awk '/PublicKey/{print $NF}')
    SHORT_ID=$(openssl rand -hex 8)
    HY2_PASS=$(openssl rand -hex 16)
    REALITY_SNI="www.icloud.com"

    VLESS_PORT=$(random_port)
    HY2_PORT=$(random_port)

    # 自签证书
    openssl ecparam -genkey -name prime256v1 -out "${WORK_DIR}/cert/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${WORK_DIR}/cert/key.pem" \
        -out "${WORK_DIR}/cert/cert.pem" -subj "/CN=bing.com" 2>/dev/null

    info "UUID: ${UUID}"
    info "VLESS 端口: ${VLESS_PORT} (TCP)"
    info "HY2 端口: ${HY2_PORT} (UDP)"
}

# ======================== 配置文件 ========================
generate_config() {
    title "生成配置"
    cat > "$CONFIG_FILE" << EOF
{
    "log": { "level": "info", "timestamp": true },
    "dns": {
        "servers": [
            { "type": "local", "tag": "local" }
        ]
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "0.0.0.0",
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
            "listen": "0.0.0.0",
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

# ======================== 防火墙 ========================
setup_firewall() {
    title "配置防火墙"
    firewall_open tcp "$VLESS_PORT"
    firewall_open udp "$HY2_PORT"
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
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"
    HY2_LINK="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=bing.com&insecure=1#Hysteria2"
}

# ======================== 保存配置 ========================
save_info() {
    # 所有值使用 printf %q 做 shell 转义, 防止 source 时执行任意命令
    {
        printf 'UUID=%q\n'        "$UUID"
        printf 'VLESS_PORT=%q\n'  "$VLESS_PORT"
        printf 'HY2_PORT=%q\n'    "$HY2_PORT"
        printf 'HY2_PASS=%q\n'    "$HY2_PASS"
        printf 'PUBLIC_KEY=%q\n'  "$PUBLIC_KEY"
        printf 'PRIVATE_KEY=%q\n' "$PRIVATE_KEY"
        printf 'SHORT_ID=%q\n'    "$SHORT_ID"
        printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
        printf 'SERVER_IP=%q\n'   "$SERVER_IP"
        printf 'VLESS_LINK=%q\n'  "$VLESS_LINK"
        printf 'HY2_LINK=%q\n'    "$HY2_LINK"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ======================== 显示结果 ========================
show_result() {
    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${W}║            ✓ 部署完成                                ║${N}"
    echo -e "${W}╚══════════════════════════════════════════════════════╝${N}"
    echo ""
    line
    echo -e "  ${C}VLESS-Reality │ TCP${N}"
    line
    echo -e "  ${G}${VLESS_LINK}${N}"
    show_qr "$VLESS_LINK"
    line
    echo -e "  ${C}Hysteria2 │ UDP${N}"
    line
    echo -e "  ${G}${HY2_LINK}${N}"
    show_qr "$HY2_LINK"
    line
    echo -e "  ${Y}Shadowrocket / v2rayNG / sing-box 均支持直接粘贴或扫码导入${N}"
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
    local NEW
    NEW=$(fetch_ip)
    [[ -z "$NEW" ]] && return
    if [[ "$SERVER_IP" != "$NEW" ]]; then
        warn "检测到 IP 变化: ${SERVER_IP} → ${NEW}"
        SERVER_IP="$NEW"
        generate_links
        save_info
        info "链接已自动更新"
    fi
}

show_menu() {
    check_root
    load_info
    check_ip_change
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
    echo -e "  ${W}2.${N} 重新生成 UUID"
    echo -e "  ${W}3.${N} 修改 VLESS 端口"
    echo -e "  ${W}4.${N} 修改 HY2 端口"
    echo -e "  ${W}5.${N} 修改 Reality 伪装域名"
    echo -e "  ${W}6.${N} 重启服务"
    echo -e "  ${W}7.${N} 刷新 IP 并更新链接"
    echo -e "  ${W}8.${N} 流量统计 (vnstat)"
    echo -e "  ${W}9.${N} 查看实时日志"
    echo -e "  ${W}10.${N} 服务状态详情"
    echo ""
    echo -e "  ${R}0.${N} 卸载"
    echo ""
    read -rp "  请选择 [0-10]: " choice
    echo ""

    case "$choice" in
        1)  cmd_links ;;
        2)  cmd_regen_uuid ;;
        3)  cmd_vless_port ;;
        4)  cmd_hy2_port ;;
        5)  cmd_sni ;;
        6)  cmd_restart ;;
        7)  cmd_refresh_ip ;;
        8)  cmd_traffic ;;
        9)  cmd_log ;;
        10) cmd_status ;;
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
    echo -e "  ${G}${VLESS_LINK}${N}"
    show_qr "$VLESS_LINK"
    line
    echo -e "  ${C}Hysteria2 (UDP)${N}"
    line
    echo -e "  ${G}${HY2_LINK}${N}"
    show_qr "$HY2_LINK"
    echo -e "  ${Y}Shadowrocket / v2rayNG / sing-box 可直接粘贴或扫码导入${N}"
    echo ""
}

rollback_config() {
    [[ -f "${CONFIG_FILE}.bak" ]] || return 1
    mv -f "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    systemctl restart sing-box 2>/dev/null || true
    sleep 1
    systemctl is-active --quiet sing-box \
        && info "已回滚到旧配置" \
        || warn "回滚后仍异常, 查看: journalctl -u sing-box -n 50"
}

apply_change() {
    # 先用 sing-box check 校验新配置, 失败直接回滚不重启
    if ! "$BIN_PATH" check -c "$CONFIG_FILE" 2>/tmp/sb-check.log; then
        warn "配置校验失败, 正在回滚:"
        sed 's/^/    /' /tmp/sb-check.log
        rm -f /tmp/sb-check.log
        rollback_config
        return 1
    fi
    rm -f /tmp/sb-check.log
    get_ip; generate_links; save_info
    if systemctl restart sing-box 2>/dev/null; then
        sleep 1
        if systemctl is-active --quiet sing-box; then
            rm -f "${CONFIG_FILE}.bak"
            return 0
        fi
    fi
    warn "服务启动失败, 正在回滚配置"
    rollback_config
    generate_links; save_info
    return 1
}

cmd_regen_uuid() {
    load_info
    local NEW
    NEW=$("$BIN_PATH" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    jq_edit '(.inbounds[] | select(.tag=="vless-reality") | .users[0].uuid) = $u' --arg u "$NEW"
    UUID="$NEW"
    if apply_change; then
        info "UUID 已更新: ${NEW}"
        cmd_links
    fi
}

change_port() {
    local tag=$1 proto=$2 cur_var=$3
    local cur="${!cur_var}" np
    read -rp "  输入新端口 (当前 ${cur}): " np
    [[ -z "$np" ]] && return
    valid_port "$np" || { warn "端口无效 (1-65535)"; return; }
    ss -tunlp 2>/dev/null | grep -q ":${np} " && { warn "端口 $np 被占用"; return; }

    jq_edit "(.inbounds[] | select(.tag==\"$tag\") | .listen_port) = \$p" --argjson p "$np"
    printf -v "$cur_var" '%s' "$np"
    if apply_change; then
        # 服务成功切到新端口后再动防火墙: 先开新, 再删旧
        firewall_open  "$proto" "$np"
        firewall_close "$proto" "$cur"
        info "端口 → ${np}"
        cmd_links
    else
        # 回滚: 变量恢复成旧端口
        printf -v "$cur_var" '%s' "$cur"
    fi
}

cmd_vless_port() { load_info; change_port vless-reality tcp VLESS_PORT; }
cmd_hy2_port()   { load_info; change_port hy2          udp HY2_PORT;   }

cmd_sni() {
    load_info
    echo -e "  ${Y}常用伪装域名: www.icloud.com  www.yahoo.com  www.apple.com  addons.mozilla.org${N}"
    read -rp "  新伪装域名 (当前 ${REALITY_SNI}): " ns
    [[ -z "$ns" ]] && return
    valid_host "$ns" || { warn "域名格式非法"; return; }

    jq_edit '
        (.inbounds[] | select(.tag=="vless-reality") | .tls.server_name) = $s |
        (.inbounds[] | select(.tag=="vless-reality") | .tls.reality.handshake.server) = $s
    ' --arg s "$ns"
    REALITY_SNI="$ns"
    if apply_change; then
        info "SNI → ${ns}"
        cmd_links
    fi
}

cmd_traffic() {
    command -v vnstat &>/dev/null || { warn "vnstat 未安装"; return; }
    echo ""
    vnstat
    echo ""
    vnstat -d 2>/dev/null | tail -n 15
    echo ""
}

cmd_refresh_ip() {
    load_info
    local OLD_IP="$SERVER_IP"
    get_ip
    if [[ "$OLD_IP" == "$SERVER_IP" ]]; then
        info "IP 未变化: ${SERVER_IP}"
        return
    fi
    generate_links
    save_info
    info "IP 已更新: ${OLD_IP} → ${SERVER_IP}"
    echo ""
    cmd_links
}

cmd_restart() {
    systemctl restart sing-box 2>/dev/null || true
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
}

cmd_uninstall() {
    read -rp "  确认卸载? [y/N]: " yn
    [[ "$yn" == [yY] ]] || return

    load_info
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true

    firewall_close tcp "${VLESS_PORT:-}"
    firewall_close udp "${HY2_PORT:-}"

    rm -rf "$WORK_DIR" "$SERVICE_FILE"
    rm -f "$BIN_PATH" "$SCRIPT_LINK"
    systemctl daemon-reload
    info "卸载完成"
}

# ======================== sb 快捷命令 ========================
install_shortcut() {
    # bash <(curl ...) 时 $0 是 /dev/fd/63 已被消费完, 这种情况下从 GitHub 重新下载
    local SB_URL="https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh"
    local SRC=""
    if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then
        SRC=$(readlink -f "$0" 2>/dev/null || echo "$0")
    fi
    if [[ -n "$SRC" && -s "$SRC" ]]; then
        cp -f "$SRC" "${WORK_DIR}/manage.sh"
    else
        curl -fsSL "$SB_URL" -o "${WORK_DIR}/manage.sh" \
            || err "无法获取脚本本体, 请手动下载到 ${WORK_DIR}/manage.sh"
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
    echo -e "${W}║  VLESS-Reality (TCP) + Hysteria2 (UDP)              ║${N}"
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
    setup_firewall
    enable_bbr
    create_service
    generate_links
    save_info
    install_shortcut
    show_result
}

main
