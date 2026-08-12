<div align="center">

# ⚡ XanMod BBR Optimizer

**Debian / Ubuntu 服务器一体化管理脚本**

XanMod 内核 · BBR v3 · TCP 动态调优 · 代理部署 · 端口转发 · 流量配额 · Telegram 告警

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-blue)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey)
![Version](https://img.shields.io/badge/version-v1.4.1-green)

</div>

---

## ⚡ 一键启动

裸系统也能直接跑（没有 curl 会自动装）：

```bash
command -v curl >/dev/null || { echo "Installing curl (a few seconds)..."; apt-get update -qq && apt-get install -y -qq curl; }; echo "Downloading..."; curl -fsSL https://raw.githubusercontent.com/Bud668/vps-mgr/main/vps-mgr.sh -o vps-mgr.sh && chmod +x vps-mgr.sh && ./vps-mgr.sh
```

> 需要 root，支持 Debian 11+ / Ubuntu 20.04+（依赖 systemd 与 apt）

**已装过的机器**直接在菜单里升级，不用重新下载：`[16] 更新服务` → `5. 本脚本`

---

## 功能总览

| 分类 | 功能 |
|------|------|
| 🚀 **内核优化** | XanMod 内核一键安装、BBR v3 拥塞控制 |
| 📶 **网络调优** | 按实测带宽动态计算 TCP 缓冲区、fq qdisc、中转/落地双档位 |
| 🔒 **安全加固** | iptables 默认 DROP、SSH 加固与防暴破、Fail2Ban、CN IP 封禁 |
| 🌐 **代理服务** | sing-box（Shadowsocks / SOCKS5 / Hysteria2）、Snell |
| 🔀 **端口转发** | realm 转发规则、失效端点检测 |
| 📊 **流量配额** | 按端口计量、超额自动暂停、到期管理 |
| 📡 **监控告警** | Telegram 话题群推送、SSH 登录通知、流量配额告警 |
| 🔄 **自更新** | 菜单一键升级 + 每日自动更新（仅正式版，预发布不动），带语法校验与自动备份 |
| ☁️ **DDNS** | Cloudflare A 记录自动更新 |

---

## 亮点功能详解

### 🚀 XanMod 内核 + BBR v3

[XanMod](https://xanmod.org/) 是专为性能优化设计的 Linux 内核，内置 BBR v3 拥塞控制。

**BBR v3 vs 传统 CUBIC：**
- 高延迟网络下吞吐量显著提升
- 高丢包场景下更稳定
- 适合跨境、高延迟 VPS 场景

```bash
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

从官方 APT 源安装，自动识别 CPU 指令集（x64v1～v4）选择对应版本，重启后生效。

---

### 📶 TCP 缓冲区动态调优

先**实测下行带宽**，再据此计算参数，而不是套固定模板：

| 参数 | 说明 |
|------|------|
| `rmem_max` / `wmem_max` | 套接字缓冲区上限，按 BDP 计算 |
| `tcp_rmem` / `tcp_wmem` | TCP 读写缓冲区三级配置 |
| `netdev_max_backlog` | 网卡队列深度 |
| `somaxconn` | 最大连接数队列 |

**两种机器角色，参数取向相反：**

- **优化线路（中转 / 高并发）**：缓冲区池均分，防单连接吃爆
- **落地（低并发 / 单连接）**：给满 BDP，单连接跑满带宽

> 1Gbps 和 100Mbps 的最优参数完全不同，脚本按实测值套用。

---

### 🌐 代理服务

| 协议 | 说明 |
|------|------|
| **Shadowsocks** | 经 [sing-box](https://github.com/SagerNet/sing-box)，支持 2022-blake3 系列加密 |
| **SOCKS5** | 经 sing-box，带 IP 白名单（未配白名单时端口全拒绝，菜单会红字提示） |
| **Hysteria2** | 经 sing-box，自签证书 + salamander 混淆 |
| **Snell** | 独立 systemd 模板单元，一端口一实例 |

监听端口从 **55000–65535** 随机分配，与内核出站临时端口段（10000–54999）刻意错开，避免 bind 竞态。

**CN IP 封禁**：可按端口开关，ipset 原子替换，每周自动更新 IP 库。

---

### 🔀 端口转发（realm）

- 向导式添加转发规则，自动开放防火墙端口
- **失效端点检测**：批量探测并清理连不通的规则
- 改完规则主菜单会**常驻红字提醒**，直到你重启生效（realm 不支持热重载，重启会断开现有连接，时机由你挑）

---

### 📊 流量配额

- 按端口独立计量进出流量（iptables 计数链）
- 超额**自动暂停端口**，到期自动删除节点
- 用量达 75% 预警，每日 Telegram 报告

---

### 🔒 安全加固

**iptables 防火墙**
- 默认 DROP 策略，最小暴露面
- 不预开 80/443（脚本不签证书、不跑 web，需要时菜单手动开）
- 规则持久化，重启不丢失
- 应用新策略前自动挂"安全网"，2 分钟内没确认则回滚，防把自己关在门外

**SSH 加固**
- 自定义端口、`MaxAuthTries=3`、`LoginGraceTime=30`
- 内核级防暴破：60 秒内 16 次新连接即 DROP
- Fail2Ban 联动，白名单 IP 永不封禁

**测试模式**
- 临时开放 Ping 和 iperf3，**2 小时自动关闭**

---

### 📡 Telegram 告警

三类通知共用一个**话题群**，各占一个话题：

| 通道 | 内容 |
|------|------|
| 🔐 SSH 登录（话题） | 登录成功/失败，IP + 时间 + 方式；Fail2Ban 封禁通知 |
| 📊 流量配额（话题） | 用量预警、超额暂停通知 |
| ☁️ DDNS（话题） | IP 变更、健康巡检 |

所有 Token 与 Chat ID **均为运行时输入**，存本地 600 权限文件，不写进脚本。多台机器填同一组话题 ID 即可共用话题群。

---

## 菜单结构

```
 [ 系统管理 ]
 ★ 1. 一键初始化                4. 切换测试模式
    2. Fail2Ban                 5. 防火墙规则
    3. TG 推送配置              6. 系统维护

 [ 代理服务 ]                   [ 规则与转发 ]
    7. 安装 Snell              11. 重启 Realm
    8. 安装 Realm              12. 检测并删除失效规则
    9. 安装 sing-box           13. 流量配额与到期管理
   10. 添加转发规则            14. 查看运行状态日志

 [ 进阶控制 ]
   15. 启停服务
   16. 更新服务 (Snell/sing-box/Realm/本脚本)
   17. 卸载服务
   18. Cloudflare DDNS
```

---

## 安装说明

跑上面的一键命令，然后选 **「1. 一键初始化」**，它会依次完成：

```
① IPv6 禁用 → ② 系统更新 & 依赖 → ③ XanMod 内核
④ 网络调优（带宽实测 + sysctl）→ ⑤ 防火墙 → ⑥ TG / Fail2Ban / TCPing
```

> 装完 XanMod 需重启一次，重启后 BBR v3 自动生效。

### 验证 BBR v3

```bash
sysctl net.ipv4.tcp_congestion_control   # 应输出 bbr
uname -r                                  # 应包含 xanmod
```

---

## 常见问题

**Q: 安装 XanMod 后 BBR v3 没生效？**
重启后再验证，确认 `uname -r` 输出包含 `xanmod`。

**Q: 支持 CentOS 吗？**
不支持。仅 Debian / Ubuntu——XanMod 官方 APT 源只面向 Debian 系，脚本也全程用 apt。

**Q: 改了 Realm 规则为什么不生效？**
realm 不支持热重载，必须重启才生效。主菜单会红字提示直到你重启。重启会断开现有连接，所以时机留给你自己挑（`[11] 重启 Realm`）。

**Q: SOCKS5 节点连不上？**
先看菜单里该节点有没有 `⚠ 白名单为空，端口全拒绝`。白名单空 = 拒绝所有来源，这是设计如此。

**Q: 网络参数调优后速度反而变慢？**
「6. 系统维护」里可重新实测带宽并调整，或切换机器角色（中转/落地的参数取向相反）。

**Q: 一键初始化为什么卸载 exim4？**
Debian 自带的 exim4 默认绑 IPv6 回环 `::1`，而脚本禁用了 IPv6，它必然启动失败并长期占据 `systemctl --failed`。代理机也用不到 MTA，留着还多一个监听 25 端口的攻击面。

---

## 第三方组件

脚本会下载并配置以下上游项目，各自遵循其许可证：

- [sing-box](https://github.com/SagerNet/sing-box)
- [realm](https://github.com/zhboner/realm)
- [XanMod Kernel](https://xanmod.org/)

---

## 免责声明

本脚本会修改系统级配置（内核参数、防火墙规则、SSH 设置）并安装服务。请在运行前自行审阅代码，仅在你拥有或已获授权管理的服务器上使用。使用者需自行遵守所在地法律法规及服务商条款。

---

## License

MIT License — 自由使用，保留署名。
