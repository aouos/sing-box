# sing-box 一键部署

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](sb.sh)

一键部署 [sing-box](https://github.com/SagerNet/sing-box) 代理服务，集成 VLESS-Reality (TCP) + Hysteria2 (UDP)，无需域名、无需手动申请证书、零交互。

## 特性

- 🚀 **双协议互补** — VLESS-Reality (TCP 稳) + Hysteria2 (UDP 快)
- 🔒 **Reality 指纹伪装** — 无需真实域名，默认使用 `www.icloud.com` 作为伪装握手域名
- 📱 **链接 + 二维码导入** — 安装完成后直接输出两条节点链接，并生成终端二维码
- 🔥 **自动放行防火墙** — 自动处理 `iptables` / `ufw` / `firewalld`
- 🌐 **IP 变化自适应** — 打开管理菜单自动检测 IP 变化并更新节点链接
- 📊 **内置流量统计** — 集成 `vnstat`，可直接在菜单查看流量数据
- 🛠️ **交互式管理** — `sb` 命令统一管理端口、UUID、SNI 和卸载
- 🛡️ **改配置带回滚** — 修改任何参数前先 `sing-box check`，启动失败自动回滚到旧配置

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

安装完成后终端会输出 VLESS、Hysteria2 节点链接和二维码，复制或扫码导入客户端即可使用。

后续管理：

```bash
sb
```

## 管理菜单

```
1.  查看节点链接
2.  重新生成 UUID
3.  修改 VLESS 端口
4.  修改 HY2 端口
5.  修改 Reality 伪装域名
6.  重启服务
7.  刷新 IP 并更新链接
8.  流量统计 (vnstat)
9.  查看实时日志
10. 服务状态详情
0.  卸载
```

任意改动（UUID / 端口 / SNI）都会先经过 `sing-box check` 校验配置；启动失败会自动回滚到旧配置，服务不会被一次错误输入带挂。

### 导入方式

- Shadowrocket：直接粘贴链接，或扫描终端输出的二维码
- v2rayNG：手动添加节点，或扫描二维码导入
- sing-box 客户端：支持直接粘贴 `vless://` / `hysteria2://` 链接

### 重启恢复

| 组件 | 恢复方式 |
|:---|:---|
| sing-box | systemd 自动拉起 |
| 防火墙放行 | 安装时写入 `iptables` / `ufw` / `firewalld` |
| BBR | 写入 `sysctl.conf`，永久生效 |
| 流量统计 | `vnstat` 后台服务持续记录 |

### 防火墙说明

- 脚本只能处理服务器系统内部的防火墙规则，例如 `iptables`、`ufw`、`firewalld`
- 如果你使用 AWS、GCP、腾讯云、阿里云、华为云等云厂商，还需要到控制台手动放行对应端口
- 常见需要放行的项目包括安全组、VPC 防火墙、网络 ACL、实例防火墙规则
- 如果云厂商侧没放行，即使脚本已经在系统里开了端口，外部依然连不上

## 文件结构

```
/etc/sing-box/
├── config.json          主配置
├── info.dat             安装参数存档
├── manage.sh            管理脚本
├── cert/                HY2 自签证书

/usr/local/bin/sing-box   sing-box 二进制
/usr/local/bin/sb         管理快捷命令
```

## 常见问题

<details>
<summary><b>连不上节点？</b></summary>

1. 检查云厂商安全组是否放行了对应端口
2. 检查 AWS / GCP / 腾讯云 / 阿里云等控制台里的安全组或防火墙规则
3. 用 [tcp.ping.pe](https://tcp.ping.pe) 测试 IP 连通性
4. `sb` 选 10 查看服务状态详情，选 9 跟实时日志
5. 尝试更换端口（选 3 / 4）
</details>

<details>
<summary><b>VPS 重启后还能用吗？</b></summary>

能。`sing-box` 由 `systemd` 自动拉起，BBR 和流量统计也会保留。
</details>

<details>
<summary><b>IP 变了怎么办？</b></summary>

运行 `sb` 打开管理菜单时会自动检测并更新，也可以手动选 7 刷新。然后重新复制或扫码导入最新链接。
</details>

<details>
<summary><b>如何更新 sing-box 内核？</b></summary>

脚本不再内置在线升级（安全起见避免新版本兼容问题把服务带挂）。需要时可以直接卸载再重装一次：

```bash
sb         # 选 0 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/aouos/sing-box/main/sb.sh)
```

重装会拿到最新版 sing-box，全新生成 UUID / 端口 / Reality 密钥对，导入新链接即可。
</details>

<details>
<summary><b>如何完全卸载？</b></summary>

运行 `sb` 选 0，会清除文件、服务、快捷命令和已写入的防火墙放行规则。
</details>

<details>
<summary><b>如何查看流量使用情况？</b></summary>

运行 `sb` 后选择 `8`，脚本会调用 `vnstat` 显示总流量和最近 15 天的日用量。

`vnstat` 由安装脚本一并装上并开启为系统服务，刚装完几分钟内数据库为空属于正常，等流量经过网卡后会自动累计。
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
