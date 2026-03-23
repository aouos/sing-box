# sing-box 一键部署

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](sb.sh)

一键部署 [sing-box](https://github.com/SagerNet/sing-box) 代理服务，集成 VLESS-Reality (TCP) + Hysteria2 (UDP 端口跳跃)，无需域名、无需证书、零交互。

## 特性

- 🚀 **双协议互补** — VLESS-Reality (TCP 稳) + Hysteria2 (UDP 快)
- 🔒 **Reality 指纹伪装** — 抗主动探测，无需真实域名和证书
- 🔀 **Hysteria2 端口跳跃** — UDP 流量分散到 2 万个端口，抗封锁
- 📡 **内置订阅服务** — Base64 通用订阅，Shadowrocket / v2rayNG 一键导入
- 🔄 **重启自恢复** — systemd 管理 + iptables 规则开机自动恢复
- 🌐 **IP 变化自适应** — 打开管理菜单自动检测 IP 变化并更新链接
- 🛠️ **交互式管理** — `sb` 命令一站式管理所有配置

## 环境要求

| 项目 | 要求 |
|:---|:---|
| 系统 | Ubuntu 20+ / Debian 11+ / CentOS 8+ / AlmaLinux / Rocky Linux |
| 架构 | x86_64 / ARM64 |
| 权限 | root |
| 网络 | 海外 VPS，可访问 GitHub |

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
```

安装完成后终端会输出 VLESS、Hysteria2 节点链接和通用订阅地址，复制到客户端即可使用。

后续管理：

```bash
sb
```

## 管理菜单

```
 1. 查看节点链接          7. 更新 sing-box 内核
 2. 查看订阅地址          8. 重启服务
 3. 重新生成 UUID         9. 查看实时日志
 4. 修改 VLESS 端口      10. 服务状态详情
 5. 修改 HY2 端口/跳跃   11. 刷新 IP 并更新链接
 6. 修改 Reality 域名     0. 卸载
```

### 端口跳跃

通过 iptables NAT 将 UDP 20000-40000 范围的流量转发到 Hysteria2 实际监听端口，客户端每次连接随机选择端口，分散流量特征。可通过 `sb` 菜单选 5 自定义跳跃范围。

### 重启恢复

| 组件 | 恢复方式 |
|:---|:---|
| sing-box / 订阅服务 | systemd 自动拉起 |
| iptables 规则 | `ExecStartPre` 脚本恢复 |
| BBR | 写入 `sysctl.conf`，永久生效 |

## 文件结构

```
/etc/sing-box/
├── config.json          主配置
├── info.dat             安装参数存档
├── manage.sh            管理脚本
├── port-hopping.sh      iptables 恢复脚本
├── sub_server.py        订阅 HTTP 服务
├── cert/                HY2 自签证书
└── sub/                 分享链接 & 订阅文件

/usr/local/bin/sing-box   sing-box 二进制
/usr/local/bin/sb         管理快捷命令
```

## 常见问题

<details>
<summary><b>连不上节点？</b></summary>

1. 检查云厂商安全组是否放行了对应端口
2. 用 [tcp.ping.pe](https://tcp.ping.pe) 测试 IP 连通性
3. `sb` 选 10 确认服务运行状态
4. 尝试更换端口（选 4/5）
</details>

<details>
<summary><b>VPS 重启后还能用吗？</b></summary>

能。所有服务和 iptables 规则均会自动恢复，无需手动操作。
</details>

<details>
<summary><b>IP 变了怎么办？</b></summary>

运行 `sb` 打开管理菜单时会自动检测并更新，也可以手动选 11 刷新。客户端刷新订阅即可获取新链接。
</details>

<details>
<summary><b>如何完全卸载？</b></summary>

运行 `sb` 选 0，会清除所有文件、服务和 iptables 规则。
</details>

<details>
<summary><b>不需要订阅服务，想节省内存？</b></summary>

订阅服务常驻约 10MB 内存，个人使用可以关掉，直接复制节点链接到客户端即可：

```bash
# 停止并禁用
systemctl stop sing-box-sub
systemctl disable sing-box-sub

# 以后想重新开启
systemctl enable sing-box-sub --now
```
</details>

<details>
<summary><b>小内存 VPS（512MB）建议开启 swap</b></summary>

sing-box 只占约 45MB 内存，512MB VPS 完全够用。但建议加一个 swap 作为安全网，防止极端情况下 OOM：

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