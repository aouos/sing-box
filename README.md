# sing-box 一键部署

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](sb.sh)

一键部署 [sing-box](https://github.com/SagerNet/sing-box) 代理服务 — VLESS-Reality (TCP)，无需域名、无需证书、零交互。

## 特性

- 🔒 **Reality 指纹伪装** — 无需真实域名，TLS 握手直接复用目标站点指纹
- 📱 **链接 + 二维码** — 安装完成即输出节点链接与终端二维码，Shadowrocket / v2rayNG / sing-box 扫码即用
- 📊 **内置流量统计** — 集成 `vnstat`，`sb` 菜单直接查看
- ⚡ **自动开启 BBR** — TCP 拥塞控制优化

## 环境要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Ubuntu 20+ / Debian 11+ |
| 架构 | x86_64 / ARM64 |
| 权限 | root |
| 网络 | 海外 VPS，可访问 GitHub |

## 快速开始

先更新系统：

```bash
apt update && apt upgrade -y
```

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
```

安装完成后终端会输出 VLESS-Reality 节点链接和二维码，复制或扫码导入客户端即可。

> ⚠️ 需要在云服务商控制台（安全组 / 防火墙规则）放行脚本输出的 TCP 端口。

后续管理：

```bash
sb
```

## 管理菜单

```
1. Show link & QR code
2. Traffic stats
3. Live logs
4. Refresh IP
0. Uninstall
```

## 文件结构

```
/etc/sing-box/
├── config.json          主配置
├── info.dat             安装参数存档
├── manage.sh            管理脚本

/usr/local/bin/sing-box   sing-box 二进制
/usr/local/bin/sb         管理快捷命令
```

## 常见问题

<details>
<summary><b>连不上节点？</b></summary>

1. 检查云厂商安全组 / 防火墙规则是否放行了脚本输出的 TCP 端口
2. 用 [tcp.ping.pe](https://tcp.ping.pe) 测试 IP + 端口连通性
3. `sb` 选 3 查看实时日志排查
</details>

<details>
<summary><b>VPS 重启后还能用吗？</b></summary>

能。`sing-box` 由 `systemd` 自动拉起，BBR 和流量统计也会保留。
</details>

<details>
<summary><b>IP 变了怎么办？</b></summary>

运行 `sb` 打开管理菜单时会自动检测并更新链接，重新扫码导入即可。
</details>

<details>
<summary><b>如何更新 sing-box？</b></summary>

卸载后重装即可拿到最新版：

```bash
sb         # 选 0 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
```
</details>

<details>
<summary><b>小内存 VPS（512MB）建议开启 swap</b></summary>

`sing-box` 本身占用不高，512MB VPS 也能跑。但建议加一个 swap 作为安全网，防止极端情况下 OOM：

```bash
fallocate -l 256M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```
</details>

<details>
<summary><b>Ubuntu 内存优化：关闭 snapd</b></summary>

snapd 在 VPS 上完全用不到，常驻占 40-60MB 内存。关掉后 512MB 机器可用内存能从 ~190MB 提升到 ~200MB+：

```bash
systemctl stop snapd snapd.socket
systemctl disable snapd snapd.socket
apt purge -y snapd
```
</details>

## License

[MIT](LICENSE)
