<div align="center">

# ⚡ XanMod BBR Optimizer

**Debian / Ubuntu 服务器一体化管理脚本**

XanMod 内核 · BBR v3 · TCP 动态调优 · 代理部署 · 端口转发 · 流量配额 · Telegram 告警

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-blue)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey)
![Version](https://img.shields.io/badge/version-v2.0.0--beta.1-orange)

</div>

---

## ⚡ 测试版安装

当前为 **v2.0.0-beta.1 预发布测试版**，仅供重装后的干净系统测试。下面固定下载测试标签，不跟随 main；没有 curl 时先安装：

```bash
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
curl -fL --connect-timeout 10 --max-time 120 https://raw.githubusercontent.com/Bud668/vps-mgr/v2.0.0-beta.1/vps-mgr.sh -o vps-mgr-beta.sh && bash -n vps-mgr-beta.sh && chmod 700 vps-mgr-beta.sh && ./vps-mgr-beta.sh
```

> v2 面向重装后的干净 Debian / Ubuntu，推荐 Debian 12/13 或 Ubuntu 22.04/24.04。需要 root、systemd 作为 PID 1、apt，以及内核 nftables 支持。容器还需要 CAP_NET_ADMIN；普通 Docker 容器不适用。

**不提供 v1/iptables 升级迁移或双后端兼容。**先重装系统，再使用 v2 配置；请确认脚本显示 v2.0.0-beta.1。发布页：[v2.0.0-beta.1](https://github.com/Bud668/vps-mgr/releases/tag/v2.0.0-beta.1)。

测试代码位于 `test/nftables-v2`，不合并到 `main`；GitHub Release 标记为 Pre-release，且不设为 Latest。旧版脚本的 `/releases/latest` 正式更新入口仍为 v1.4.1，不会自动安装本测试版。后续 beta 需手动安装，本测试版也不会自动降级到 v1。

请保留下载脚本的路径，防火墙等 systemd 单元会引用它；不要测试安装后删除或移动。实际启动、第二次 SSH 登录和重启恢复仍需在测试机验收。

---

## 功能总览

| 分类 | 功能 |
|------|------|
| 🚀 **内核优化** | XanMod 内核一键安装、BBR v3 拥塞控制 |
| 📶 **网络调优** | 按实测带宽动态计算 TCP 缓冲区、fq qdisc、中转/落地双档位 |
| 🔒 **安全加固** | 原生 nftables 双栈默认 DROP、SSH 防暴破、Fail2Ban、CN IP 封禁 |
| 🌐 **代理服务** | sing-box（Shadowsocks / SOCKS5 / Hysteria2）、Snell |
| 🔀 **端口转发** | realm 转发规则、失效端点检测 |
| 📊 **流量配额** | 按端口计量、超额自动暂停、到期管理 |
| 📡 **监控告警** | Telegram 话题群推送、SSH 登录通知、流量配额告警 |
| 🔄 **自更新** | 手动更新；每日自动更新需自行启用，带语法校验、备份和防降级 |
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

`fq maxrate` 是**单流**上限，不是整机聚合限速。80Mbps 等低带宽按实际配置计算，不会被抬高至100Mbps；带宽重调默认读取上次确认值，不从限速值反推。

网络优化必须同时考虑 Snell、Realm、sing-box 和混部的 Sub2API：共享内核参数按各服务共同需求评估，建连、保活和读写超时分别由服务控制。已建立连接的 `tcp_retries2` 默认8，基础检测要求不低于8，避免短暂断网时过早断开；SYN及孤儿连接重试保持3和1。此项不替代各服务的超时与保活，也不保证长WS能跨过所有断网。业务上线后应用单项变更，不重跑整套初始化。

---

### 🌐 代理服务

| 协议 | 说明 |
|------|------|
| **Shadowsocks** | 经 [sing-box](https://github.com/SagerNet/sing-box)，支持 2022-blake3 系列加密 |
| **SOCKS5** | 经 sing-box，带 IP 白名单（未配白名单时端口全拒绝，菜单会红字提示） |
| **Hysteria2** | 经 sing-box，自签证书 + salamander 混淆 |
| **Snell** | 独立 systemd 模板单元，一端口一实例 |

安装时可手动指定本机监听端口；回车才从 **55000–65535** 中选择未占用端口。指定端口被占用时会要求重填，不会悄悄换成随机端口。NAT 小鸡必须按供应商映射填写，防火墙不能新增供应商未分配的公网端口。

**CN IP 封禁**：按端口开关，原生 IPv4/IPv6 interval sets 原子更新，下载/校验失败保留旧库，每周更新并持久化；不再依赖 ipset。

sing-box 配置先在 600 权限临时文件中生成并校验，再替换生效；添加/删除节点、修改 ACL 失败会恢复原状态。SOCKS5 白名单同时保护 IPv4/IPv6，默认只开放 TCP；Hy2 只开放 UDP。

程序先下载、验证再替换；sing-box/Realm 验证 GitHub Release 资产的 SHA256，Snell 使用官方 HTTPS 下载、ELF/启动参数校验（上游未提供同样的摘要接口）。下载失败保留旧程序运行，替换后原本运行的服务启动失败会回退。

---

### 🔀 端口转发（realm）

- 向导式添加转发规则，自动开放防火墙端口
- **失效端点检测**：批量探测并清理连不通的规则
- 改完规则主菜单会**常驻红字提醒**，直到你重启生效（realm 不支持热重载，重启会断开现有连接，时机由你挑）

---

### 📊 流量配额

- 按端口独立计量 IPv4/IPv6 进出流量（nftables 命名计数器）
- 超额**自动暂停端口**，到期自动删除节点
- 用量达 75% 预警，每日 Telegram 报告
- 普通端口放行不重置计数器；暂停同时拦截已有连接，重启/规则恢复时先恢复暂停状态
- 巡检间隔 5 分钟：超额执行可能有一个巡检间隔的延迟；突然断电可能丢失上次落盘后尚未结算的流量，非计费级精确统计

---

### 🔒 安全加固

**原生 nftables 防火墙**

- 默认 DROP 策略，最小暴露面
- 不预开 80/443（脚本不签证书、不跑 web，需要时菜单手动开）
- 仅管理 `table inet vps_mgr`，普通修改是原子批次，不清空整个 ruleset
- 配置存于 `/etc/nftables.d/vps-mgr.nft`，由 `vps-mgr-firewall.service` 恢复；停止该单元不会移除保护
- 首次应用前建立独立 systemd 回滚定时器，3 分钟内必须从**第二个 SSH 会话**执行屏幕显示的 `firewall-confirm` 命令
- 未确认不继续安装代理，不启用开机恢复；超时只撤回本次新建表，恢复初始化前的空规则状态

**已有其他防火墙规则或管理服务时，拒绝初始化并原样保留，不清空、不停用。**读取状态失败也中止。已经初始化的本脚本表重复执行时保持不变；不提供“全开放/清空所有规则”菜单。不支持接管 Docker、Kubernetes 或已有路由/NAT 主机；Realm 是用户态代理，不能把它等同于内核 FORWARD。

业务上线后不要重复执行完整初始化：系统升级、DNS 重写、带宽测速和 sysctl 调整仍可能影响连接。已有 fq 使用 change 更新；其他 qdisc 保留不动，持久化使用单独的 `vps-mgr-fq.service`。

**SSH 加固**

- 保留原 SSH 端口，检测有效配置与实际连接端口；外部 NAT 端口不等于本机监听端口
- 配置 Fail2Ban 时设置 `MaxAuthTries=3`、`LoginGraceTime=30`（通过独立 sshd drop-in，校验后重载）
- 每来源 IP 的令牌桶限速：15 次/分钟、突发 15；与旧 recent 滑动窗口语义不同
- Fail2Ban 明确使用 nftables action；管理白名单只豁免 SSH，不绕过业务配额或 ACL

**测试模式**

- 通过内核 timeout 临时开放 Ping 和 iperf3，**2 小时自动到期**，不依赖 atd，也不随重启重新开放
- 两端口 NAT 容器通常没有 5201 映射，不应为测速或 TCPing 随意占用业务端口

---

### 📡 Telegram 告警

三类通知共用一个**话题群**，各占一个话题：

| 通道 | 内容 |
|------|------|
| 🔐 SSH 登录（话题） | 登录成功/失败，IP + 时间 + 方式；Fail2Ban 封禁通知 |
| 📊 流量配额（话题） | 用量预警、超额暂停通知 |
| ☁️ DDNS（话题） | IP 变更、健康巡检 |

所有 Token 与 Chat ID **均为运行时输入**，不写进脚本。未启用 SSH 通知时为 root-only；启用后共享配置/国旗缓存为 `root:ssh-tg-monitor`、640，父目录仅给该组遍历权限，其他代理密钥仍不可读。监控以独立用户读取 systemd journal，不再 source 用户配置；卸载 SSH 监控保留配额/DDNS 共用的 TG 配置。

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

重装系统后运行 v2 脚本：

1. 选择 **「1. 一键初始化 → 1. 仅代理必需依赖 + nftables」**。
2. 保留当前 SSH，另开连接执行屏幕中的确认命令。未确认前不要重启机器。
3. 重新进入菜单 1 的轻量模式确认初始化完成，再进入 **菜单 9** 安装 SS2022。
4. NAT 容器按实际映射手填端口，例如本机映射也为 24073/24074 时才填写这两个端口；不改供应商 SSH 映射。
5. 按需配置菜单 2（Fail2Ban）、3（通知）、13（配额）。

轻量模式不升级系统、不改 DNS/IPv6、不换内核、不创建 Swap、不调整 qdisc，也不默认安装专用 TCPing 服务。

独立 VPS 可选择完整调优模式，在防火墙确认后继续系统升级、XanMod 与网络优化。容器强制走轻量路径；参数计算尊重 cgroup 内存上限和真实页大小。

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

**Q: 需要启用 nftables.service 或卸载 iptables 吗？**
不需要。脚本使用自己的持久化单元；不要另行启动带 `flush ruleset` 的全局配置。旧工具包是否安装不重要，本版业务路径不调用它们，也不会自动卸载其他程序的依赖。

**Q: 容器提示 nftables 无权限？**
需要供应商提供内核功能及 CAP_NET_ADMIN。安装软件包不能补足宿主权限；脚本会停止，不降级到 iptables，也不让你误以为白名单已经生效。

## 本地验证

```bash
bash -n vps-mgr.sh
shellcheck -S error vps-mgr.sh tests/*.sh
bash tests/test_get_node_id.sh
bash tests/test_safety.sh
bash tests/test_network_init.sh
unshare --net bash tests/test_network_init.sh --netns
unshare --net bash tests/test_nftables.sh
```

网络集成测试只允许在独立 network namespace 中运行，状态文件重定向到临时目录，服务管理被替换为测试桩，不修改宿主防火墙。可设置 `VPS_MGR_REAL_SBX=/path/to/sing-box` 让安全回归调用真实核心校验配置。新系统的实际启动、SSH 重连和重启恢复仍需部署后验收。

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
