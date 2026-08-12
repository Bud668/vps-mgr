#!/bin/bash
# ==============================================================================
# Server & VPS Manager (统一版)
# https://github.com/Bud668/vps-mgr
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

# ── 手动配置区（升级时只改这里）──────────────────────────────────
readonly SNELL_VERSION_OVERRIDE="v5.0.1"


# ==============================================================================
# SECTION 1: 全局常量
# ==============================================================================

readonly SCRIPT_VERSION="1.4.1"
readonly SELF_REPO="Bud668/vps-mgr"
readonly TZ_DEFAULT="Asia/Shanghai"
readonly WORK_DIR="/opt/proxy-manager"
readonly CACHE_FILE="$WORK_DIR/server_info.cache"
readonly CACHE_TTL=86400
readonly LOCK_FILE="/run/server-manager.lock"
readonly UPDATE_CHECK_CACHE="$WORK_DIR/update_check.cache"
readonly UPDATE_CHECK_INTERVAL=86400
# 入站监听口自动分配段（55000-65535）。与出站临时端口段（sysctl ip_local_port_range
# = 10000 54999）刻意错开，避免监听口与内核出站源端口在同一台机上撞号（bind 竞态）。
readonly RAND_PORT_MIN=55000
readonly RAND_PORT_MAX=65535
readonly ULIMIT_NOFILE=51200

# 变量初始化
SERVER_IP="127.0.0.1"
SERVER_COUNTRY_CODE="UN"
SERVER_COUNTRY_NAME="Unknown"
SERVER_CITY="Unknown"
_G_BBR_VER=""
_TMPFILES=()


# Snell/Realm 服务路径（SS/SOCKS5/Hy2 见 sing-box 区块 SBX_*）
readonly SNELL_USER="snellproxy"
readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_CONFIG_DIR="/etc/snell"
readonly SNELL_SERVICE_FILE="/etc/systemd/system/snell@.service"
# Snell 无 --version，安装时把版本号落盘记录，供更新检查比对
readonly SNELL_VERSION_FILE="/etc/snell/.version"
# Snell 无 GitHub 仓库，版本从 Surge 官方 KB 页面抓取
readonly SNELL_KB_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

# Realm 相关
readonly REALM_USER="realmproxy"
readonly REALM_BIN="/usr/local/bin/realm"
readonly REALM_CONFIG_DIR="/etc/realm"
readonly REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.json"
readonly REALM_META_FILE="${REALM_CONFIG_DIR}/metadata.json"
readonly REALM_SERVICE_FILE="/etc/systemd/system/realm.service"

# sing-box 统一代理（SS/SS2022；后续 SOCKS5/Hysteria2）。每节点一个 env 小文件，
# sbx_render 据此重建 config.json。函数统一 sbx_/_sbx_ 前缀，与旧模块零冲突。
readonly SBX_BIN="/usr/local/bin/sing-box"
readonly SBX_ETC="/etc/sing-box"
readonly SBX_CONF="${SBX_ETC}/config.json"
readonly SBX_ST="/etc/sb-server"
readonly SBX_ACL="${SBX_ST}/acl-domains.txt"
readonly SBX_SVC="sing-box"


TCPING_SERVICE_NAME="tcping-monitor"
TCPING_CONFIG_FILE="/etc/tcping-monitor.conf"

SSH_TG_SERVICE="ssh-tg-monitor"
SSH_TG_CONF="/etc/ssh-tg-monitor.conf"
SSH_TG_SCRIPT="/usr/local/bin/ssh-tg-monitor.sh"
F2B_WHITELIST="/etc/fail2ban/f2b-whitelist.conf"


# ==============================================================================
# SECTION 2: 颜色变量（统一 C_* 命名 + iptables 模块兼容别名）
# ==============================================================================

readonly C_RESET='\033[0m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_PURPLE='\033[1;35m'
readonly C_CYAN='\033[1;36m'
readonly C_WHITE='\033[1;37m'
readonly C_DIM='\033[2m'

# 兼容 iptables 模块中大量使用的旧名字（不影响功能）
RED=$C_RED; GREEN=$C_GREEN; YELLOW=$C_YELLOW; BLUE=$C_BLUE
CYAN=$C_CYAN; WHITE=$C_WHITE; NC=$C_RESET
L_GREEN=$C_GREEN; L_YELLOW=$C_YELLOW; L_BLUE=$C_BLUE
L_PURPLE=$C_PURPLE; L_CYAN=$C_CYAN


# ==============================================================================
# SECTION 3: 日志与核心工具函数
# ==============================================================================

readonly LOG_FILE="/var/log/proxy-manager.log"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

log_message() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(TZ="$TZ_DEFAULT" date '+%Y-%m-%d %H:%M:%S')
    case "$LOG_LEVEL" in
        DEBUG) ;;
        INFO) [[ "$level" == "DEBUG" ]] && return ;;
        WARN) [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return ;;
        ERROR) [[ "$level" != "ERROR" ]] && return ;;
    esac
    if [[ ! -f "$LOG_FILE" ]]; then
        install -m 600 /dev/null "$LOG_FILE" 2>/dev/null || true
    fi
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# 基础 msg 只做输出，不自己写日志 (避免包装函数重复写入)
msg() { printf '%b\n' "$@"; }
msg_info()    { msg "${C_GREEN}[信息]${C_RESET} $1"; log_message "INFO"  "$1"; }
msg_warn()    { msg "${C_YELLOW}[警告]${C_RESET} $1"; log_message "WARN"  "$1"; }
msg_error()   { msg "${C_RED}[错误]${C_RESET} $1" >&2; log_message "ERROR" "$1"; }
msg_step()    { msg "${C_BLUE}[步骤]${C_RESET} $1"; log_message "INFO"  "$1"; }
msg_success() { msg "${C_GREEN}[成功]${C_RESET} $1"; log_message "INFO"  "$1"; }
cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
# 注意: cleanup 的 EXIT trap 仅在 acquire_lock 成功拿锁后注册，
# 避免 daemon/quota-check 等子命令(从不持锁)退出时误删交互实例的锁文件。

die() {
    msg_error "$1"
    exit 1
}

acquire_lock() {
    local _pid
    _pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    # 用追加模式打开：未拿到锁时不会截断正在运行实例写入的 PID
    exec 9>>"$LOCK_FILE"
    if ! flock -n 9 2>/dev/null; then
        if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" >/dev/null 2>&1; then
            echo -e "${C_RED}错误: 脚本已在运行 (PID: ${_pid})。${C_RESET}" >&2
        else
            echo -e "${C_RED}错误: 无法获取锁文件 ${LOCK_FILE}。${C_RESET}" >&2
        fi
        exit 1
    fi
    : > "$LOCK_FILE"
    echo $$ >&9
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
    # 仅持锁者注册清理，避免子命令退出删除他人锁文件
    trap cleanup EXIT
}

get_flag_emoji() {
    # 由国家码算 Unicode 国旗（区域指示符），支持任意国家，不再靠写死列表。
    # UN = 脚本内部"未知"哨兵、空值、非两位字母 → 一律地球。纯 bash，无需 python。
    local cc="${1:-}"
    [[ "$cc" =~ ^[A-Za-z]{2}$ ]] || { printf '🌐'; return; }
    cc="${cc^^}"
    [[ "$cc" == "UN" ]] && { printf '🌐'; return; }
    local a b
    a=$(( 0x1F1E6 + $(printf '%d' "'${cc:0:1}") - 65 ))
    b=$(( 0x1F1E6 + $(printf '%d' "'${cc:1:1}") - 65 ))
    printf "\\U$(printf '%08x' "$a")\\U$(printf '%08x' "$b")"
}

# 渲染服务器展示名。纯 ASCII 名（如 Bread_LA）补国旗；已含 emoji 的（如自动生成的
# "🇺🇸 United States, Los Angeles"）原样返回，避免重复加旗。
# $2 非空时再加 # 前缀 —— 那是 Telegram 话题标签，可点击筛选某台机器的消息，
# 仅用于推送，终端显示不加。
# 注：SSH 监控脚本内有一份等价的 _srv_display，因其独立运行无法共用。
_srv_render() {
    local _n="$1" _tag="${2:-}" _cc="${3:-${SERVER_COUNTRY_CODE:-}}"
    if [[ "$_n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        local _f; _f=$(get_flag_emoji "$_cc")
        printf '%s%s%s' "${_f:+${_f} }" "${_tag:+#}" "${_n//-/_}"
    else
        printf '%s' "$_n"
    fi
}

# 返回供配额和 DDNS 共用的本机标识。默认输出 Telegram 标签；传 plain 时
# 输出终端展示名。优先使用用户设置的 SERVER_NAME，没有时回退到国家码和
# 公网 IPv4 末段。该函数必须留在共享工具区，不能随某个业务模块一起删除。
get_node_id() {
    local _mode="${1:-tag}" _tag="tag"
    local _name="" _cc="" _ip="" _last=""
    [[ "$_mode" == "plain" ]] && _tag=""

    _name=$(_tg_cfg_get "$TG_CONF" SERVER_NAME)
    _cc=$(_read_cache_value "SERVER_COUNTRY_CODE" "$CACHE_FILE")
    if [[ -n "$_name" ]]; then
        _srv_render "$_name" "$_tag" "${_cc:-${SERVER_COUNTRY_CODE:-UN}}"
        return 0
    fi

    _ip=$(_read_cache_value "SERVER_IP" "$CACHE_FILE")
    if [[ ! "$_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        _ip=$(get_public_ip 2>/dev/null || true)
    fi
    [[ "$_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && _last="${_ip##*.}"

    _cc="${_cc:-${SERVER_COUNTRY_CODE:-UN}}"
    [[ "$_cc" =~ ^[A-Za-z]{2}$ ]] || _cc="UN"
    _cc="${_cc^^}"
    if [[ -n "$_last" ]]; then
        printf '%s%s_%s' "${_tag:+#}" "$_cc" "$_last"
    else
        printf '%s%s' "${_tag:+#}" "$_cc"
    fi
}

get_latest_github_release() {
    local repo_url=$1
    local fallback_version="${2:-}"
    local latest_tag

    # 尝试获取，如果失败则静默
    # -L 跟随重定向：仓库改名后 API 返回 301，不跟随就拿不到版本（自更新会失效）
    latest_tag=$(curl -sL --max-time 10 --retry 2 "https://api.github.com/repos/${repo_url}/releases/latest" | jq -r '.tag_name' 2>/dev/null)

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        if [[ -n "$fallback_version" ]]; then
            msg_warn "无法连接 Github API (可能触发限流)，将使用保底版本: ${fallback_version}"
            echo "$fallback_version"
        else
            msg_warn "无法连接 Github API，且无保底版本，请检查网络后重试。"
            return 1
        fi
        return 0
    fi
    echo "$latest_tag"
}


# ------------------------------------------------------------------------------
# 系统与环境检查
# ------------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要root权限运行。请使用: sudo $0"
    fi
    return 0
}

# ==============================================================================
# SECTION 4: 系统工具函数（共享）
# ==============================================================================

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "aarch64" ;;
        armv7l) echo "armv7l" ;;
        *) echo "unsupported" ;;
    esac
}

SNELL_ARCH=$(detect_arch)
SS_ARCH=$SNELL_ARCH

get_public_ip() {
    local ip url
    for url in "https://api.ipify.org" "https://ip.sb" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"; return 0
        fi
    done
    echo "<获取失败，请手动填写>"
}


show_spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        i=$(((i + 1) % ${#spin}))
        printf "\r${YELLOW}%s %s${NC}" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    tput cnorm 2>/dev/null
    printf "\r%s\r" "$(tput el)"
}

check_package_manager_lock() {
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
    )
    for lock_file in "${lock_files[@]}"; do
        if fuser "$lock_file" >/dev/null 2>&1; then
            echo -e "${RED}错误: 包管理器被占用 ($lock_file)。${NC}"
            return 1
        fi
    done
    return 0
}

pause() {
    echo
    printf "${C_BLUE}按任意键返回主菜单...${C_RESET}\n"
    read -rsn1
}

open_firewall_port() {
    local port=$1
    # 端口合法性校验，防止空值或非法参数静默失败
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo -e "${RED}错误: open_firewall_port 收到无效端口: '${port}'${NC}" >&2
        return 1
    fi
    msg_step "配置防火墙开放端口 ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port" >/dev/null
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="${port}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null || \
            iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT || { echo -e "${RED}错误: iptables 开放 TCP ${port} 失败${NC}" >&2; return 1; }
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT &>/dev/null || \
            iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT || { echo -e "${RED}错误: iptables 开放 UDP ${port} 失败${NC}" >&2; return 1; }
        # 优先使用 netfilter-persistent 保存
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi
}

close_firewall_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo -e "${RED}错误: close_firewall_port 收到无效端口: '${port}'${NC}" >&2
        return 1
    fi
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw delete allow "$port" >/dev/null
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null
        firewall-cmd --permanent --remove-port="${port}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
    elif command -v iptables &>/dev/null; then
        local _deleted=0
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null && \
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null && _deleted=1 || true
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT &>/dev/null && \
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT &>/dev/null && _deleted=1 || true
        # 仅在实际删除了规则时才持久化，避免无意义写入
        if [[ $_deleted -eq 1 ]]; then
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            fi
        fi
    fi
    printf "${C_GREEN}已尝试删除防火墙规则 (Port: %s)${C_RESET}\n" "$port"
}


# ==============================================================================
# SECTION 5: 统一 Telegram 基础设施
# ==============================================================================

readonly TG_CONF="/etc/ssh-tg-monitor.conf"

# 发送话题群消息时的 message_thread_id；空 = 普通群/主话题
TG_THREAD_ID=""

# 读取 key=value 配置项（剥离引号）；$1=文件 $2=键名
_tg_cfg_get() {
    [[ -f "$1" ]] || return 0
    grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true
}

# 解析通知通道，设置 TG_BOT_TOKEN / TG_CHAT_ID / TG_THREAD_ID
# $1 = monitor | quota | ddns —— 三者共用话题群(TG_CHAT_HUB)，各占一个话题
# 三个通道共用话题群(TG_CHAT_HUB)，各占一个话题
_tg_resolve_channel() {
    local _key
    TG_BOT_TOKEN=""; TG_CHAT_ID=""; TG_THREAD_ID=""
    case "$1" in
        ssh)     _key=TG_THREAD_SSH     ;;
        quota)   _key=TG_THREAD_QUOTA   ;;
        ddns)    _key=TG_THREAD_DDNS    ;;
        *)       return 0 ;;
    esac
    TG_BOT_TOKEN=$(_tg_cfg_get "$TG_CONF" TG_BOT_TOKEN)
    TG_CHAT_ID=$(_tg_cfg_get   "$TG_CONF" TG_CHAT_HUB)
    TG_THREAD_ID=$(_tg_cfg_get "$TG_CONF" "$_key")
    return 0
}

# 写入统一 TG 配置：话题群 + SSH/配额/DDNS 三个话题ID
# 全部通知统一发到话题群，各占一个话题。TG_CHAT_ID 保留并等于话题群 ID：
# SSH 监控脚本沿用它作 chat_id，配合 TG_THREAD_SSH 投递到 SSH 话题。
_write_tg_conf() {
    local _tok="$1" _hub="$2" _srv="$3"
    local _th_ssh="${4:-}" _th_qt="${5:-}" _th_dd="${6:-}"
    local _tmp; _tmp=$(mktemp)
    {
        printf "TG_BOT_TOKEN='%s'\n" "$_tok"
        printf "TG_CHAT_ID='%s'\n"   "$_hub"
        printf "TG_CHAT_HUB='%s'\n"  "$_hub"
        [[ -n "$_srv"    ]] && printf 'SERVER_NAME="%s"\n'      "$_srv"
        [[ -n "$_th_ssh" ]] && printf "TG_THREAD_SSH='%s'\n"    "$_th_ssh"
        [[ -n "$_th_qt"  ]] && printf "TG_THREAD_QUOTA='%s'\n"  "$_th_qt"
        [[ -n "$_th_dd"  ]] && printf "TG_THREAD_DDNS='%s'\n"   "$_th_dd"
    } > "$_tmp"
    chmod 600 "$_tmp"
    mv "$_tmp" "$TG_CONF"
}

# 读取并保存 TG Token/Chat ID；成功返回 0，失败返回 1
# $1 = SERVER_NAME（可为空）
_tg_input_tokens() {
    local _srv="${1:-}"
    local _vals _vline _blank _new_tok _hub _th_ssh _th_qt _th_dd
    local _resp _bot _gf _cf
    while :; do
        printf "  粘贴配置，支持 # 注释行和空行分隔，自动跳过:\n"
        printf "  顺序: Bot Token → 话题群 Chat ID\n"
        printf "        → SSH 话题ID → 配额 话题ID → DDNS 话题ID\n"
        printf "  ${C_CYAN}提示: 话题ID = 在 TG 里右键话题「复制链接」，末尾那个数字${C_RESET}\n"
        printf "  ${C_CYAN}      所有机器填同一组 ID 即可共用话题群${C_RESET}\n"
        printf "  ${C_YELLOW}填完后（最少填 Token 和 话题群 Chat ID 两行）连按两次回车结束；输入 q 放弃${C_RESET}\n>>> "
        _vals=(); _blank=0
        while [[ ${#_vals[@]} -lt 5 ]]; do
            read -r _vline < /dev/tty || break
            _vline="${_vline#"${_vline%%[![:space:]]*}"}"
            _vline="${_vline%"${_vline##*[![:space:]]}"}"
            if [[ -z "$_vline" ]]; then
                # 已够主频道(≥2行) 时，连续两个空行结束；否则空行仅作分隔忽略
                if [[ ${#_vals[@]} -ge 2 ]]; then
                    _blank=$((_blank + 1))
                    [[ $_blank -ge 2 ]] && break
                fi
                continue
            fi
            _blank=0
            [[ "$_vline" =~ ^# ]] && continue
            _vals+=("$_vline")
        done
        _new_tok="${_vals[0]:-}" _hub="${_vals[1]:-}"
        _th_ssh="${_vals[2]:-}" _th_qt="${_vals[3]:-}" _th_dd="${_vals[4]:-}"
        [[ "$_new_tok" == "q" || "$_new_tok" == "Q" ]] && { printf "  ${C_YELLOW}⚠ 已放弃配置${C_RESET}\n"; return 1; }
        if [[ -z "$_new_tok" || -z "$_hub" ]]; then
            printf "  ${C_RED}✗ Token 或 话题群 Chat ID 不能为空，请重新粘贴（q 放弃）${C_RESET}\n"; continue
        fi
        printf "  正在验证 Bot..."
        _resp=$(curl -s --max-time 8 "https://api.telegram.org/bot${_new_tok}/getMe" 2>/dev/null || true)
        if ! echo "$_resp" | grep -q '"ok":true'; then
            printf " ${C_RED}✗ 连接失败（token 错误或网络问题），请重新粘贴（q 放弃）${C_RESET}\n"; continue
        fi
        _bot=$(echo "$_resp" | grep -oP '"username":"\K[^"]+' || echo "?")
        printf " ${C_GREEN}✓ @%s${C_RESET}\n" "$_bot"
        if [[ -z "$_srv" ]]; then
            _gf=$(get_flag_emoji "${SERVER_COUNTRY_CODE:-UN}")
            _srv="${_gf} ${SERVER_COUNTRY_NAME:-Unknown}, ${SERVER_CITY:-Unknown}"
        fi
        printf "  ${C_CYAN}── 待写入内容（请核对）──${C_RESET}\n"
        printf "  Token   : %s\n" "${_new_tok:0:20}..."
        printf "  话题群  : %s\n" "$_hub"
        printf "    ├ SSH 登录 : 话题 %s\n" "${_th_ssh:-未设置}"
        printf "    ├ 流量配额 : 话题 %s\n" "${_th_qt:-未设置}"
        printf "    └ DDNS     : 话题 %s\n" "${_th_dd:-未设置}"
        printf "  ${C_YELLOW}确认写入？[y=写入 / q=放弃 / 回车=重新粘贴]: ${C_RESET}"
        read -r _cf < /dev/tty || _cf="q"
        case "$_cf" in
            [Yy]) break ;;
            [Qq]) printf "  ${C_YELLOW}⚠ 已放弃，未写入${C_RESET}\n"; return 1 ;;
            *)    printf "  ${C_CYAN}↻ 重新粘贴${C_RESET}\n"; continue ;;
        esac
    done
    _write_tg_conf "$_new_tok" "$_hub" "$_srv" "$_th_ssh" "$_th_qt" "$_th_dd"
    printf "  ${C_GREEN}✓ 已保存${C_RESET}\n"
    printf "  ${C_CYAN}正在启动各监控服务...${C_RESET}\n"
    _setup_ssh_tg_monitor || true
    # 先发确认：服务未装时也能立刻验证话题 ID 是否正确
    printf "  ${C_CYAN}正在验证话题群各通道...${C_RESET}\n"
    _tg_notify_configured "$_srv"
    [[ -n "$_th_qt" ]] && grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null && { install_quota_services || true; }
    return 0
}

# 配置保存后逐通道发确认，当场暴露话题 ID 填错——否则要等对应服务真触发才发现
_tg_notify_configured() {
    local _srv="$1" _entry _ch _label _msg _ts
    _ts=$(TZ="$TZ_DEFAULT" date '+%Y-%m-%d %H:%M:%S')
    for _entry in "ssh:SSH 登录" "quota:流量配额" "ddns:DDNS"; do
        _ch="${_entry%%:*}"; _label="${_entry#*:}"
        _tg_resolve_channel "$_ch"
        [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" || -z "$TG_THREAD_ID" ]] && continue
        printf "  %s: " "$_label"
        _msg="✅ <b>${_label} 通道配置成功</b>
👤 主机: $(_srv_render "$_srv" tag)
🕒 时间: ${_ts}"
        if send_telegram "$_msg" 2>/dev/null; then
            printf "${C_GREEN}✓ 已送达话题 %s${C_RESET}\n" "$TG_THREAD_ID"
        else
            printf "${C_RED}✗ 失败（检查话题 ID 是否正确）${C_RESET}\n"
        fi
    done
}

# 测试单个推送目标；$1=标签 $2=token $3=chat $4=话题ID(可空) $5=时间戳
_tg_test_one() {
    local _label="$1" _tk="$2" _ch="$3" _th="$4" _ts="$5"
    printf "  %-6s: " "$_label"
    if [[ -z "$_tk" || -z "$_ch" ]]; then
        printf "${C_YELLOW}未配置${C_RESET}\n"; return
    fi
    local _cfg _um _resp
    _um=$(umask); umask 177; _cfg=$(mktemp); umask "$_um"
    printf 'max-time = 8\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "chat_id=%s"\ndata = "text=🔔 %s 测试推送 %s"\n' \
        "$_tk" "$_ch" "$_label" "$_ts" > "$_cfg"
    [[ -n "$_th" ]] && printf 'data = "message_thread_id=%s"\n' "$_th" >> "$_cfg"
    _resp=$(curl -K "$_cfg" -s 2>/dev/null || true); rm -f "$_cfg"
    if printf '%s' "$_resp" | grep -q '"ok":true'; then
        printf "${C_GREEN}✓ 成功${C_RESET}%b\n" "${_th:+  ${C_DIM}(话题 ${_th})${C_RESET}}"
    else
        printf "${C_RED}✗ 失败${C_RESET}  ${C_DIM}%s${C_RESET}\n" \
            "$(printf '%s' "$_resp" | grep -oP '"description":"\K[^"]+' || echo '无响应')"
    fi
}

# 中央 TG 推送配置菜单
_do_tg_config() {
    while true; do
        clear
        printf "${C_CYAN}:: TG 推送配置 ::${C_RESET}\n\n"

        local _tok="" _srv="" _hub="" _th_ssh="" _th_qt="" _th_dd=""
        _tok=$(_tg_cfg_get    "$TG_CONF" TG_BOT_TOKEN)
        _srv=$(_tg_cfg_get    "$TG_CONF" SERVER_NAME)
        _hub=$(_tg_cfg_get    "$TG_CONF" TG_CHAT_HUB)
        _th_ssh=$(_tg_cfg_get "$TG_CONF" TG_THREAD_SSH)
        _th_qt=$(_tg_cfg_get  "$TG_CONF" TG_THREAD_QUOTA)
        _th_dd=$(_tg_cfg_get  "$TG_CONF" TG_THREAD_DDNS)

        local _ssh_tg_st _quota_st _ddns_st
        systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null \
            && _ssh_tg_st="${C_GREEN}运行中${C_RESET}" || _ssh_tg_st="[-]"
        systemctl is-active --quiet quota-check.timer 2>/dev/null \
            && _quota_st="${C_GREEN}运行中${C_RESET}" || _quota_st="[-]"
        systemctl is-active --quiet "${DDNS_SERVICE_NAME}.timer" 2>/dev/null \
            && _ddns_st="${C_GREEN}运行中${C_RESET}" || _ddns_st="[-]"

        local _d
        _d="${_tok:+${_tok:0:20}...}"; printf "  Token : %s\n\n" "${_d:-未设置}"
        printf "  ${C_BLUE}[ 话题群 ]${C_RESET}  %b\n" "${_hub:-${C_YELLOW}未设置${C_RESET}}"
        printf "    ├ SSH 登录 %b  话题 %b\n" "$_ssh_tg_st"  "${_th_ssh:-${C_YELLOW}未设置${C_RESET}}"
        printf "    ├ 流量配额 %b  话题 %b\n" "$_quota_st" "${_th_qt:-${C_YELLOW}未设置${C_RESET}}"
        printf "    └ DDNS     %b  话题 %b\n" "$_ddns_st" "${_th_dd:-${C_YELLOW}未设置${C_RESET}}"

        printf "\n  ${C_GREEN}1.${C_RESET} 设置 Token & Chat ID\n"
        printf "  ${C_GREEN}2.${C_RESET} SSH 监控\n"
        printf "  ${C_GREEN}3.${C_RESET} 配额 监控\n"
        printf "  ${C_GREEN}4.${C_RESET} 测试推送\n"
        printf "  ${C_GREEN}0.${C_RESET} 返回\n"
        printf "\n${C_CYAN}请选择 [0-4]: ${C_RESET}"
        local _tg_ch; read -r _tg_ch < /dev/tty

        case "$_tg_ch" in
            1)  printf "\n"; _tg_input_tokens "$_srv" || true; pause ;;
            2)  # SSH 监控 sub-menu
                while true; do
                    clear
                    printf "${C_CYAN}:: SSH 监控 ::${C_RESET}\n\n"
                    local _ss_st
                    systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null \
                        && _ss_st="${C_GREEN}运行中${C_RESET}" || _ss_st="${C_RED}未运行${C_RESET}"
                    printf "  状态    : %b\n" "$_ss_st"
                    printf "  推送目标: ${C_CYAN}%s${C_RESET} 话题 ${C_CYAN}%s${C_RESET}\n" \
                        "${_hub:-未设置}" "${_th_ssh:-未设置}"
                    printf "\n  ${C_GREEN}1.${C_RESET} 配置并启动服务\n"
                    printf "  ${C_GREEN}2.${C_RESET} 查看日志\n"
                    printf "  ${C_GREEN}3.${C_RESET} 停止并卸载\n"
                    printf "  ${C_GREEN}0.${C_RESET} 返回\n"
                    printf "\n${C_CYAN}请选择 [0-3]: ${C_RESET}"
                    local _ssh_sub; read -r _ssh_sub < /dev/tty; printf "\n"
                    case $_ssh_sub in
                        1)  _setup_ssh_tg_monitor; pause ;;
                        2)  clear
                            printf "${C_YELLOW}--- SSH 推送最近日志 (50条) ---${C_RESET}\n"
                            journalctl -u "$SSH_TG_SERVICE" --no-pager -n 50 2>/dev/null \
                                || printf "${C_YELLOW}暂无日志${C_RESET}\n"
                            pause ;;
                        3)  systemctl stop    "$SSH_TG_SERVICE" 2>/dev/null || true
                            systemctl disable "$SSH_TG_SERVICE" 2>/dev/null || true
                            rm -f "/etc/systemd/system/${SSH_TG_SERVICE}.service" \
                                  "$SSH_TG_SCRIPT" "$SSH_TG_CONF"
                            systemctl daemon-reload 2>/dev/null || true
                            printf "${C_GREEN}✓ SSH 推送服务已停止并移除${C_RESET}\n"
                            pause; break ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"; printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                    esac
                done ;;
            3)  # 配额 监控
                while true; do
                    clear
                    printf "${C_CYAN}:: 配额 监控 ::${C_RESET}\n\n"
                    printf "  推送目标: ${C_CYAN}%s${C_RESET} 话题 ${C_CYAN}%s${C_RESET}\n" \
                        "${_hub:-未设置}" "${_th_qt:-未设置}"
                    printf "\n  ${C_GREEN}1.${C_RESET} 配置并启动服务\n"
                    printf "  ${C_GREEN}2.${C_RESET} 立即推送配额日报\n"
                    printf "  ${C_GREEN}0.${C_RESET} 返回\n"
                    printf "\n${C_CYAN}请选择 [0-2]: ${C_RESET}"
                    local _quota_sub; read -r _quota_sub < /dev/tty; printf "\n"
                    case $_quota_sub in
                        1)  if grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null; then
                                printf "  ${C_CYAN}正在启动配额监控服务...${C_RESET}\n"
                                install_quota_services || true
                            else
                                printf "  ${C_YELLOW}未配置流量配额，跳过启动${C_RESET}\n"
                            fi
                            pause ;;
                        2)  quota_daily_report || true; pause ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"; printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                    esac
                done ;;
            4)  # 测试推送（话题群三个话题）
                local _ts; _ts=$(TZ="$TZ_DEFAULT" date '+%H:%M:%S')
                _tg_test_one "SSH"  "$_tok" "$_hub" "$_th_ssh" "$_ts"
                _tg_test_one "配额" "$_tok" "$_hub" "$_th_qt"  "$_ts"
                _tg_test_one "DDNS" "$_tok" "$_hub" "$_th_dd"  "$_ts"
                pause ;;
            0|"") return ;;
            *) continue ;;
        esac
    done
}

_TG_LAST_MSG_ID=""

_tg_send_chunk() {
    local text="$1"
    _TG_LAST_MSG_ID=""
    local _cfg _old_umask
    _old_umask=$(umask)
    umask 177
    _cfg=$(mktemp)
    umask "$_old_umask"
    trap "rm -f '$_cfg'" RETURN
    printf 'max-time = 15\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "chat_id=%s"\ndata = "parse_mode=HTML"\n' \
        "$TG_BOT_TOKEN" "$TG_CHAT_ID" > "$_cfg"
    [[ -n "${TG_THREAD_ID:-}" ]] && printf 'data = "message_thread_id=%s"\n' "$TG_THREAD_ID" >> "$_cfg"

    local attempt resp
    for attempt in 1 2 3; do
        resp=$(printf '%s' "$text" | curl -K "$_cfg" --data-urlencode "text@-" -s 2>/dev/null)
        if printf '%s' "$resp" | grep -q '"ok":true'; then
            _TG_LAST_MSG_ID=$(printf '%s' "$resp" | grep -o '"message_id":[0-9]*' | grep -o '[0-9]*')
            rm -f "$_cfg"
            return 0
        fi
        # 话题不存在是配置错误，重试无意义（否则每次通知白等 15 秒）
        if printf '%s' "$resp" | grep -q 'message thread not found'; then
            rm -f "$_cfg"
            msg_warn "Telegram 话题 ID ${TG_THREAD_ID} 不存在，请在 TG 推送配置中检查"
            return 1
        fi
        [[ $attempt -lt 3 ]] && sleep 5
    done
    rm -f "$_cfg"
    msg_warn "Telegram 推送失败（已重试 3 次），请检查网络或 Bot 配置"
    return 1
}

_tg_edit_keyboard() {
    local msg_id="$1" keyboard_json="$2"
    local _attempt _cfg _old_umask
    _old_umask=$(umask); umask 177
    _cfg=$(mktemp); umask "$_old_umask"
    trap "rm -f '$_cfg'" RETURN
    printf 'max-time = 8\nurl = "https://api.telegram.org/bot%s/editMessageReplyMarkup"\nheader = "Content-Type: application/json"\n' \
        "$TG_BOT_TOKEN" > "$_cfg"
    for _attempt in 1 2; do
        printf '{"chat_id":"%s","message_id":%s,"reply_markup":{"inline_keyboard":%s}}' \
            "$TG_CHAT_ID" "$msg_id" "$keyboard_json" | \
            curl -K "$_cfg" --data @- -s 2>/dev/null | grep -q '"ok":true' && return 0
        [[ $_attempt -lt 2 ]] && sleep 3
    done
    return 0
}

send_telegram() {
    local text="$1"
    local server_label="${2:-}"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0

    # 消息不超限直接发送
    if [[ ${#text} -le 4050 ]]; then
        _tg_send_chunk "$text"
        return
    fi

    # 超限时在 ╌ 分隔符处分段，每段同时限制字符数(≤3800)和条目数(≤14)
    # 14条/页 × <u><b> 双标签 = 28 entities，远低于 Telegram 100 entities/msg 限制
    local limit=3800 entry_limit=14 chunk="" line sep_count=0
    local -a chunks=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^╌ && -n "$chunk" ]] && \
           [[ ${#chunk} -gt $limit || $sep_count -ge $entry_limit ]]; then
            chunks+=("$chunk")
            chunk="$line"
            sep_count=1
        else
            chunk="${chunk:+${chunk}$'\n'}${line}"
            [[ "$line" =~ ^╌ ]] && sep_count=$((sep_count + 1))
        fi
    done <<< "$text"
    [[ -n "$chunk" ]] && chunks+=("$chunk")

    local total=${#chunks[@]}
    # 只有一段（无可用切割点）直接发送
    if [[ $total -eq 1 ]]; then
        _tg_send_chunk "${chunks[0]}"
        return
    fi

    # 多段：每段首行加「标题 (N/total)」，第二行若是时间行(🕐)也重复
    local title_line1 title_line2
    title_line1=$(printf '%s' "$text" | head -1)
    title_line2=$(printf '%s' "$text" | sed -n '2p')
    [[ "$title_line2" != 🕐* ]] && title_line2=""

    local -a msg_ids=()
    local i
    for (( i=0; i<total; i++ )); do
        local part="${chunks[$i]}"
        local label="$((i+1))/${total}"
        if [[ $i -eq 0 ]]; then
            if [[ -n "$title_line2" ]]; then
                local _rest="${part#*$'\n'}"
                local _body="${_rest#*$'\n'}"
                part="${title_line1}"$'\n'"${title_line2} (${label})"$'\n'"${_body}"
            else
                part="${title_line1} (${label})"$'\n'"${part#*$'\n'}"
            fi
        else
            if [[ -n "$title_line2" ]]; then
                part="${title_line1}"$'\n'"${title_line2} (${label})"$'\n'"${part}"
            else
                part="${title_line1} (${label})"$'\n'"${part}"
            fi
        fi
        _tg_send_chunk "$part" || return 1
        msg_ids+=("$_TG_LAST_MSG_ID")
    done

    # 添加翻页按钮（仅限频道，且成功获取到 message_id 时）
    if [[ -n "${msg_ids[0]:-}" && "${TG_CHAT_ID}" == -100* ]]; then
        local channel_num="${TG_CHAT_ID#-100}"
        local last=$((total - 1))
        local base_url="https://t.me/c/${channel_num}"
        local prefix="${server_label:+${server_label} · }"
        for (( i=0; i<total; i++ )); do
            [[ -z "${msg_ids[$i]:-}" ]] && continue
            local kb="[" row="" col=0
            for (( j=0; j<total; j++ )); do
                local btn_label
                [[ $j -eq $i ]] \
                    && btn_label="${prefix}▶ $((j+1))/${total}" \
                    || btn_label="${prefix}$((j+1))/${total}"
                [[ $col -gt 0 ]] && row+=","
                row+="{\"text\":\"${btn_label}\",\"url\":\"${base_url}/${msg_ids[$j]}\"}"
                col=$(( col + 1 ))
                if [[ $col -eq 2 ]]; then
                    [[ "$kb" != "[" ]] && kb+=","
                    kb+="[${row}]"
                    row=""; col=0
                fi
            done
            [[ -n "$row" ]] && { [[ "$kb" != "[" ]] && kb+=","; kb+="[${row}]"; }
            kb+="]"
            _tg_edit_keyboard "${msg_ids[$i]}" "$kb"
        done
    fi
    return 0
}


# 设置/修改服务器名称（统一入口，写入 TG_CONF）
_set_server_name() {
    local _cur_name=""
    [[ -f "$TG_CONF" ]] && _cur_name=$(grep "^SERVER_NAME=" "$TG_CONF" 2>/dev/null | cut -d= -f2- || true)
    echo -e "  当前名称: ${C_YELLOW}${_cur_name:-（未设置）}${C_RESET}"
    echo -ne "  输入服务器名称 (格式如 🇭🇰SR_HK_Std，回车跳过): "
    local _new_name
    read -r _new_name < /dev/tty
    [[ -z "$_new_name" ]] && return 0
    if [[ -f "$TG_CONF" ]]; then
        local _tmp_sn; _tmp_sn=$(mktemp)
        grep -v "^SERVER_NAME=" "$TG_CONF" > "$_tmp_sn"
        printf 'SERVER_NAME=%s\n' "$_new_name" >> "$_tmp_sn"
        chmod 600 "$_tmp_sn"
        mv "$_tmp_sn" "$TG_CONF"
    else
        printf 'SERVER_NAME=%s\n' "$_new_name" > "$TG_CONF"
        chmod 600 "$TG_CONF"
    fi
    echo -e "  ${C_GREEN}✓ 服务器名称已设为: ${_new_name}${C_RESET}"
    if systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null; then
        systemctl restart "$SSH_TG_SERVICE" 2>/dev/null || true
        echo -e "  ${C_GREEN}✓ SSH TG 服务已重启${C_RESET}"
    fi
}


# ==============================================================================
# SECTION 6: 系统管理模块（来自 iptables+rely.sh）
# ==============================================================================

_safe_iptables_remove_rule() {
    local pattern="$1"
    local grep_flag="${2:--F}"
    local _tmp _bak
    if ! _tmp=$(mktemp /root/.iptfw-XXXXXX 2>/dev/null); then
        echo -e "${RED}错误: mktemp 失败，跳过防火墙规则操作${NC}" >&2
        return 1
    fi
    if ! _bak=$(mktemp /root/.iptfw-bak-XXXXXX 2>/dev/null); then
        rm -f "$_tmp"
        echo -e "${RED}错误: mktemp 失败，跳过防火墙规则操作${NC}" >&2
        return 1
    fi
    chmod 600 "$_tmp" "$_bak"
    local _orig _filtered orig_lines filtered_lines
    _orig=$(iptables-save 2>/dev/null) || { rm -f "$_tmp" "$_bak"; return 1; }
    # 先将当前规则保存到备份，供 restore 失败时回滚
    echo "$_orig" > "$_bak"
    _filtered=$(echo "$_orig" | grep -v "$grep_flag" "$pattern" || true)
    orig_lines=$(echo "$_orig" | wc -l)
    filtered_lines=$(echo "$_filtered" | wc -l)
    if [ "$filtered_lines" -lt $(( orig_lines * 50 / 100 )) ]; then
        echo -e "${RED}错误: 规则过滤结果异常 (${filtered_lines}/${orig_lines} 行)，已中止还原${NC}" >&2
        rm -f "$_tmp" "$_bak"
        return 1
    fi
    echo "$_filtered" > "$_tmp"
    if ! iptables-restore < "$_tmp"; then
        echo -e "${RED}错误: iptables-restore 失败，正在回滚...${NC}" >&2
        iptables-restore < "$_bak" 2>/dev/null || true
        rm -f "$_tmp" "$_bak"
        return 1
    fi
    rm -f "$_tmp" "$_bak"
    return 0
}

# iptables 规则持久化：写入对应发行版的文件路径并调用持久化工具
# 支持 Debian/Ubuntu（/etc/iptables/rules.v4 + netfilter-persistent）
# 和 RHEL/CentOS（/etc/sysconfig/iptables + service iptables save）
_persist_iptables() {
    local _save_file="/etc/iptables/rules.v4"
    [ -f /etc/redhat-release ] && _save_file="/etc/sysconfig/iptables"
    mkdir -p "$(dirname "$_save_file")"
    # 原子写入：先写临时文件再 mv，避免磁盘满/进程被杀时 rules.v4 变空导致重启锁死
    local _tmp_save
    _tmp_save=$(mktemp "$(dirname "$_save_file")/.rules-XXXXXX") || {
        echo -e "${RED}错误: mktemp 失败，无法持久化规则${NC}" >&2; return 1
    }
    chmod 600 "$_tmp_save"
    if ! iptables-save > "$_tmp_save"; then
        rm -f "$_tmp_save"
        echo -e "${RED}错误: iptables-save 写入失败${NC}" >&2
        return 1
    fi
    mv "$_tmp_save" "$_save_file"
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service &>/dev/null && [ -f /etc/redhat-release ]; then
        service iptables save >/dev/null 2>&1 || true
    fi
}


# ==============================================================================
# 共享工具函数 (供多个核心功能复用)
# ==============================================================================

# 写入 IPv6 禁用配置并同步清理 /etc/sysctl.conf 残留条目
# 注释掉 /etc/network/interfaces 里的 IPv6 stanza。
# 不做的话：开机 ifup 去配 IPv6 地址、撞上 disable_ipv6=1 而失败，networking.service
# 永久 failed（IPv4 排在前面仍能起来，但故障列表被这条噪音长期占据）。
# 用标记前缀而非删除 —— 重新启用时要靠这些行读回静态地址。
# 返回 0 = 确实注释了内容；返回 1 = 无需改动（调用方若不关心须加 || true，本脚本 set -e）
_ipv6_ifaces_off() {
    local f=/etc/network/interfaces
    [[ -f "$f" ]] || return 1
    grep -qE '^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet6' "$f" || return 1
    local t; t=$(mktemp) || return 1
    awk '
        /^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet6/ { blk=1; print "#V6OFF# " $0; next }
        blk && /^[[:space:]]+[^[:space:]]/                            { print "#V6OFF# " $0; next }
        { blk=0; print }
    ' "$f" > "$t" && cat "$t" > "$f"   # cat 而非 mv：保住原 inode 和权限
    rm -f "$t"
    return 0
}

_ipv6_ifaces_on() {
    [[ -f /etc/network/interfaces ]] || return 0
    sed -i 's/^#V6OFF# //' /etc/network/interfaces
}

# Debian 装机自带 exim4，默认要绑 IPv6 回环 ::1 —— IPv6 一禁它就必然启动失败，
# 从此常驻 systemctl --failed，把真正的故障淹掉。代理机不需要 MTA，直接卸掉，
# 顺带少一个监听 25 端口的攻击面。反向依赖只有它自己的组件和 bsd-mailx（mail 命令）。
_purge_exim4() {
    # 必须用 grep -c 而非 grep -q：-q 一匹配到就退出并关闭管道，dpkg -l 还剩几百行没写完
    # 便吃到 SIGPIPE 退出 141；本脚本开了 pipefail，整条管道遂返回 141，
    # '|| return 0' 就把「已安装」误判成「未安装」直接返回。-c 会读完全部输入，不留竞态。
    local _n
    _n=$(dpkg -l 2>/dev/null | grep -cE '^ii[[:space:]]+exim4' || true)
    [[ "${_n:-0}" -gt 0 ]] || return 0
    echo -e "  ${CYAN}⟳${NC} 检测到 exim4（Debian 自带邮件服务）"
    echo -e "    IPv6 已禁用，它绑不上 ::1 必然启动失败；代理机也用不到 MTA，正在卸载..."
    systemctl stop exim4 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        exim4 exim4-base exim4-config exim4-daemon-light bsd-mailx >/dev/null 2>&1 || true
    systemctl reset-failed exim4.service 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} exim4 已卸载"
}

_write_disable_ipv6_conf() {
    _ipv6_ifaces_off || true
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'IPVCEOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPVCEOF
    if [ -f "/etc/sysctl.conf" ]; then
        sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
        sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
        sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# Swap 检测与自动创建（未启用时按磁盘剩余空间动态分配）
_ensure_swap() {
    local _free_kb _free_mb _size_mb=1024
    # 若存在临时 Swap 标志（XanMod 安装前创建的），先拆除再按实际磁盘重建
    if [ -f /tmp/.swap_is_temp ]; then
        echo -e "  ${YELLOW}检测到临时 Swap，按当前磁盘重新计算...${NC}"
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile /tmp/.swap_is_temp
        sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    fi
    local _swap_kb _swap_mb
    _swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}' || echo 0)
    _swap_mb=$(( ${_swap_kb:-0} / 1024 ))
    if [ "$_swap_mb" -gt 0 ]; then
        echo -e "  Swap 状态: ${GREEN}已启用 (${_swap_mb} MB)${NC}"
        return
    fi
    _free_kb=$(df -k / | awk 'NR==2 {print $4}' || echo 0)
    _free_mb=$(( ${_free_kb:-0} / 1024 ))
    [ "$_free_mb" -ge 20480 ] && _size_mb=2048
    [ "$_free_mb" -lt 2048  ] && _size_mb=512
    echo -e "  ${YELLOW}未启用 Swap，磁盘剩余 ${_free_mb}MB → 创建 ${_size_mb}MB...${NC}"
    if [ ! -f /swapfile ]; then
        fallocate -l "${_size_mb}M" /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count="$_size_mb" status=none
    fi
    chmod 600 /swapfile
    if ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        mkswap /swapfile >/dev/null 2>&1 || { echo -e "  ${RED}✗ mkswap 失败${NC}"; return; }
        swapon /swapfile >/dev/null 2>&1 || { echo -e "  ${RED}✗ swapon 失败${NC}"; return; }
    fi
    grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "  ${GREEN}✓ /swapfile (${_size_mb}MB) 已创建并挂载${NC}"
}

# 8 线程并发测速 → Cloudflare，结果写入全局 _BW_MBPS
# 调用前先 printf "测速中..." 提示，本函数用 \r 覆盖同一行打印结果
_measure_bandwidth() {
    local _default=${1:-1000}
    _BW_MBPS=$_default
    local _tmpdir _threads=8 _i _pid _pids=()
    _tmpdir=$(mktemp -d) || { _BW_MBPS=$_default; return 0; }
    for _i in $(seq 1 $_threads); do
        curl -4 -o /dev/null -s --max-time 15 \
            -w "%{speed_download}" \
            "https://speed.cloudflare.com/__down?bytes=10485760" \
            > "${_tmpdir}/spd_${_i}" 2>/dev/null &
        _pids+=($!)
    done
    # 注册信号处理：Ctrl+C 时杀掉全部 curl 子进程，避免孤儿进程继续占用带宽
    trap 'kill "${_pids[@]}" 2>/dev/null; rm -rf "$_tmpdir"; trap - INT TERM' INT TERM
    for _pid in "${_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    trap - INT TERM
    local _total_bytes=0 _v
    for _i in $(seq 1 $_threads); do
        _v=$(cat "${_tmpdir}/spd_${_i}" 2>/dev/null)
        _v=${_v%%.*}
        [[ "${_v:-0}" =~ ^[0-9]+$ ]] && _total_bytes=$(( _total_bytes + _v ))
    done
    rm -rf "$_tmpdir"
    if [[ $(( _total_bytes / 1048576 )) -gt 0 ]]; then
        _BW_MBPS=$(( _total_bytes * 8 / 1000000 ))
        [ "$_BW_MBPS" -lt 1 ] && _BW_MBPS=1
        echo -e "\r  实测下行: ${GREEN}${_BW_MBPS} Mbps${NC}                              "
    else
        echo -e "\r  ${YELLOW}⚠ 测速失败，使用默认值 ${_default} Mbps${NC}              "
    fi
}

# 根据物理内存和带宽计算 sysctl 动态参数，结果写入全局 _P_* 变量
_calc_sysctl_params() {
    local _pmem=$1 _bw=$2 _role=${3:-transit}
    local _rmem_ram_cap=$(( _pmem * 1048576 / 10 ))  # 10% RAM 上限
    # tcp_mem 全局池 (单位: 4KB 页) — 硬上限 ≈ 14% RAM
    # 内核默认约 8% RAM；中转高并发(实测 .197 晚高峰 200+ 连接)易在旧默认(920M机=74MB)撞墙，
    # 进内存压力模式后内核强收每连接缓冲拖垮吞吐。抬到 ~14% RAM，实测 93MB 峰值稳在压力线下。
    _P_TCP_MEM_MAX=$(( _pmem * 256 * 14 / 100 ))         # 硬上限 ≈ 14% RAM
    _P_TCP_MEM_PRESSURE=$(( _P_TCP_MEM_MAX * 3 / 4 ))    # 压力档 = 75% 硬上限
    _P_TCP_MEM_LOW=$(( _P_TCP_MEM_MAX / 2 ))             # 压力起 = 50% 硬上限
    # rmem_max = BDP @ 200ms RTT (代理中继最远链路基准)
    # 旧值 bw*50000 = BDP@400ms, BBR 探测窗口是实际 BDP 的 4× → 拥塞路径(HK-SEA/Chicago)重传爆表
    # cap=64MB: 覆盖高带宽落地(HKT 2.5Gbps × 129ms BDP=25.8MB，adv_win_scale=1时需socket≥51MB)
    _P_RMEM_MAX=$(( _bw * 25000 ))
    [ "$_P_RMEM_MAX" -lt 8388608  ] && _P_RMEM_MAX=8388608    # min 8MB
    [ "$_P_RMEM_MAX" -gt 67108864 ] && _P_RMEM_MAX=67108864   # max 64MB
    [ "$_P_RMEM_MAX" -gt "$_rmem_ram_cap" ] && _P_RMEM_MAX=$_rmem_ram_cap
    # per-socket 上限再受 tcp_mem 全局池约束，防单连接吃爆池(旧配置 25MB > 池 74MB，3 条即爆)。
    # 并发数无法从带宽/内存推出，故按机器角色分档:
    #   优化线路(transit,高并发,百+连接) → 池/16：.197 1000M口=8MB(6天实测验证)
    #   落地(edge,低并发,≤10条中转规则也算)→ 池/4 ：单连接放宽到跑满 BDP，不被池子枷锁
    _P_ROLE="$_role"
    local _pool_div=16; [ "$_role" = "edge" ] && _pool_div=4
    local _pool_cap=$(( _P_TCP_MEM_MAX * 4096 / _pool_div ))
    [ "$_P_RMEM_MAX" -gt "$_pool_cap" ] && _P_RMEM_MAX=$_pool_cap
    [ "$_P_RMEM_MAX" -lt 8388608  ] && _P_RMEM_MAX=8388608    # 复位 min 8MB
    # tcp_rmem middle / rmem_default = BDP @ 20ms RTT (国内/日韩典型延迟)
    # TCP 自动调优会从此值按需增长到 rmem_max，无需把 default 设得很大
    # 封顶 8MB：避免大量连接时虚拟内存过度占用，高延迟路径由自动调优覆盖
    _P_TCP_RMEM_MID=4194304    # 固定 4MB：BDP@10ms@3Gbps=3.75MB，覆盖亚洲路径无需爬坡，自动调优按需涨到 rmem_max
    _P_CONNTRACK_MAX=$(( _pmem * 256 ))
    [ "$_P_CONNTRACK_MAX" -gt 4194304 ] && _P_CONNTRACK_MAX=4194304
    [ "$_P_CONNTRACK_MAX" -lt 131072  ] && _P_CONNTRACK_MAX=131072
    _P_SOMAXCONN=$(( _pmem * 16 ))
    [ "$_P_SOMAXCONN" -gt 65535 ] && _P_SOMAXCONN=65535
    [ "$_P_SOMAXCONN" -lt 1024  ] && _P_SOMAXCONN=1024
    _P_TW_BUCKETS=$(( _pmem * 128 ))
    [ "$_P_TW_BUCKETS" -lt 131072 ] && _P_TW_BUCKETS=131072
    _P_NETDEV_BACKLOG=$(( _pmem * 8 ))
    [ "$_P_NETDEV_BACKLOG" -gt 32768 ] && _P_NETDEV_BACKLOG=32768
    [ "$_P_NETDEV_BACKLOG" -lt 1000  ] && _P_NETDEV_BACKLOG=1000
    # 带宽 ≥ 1Gbps 时下限提升至 16384，避免 3G/5G 高速端口 softirq 丢包
    [ "$_bw" -ge 1000 ] && [ "$_P_NETDEV_BACKLOG" -lt 16384 ] && _P_NETDEV_BACKLOG=16384
    _P_FS_FILE_MAX=$(( _pmem * 256 ))
    [ "$_P_FS_FILE_MAX" -lt 1000000 ] && _P_FS_FILE_MAX=1000000
    # net.ipv4.udp_mem 单位是内存页数 (4KB/页)，需先换算: MB → 字节 → 页数
    _P_UDP_MEM_MAX=$(( _pmem * 1024 * 1024 / 4096 / 4 ))
    _P_UDP_MEM_PRESSURE=$(( _P_UDP_MEM_MAX * 3 / 4 ))
    [ "$_P_UDP_MEM_MAX"      -lt 32768 ] && _P_UDP_MEM_MAX=32768
    [ "$_P_UDP_MEM_PRESSURE" -lt 8192  ] && _P_UDP_MEM_PRESSURE=8192
    [ "$_P_UDP_MEM_PRESSURE" -gt "$_P_UDP_MEM_MAX" ] && _P_UDP_MEM_PRESSURE=$_P_UDP_MEM_MAX
    return 0
}

# nf_conntrack 模块就绪后逐条强制写入（sysctl --system 不保证模块已初始化）
_apply_conntrack_sysctl() {
    local _ctmax=${1:-131072}
    # 确保模块开机提前加载（在 sysctl --system 之前），防止参数写入失败
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_max="$_ctmax"               >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30     >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30      >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15    >/dev/null 2>&1 || true
}

# 设置 /etc/security/limits.conf nofile 上限为 512000
_apply_nofile_limits() {
    # limits.conf: '*' does NOT match root, so we set both wildcard and root explicitly
    local _lc=/etc/security/limits.conf
    for _u in "*" "root"; do
        # '*' is a regex metachar; use [*] in patterns to match the literal asterisk
        local _pat; [ "$_u" = "*" ] && _pat='[*]' || _pat="$_u"
        if grep -q "^${_pat} soft nofile" "$_lc" 2>/dev/null; then
            sed -i "s|^${_pat} soft nofile.*|${_u} soft nofile 512000|" "$_lc"
        else
            echo "${_u} soft nofile 512000" >> "$_lc"
        fi
        if grep -q "^${_pat} hard nofile" "$_lc" 2>/dev/null; then
            sed -i "s|^${_pat} hard nofile.*|${_u} hard nofile 512000|" "$_lc"
        else
            echo "${_u} hard nofile 512000" >> "$_lc"
        fi
    done
    # systemd: DefaultLimitNOFILE covers system services (including sshd)
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=512000\n' > /etc/systemd/system.conf.d/nofile-limits.conf
    printf '[Manager]\nDefaultLimitNOFILE=512000\n' > /etc/systemd/user.conf.d/nofile-limits.conf
    systemctl daemon-reload 2>/dev/null || true
    # profile.d fallback: catches any shell not covered by PAM/systemd
    printf 'ulimit -n 512000 2>/dev/null || true\n' > /etc/profile.d/nofile-limits.sh
    chmod 644 /etc/profile.d/nofile-limits.sh
}

_apply_journald_limits() {
    local conf="/etc/systemd/journald.conf"
    [ -f "$conf" ] || return
    local changed=0
    _jd_set() {
        local key="$1" val="$2"
        if grep -qE "^#?${key}=" "$conf"; then
            sed -i "s|^#\?${key}=.*|${key}=${val}|" "$conf" && changed=1
        else
            printf '%s=%s\n' "$key" "$val" >> "$conf" && changed=1
        fi
    }
    _jd_set SystemMaxUse      100M
    _jd_set SystemMaxFileSize  20M
    _jd_set RuntimeMaxUse      20M
    _jd_set MaxRetentionSec    7day
    [ "$changed" -eq 1 ] && systemctl restart systemd-journald 2>/dev/null || true
}

# 写入 sysctl 配置文件（唯一入口，避免双份不一致）
# 调用前必须已运行 _calc_sysctl_params，_P_* 全局变量已就绪
# 用法: _write_sysctl_conf <bw_mbps> <phys_mem_mb> <cc>
_write_sysctl_conf() {
    local bw_mbps="$1" phys_mem_mb="$2" cc="$3"
    # H-01 断言：确保在调用前已运行 _calc_sysctl_params，避免关键参数为 0 导致写入无效配置
    if [[ "${_P_SOMAXCONN:-0}" -eq 0 || "${_P_RMEM_MAX:-0}" -eq 0 ]]; then
        echo -e "${RED}BUG: _write_sysctl_conf 被调用前未初始化 _P_* 参数，已中止${NC}" >&2
        return 1
    fi
    local _sw_val=10
    [ "$phys_mem_mb" -ge 400 ] && _sw_val=5
    local _min_free_kb=$(( phys_mem_mb * 1024 * 6 / 100 ))
    [ "$_min_free_kb" -lt 32768  ] && _min_free_kb=32768   # 下限 32MB
    [ "$_min_free_kb" -gt 131072 ] && _min_free_kb=131072  # 上限 128MB
    cat > /etc/sysctl.d/99-custom-tuning.conf <<EOF
# ============================================================
# 动态调优 | 带宽: ${bw_mbps}Mbps | RAM: ${phys_mem_mb}MB | RTT基准: 200ms
# 生成时间: $(TZ="$TZ_DEFAULT" date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- 拥塞控制 & 队列调度 ---
# default_qdisc=fq: 内核级 sysctl 对新建接口生效；
# 已有接口须由 do_quick_init 末尾的 tc 命令显式更新
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}

# --- 基础协议标志 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1

# --- 重传 & 乱序优化 (实测调优，适合代理中转场景) ---
# frto=2: F-RTO 检测伪超时重传，对 HK→LA(143ms)/JP→LA(97ms) 等长RTT路径有效
# ecn=2:  仅在对端支持时启用 ECN，通过拥塞信号替代丢包，减少不必要重传
# mtu_probing=1: 防 MTU 黑洞（LA节点 MTU=1350），避免静默超时
# reordering=6: 乱序容忍度提高，减少 Fast-Retransmit 误触发
# notsent_lowat=16384: 更早唤醒发送端补充数据，降低代理实时延迟
net.ipv4.tcp_frto = 2
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_reordering = 6
net.ipv4.tcp_notsent_lowat = 16384

# --- 超时 & 故障检测 ---
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 500
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# 出站临时端口段，与入站监听口段（脚本 RAND_PORT_MIN/MAX = 55000-65535）错开，
# 避免同机"监听口 vs 出站源端口"撞号。45000 个口，足够高并发出站不耗尽
net.ipv4.ip_local_port_range = 10000 54999
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 6
net.ipv4.tcp_orphan_retries = 1

# --- Conntrack 超时 ---
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15

# --- 系统调度 & 内存管理 ---
kernel.sched_autogroup_enabled = 0
vm.swappiness = ${_sw_val}
vm.min_free_kbytes = ${_min_free_kb}
vm.vfs_cache_pressure = 50

# --- 容量类 动态计算 (RAM: ${phys_mem_mb}MB) ---
fs.file-max = ${_P_FS_FILE_MAX}
net.core.somaxconn = ${_P_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = $(( _P_SOMAXCONN * 4 ))
net.ipv4.tcp_max_tw_buckets = ${_P_TW_BUCKETS}
net.core.netdev_max_backlog = ${_P_NETDEV_BACKLOG}
net.netfilter.nf_conntrack_max = ${_P_CONNTRACK_MAX}

# --- Buffer 类 动态计算 (${bw_mbps}Mbps | 角色:${_P_ROLE:-transit} | rmem_max=min(BDP@200ms,池/N) | tcp_mem≈14%RAM | default=4MB) ---
net.ipv4.tcp_mem = ${_P_TCP_MEM_LOW} ${_P_TCP_MEM_PRESSURE} ${_P_TCP_MEM_MAX}
net.core.rmem_max = ${_P_RMEM_MAX}
net.core.wmem_max = ${_P_RMEM_MAX}
net.ipv4.tcp_rmem = 4096 ${_P_TCP_RMEM_MID} ${_P_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${_P_TCP_RMEM_MID} ${_P_RMEM_MAX}
net.core.rmem_default = ${_P_TCP_RMEM_MID}
net.core.wmem_default = ${_P_TCP_RMEM_MID}

# --- UDP 动态计算 (单位: 内存页 4KB) ---
net.ipv4.udp_mem = 8192 ${_P_UDP_MEM_PRESSURE} ${_P_UDP_MEM_MAX}
EOF
}


# ==============================================================================
# 核心功能 1: 端口/IP 验证工具 (validate_ip_cidr / get_current_ssh_port)
# 核心功能 2: 防火墙初始化
# ==============================================================================

validate_ip_cidr() {
    local input="$1"
    [[ "$input" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]] || return 1
    local o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]} prefix=${BASH_REMATCH[6]}
    [[ $o1 -le 255 && $o2 -le 255 && $o3 -le 255 && $o4 -le 255 ]] || return 1
    [[ -z "$prefix" || ( $prefix -ge 0 && $prefix -le 32 ) ]] || return 1
    return 0
}

get_current_ssh_port() {
    local port=""
    # 主配置文件
    [ -r /etc/ssh/sshd_config ] && port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | tail -n 1 || true)
    # drop-in 目录优先级更高，无条件覆盖主配置的值
    if [ -d /etc/ssh/sshd_config.d ]; then
        local _dropin
        _dropin=$(grep -rhiE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
        [ -n "$_dropin" ] && port="$_dropin"
    fi
    # 兜底：从实际监听端口读取
    [ -z "$port" ] && command -v ss >/dev/null && port=$(ss -tlnp 2>/dev/null | grep -iE 'sshd|ssh' | sed -n 's/.*:\([0-9]\{1,5\}\).*/\1/p' | head -n 1 || true)
    echo "${port:-22}"
}

confirm_ssh_port() {
    local p=$1
    # 检测 /dev/tty 可用性，避免在非交互环境（管道/CI/SSH heredoc）中 read < /dev/tty 死锁
    if [ -t 0 ] && [ -e /dev/tty ]; then
        echo -e "\n${YELLOW}检测到 SSH 端口: ${GREEN}${p}${NC}" > /dev/tty
        echo -ne "${BLUE}确认使用此端口? (回车确认, 或输入其他): ${NC}" > /dev/tty
        local c
        read -r c < /dev/tty
        c=$(echo "$c" | tr -d '[:space:]')
        [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le 65535 ] && echo "$c" || echo "$p"
    else
        # 非交互环境直接沿用检测值，避免死锁
        echo "$p"
    fi
}

_harden_sshd() {
    local _cfg=/etc/ssh/sshd_config
    if [ ! -f "$_cfg" ]; then
        echo -e "  ${YELLOW}⚠ sshd_config 未找到，跳过 SSH 加固${NC}"
        return 0
    fi
    # 备份原始配置
    cp -f "$_cfg" "${_cfg}.bak.$(TZ="$TZ_DEFAULT" date +%Y%m%d%H%M%S)" 2>/dev/null || true
    # 幂等写入：先删除所有相关行（含注释行），再追加
    _sshd_set() {
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${1}[[:space:]]/d" "$_cfg"
        echo "${1} ${2}" >> "$_cfg"
    }
    _sshd_set MaxAuthTries 3
    _sshd_set LoginGraceTime 30
    # 验证语法后才重载，失败则从备份恢复
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        echo -e "  ${GREEN}✓ SSH 加固: MaxAuthTries=3  LoginGraceTime=30${NC}"
    else
        echo -e "  ${RED}✗ sshd 配置语法错误，正在从备份恢复...${NC}"
        local _bak
        _bak=$(ls -t "${_cfg}.bak."* 2>/dev/null | head -1 || true)
        [ -n "$_bak" ] && cp -f "$_bak" "$_cfg" && \
            systemctl reload sshd 2>/dev/null || true
    fi
}

# 防火墙 flush 后重新放行所有代理监听端口（Realm 中转 / Snell 落地 / Shadowsocks）。
# iptables -F 会清掉 open_firewall_port 之前加的放行规则，若不重建，重置防火墙会
# 把 50+ 条中转端口全部关闭（已建立连接靠 ESTABLISHED 存活，但新连接全部被 DROP）。
_firewall_reopen_proxy_ports() {
    local _ports=() _p _f _seen=" " _cnt=0
    # Realm 转发监听端口
    if [[ -f "$REALM_CONFIG_FILE" ]]; then
        while IFS= read -r _p; do [[ "$_p" =~ ^[0-9]+$ ]] && _ports+=("$_p"); done \
            < <(jq -r '.endpoints[]?.listen | split(":")[-1]' "$REALM_CONFIG_FILE" 2>/dev/null)
    fi
    # Snell 多实例端口（文件名 snell-<port>.conf）
    if [[ -d "$SNELL_CONFIG_DIR" ]]; then
        while IFS= read -r _p; do [[ "$_p" =~ ^[0-9]+$ ]] && _ports+=("$_p"); done \
            < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null \
                | grep -oP 'snell-\K[0-9]+(?=\.conf)')
    fi
    # sing-box 各协议监听端口（ss/socks/hy2 的 env 文件名即端口）
    if [[ -d "$SBX_ST" ]]; then
        for _f in "$SBX_ST"/ss-*.env "$SBX_ST"/socks-*.env "$SBX_ST"/hy2-*.env; do
            [[ -e "$_f" ]] || continue
            _p=$(basename "$_f"); _p=${_p#*-}; _p=${_p%.env}
            [[ "$_p" =~ ^[0-9]+$ ]] && _ports+=("$_p")
        done
    fi
    [[ ${#_ports[@]} -eq 0 ]] && return 0
    # 逐个放行（tcp+udp，与 open_firewall_port 一致），插到 INPUT 顶部；
    # 去重，且必须在配额暂停规则之前执行——暂停端口的 DROP 会 -I 到更顶部从而压制此放行。
    for _p in "${_ports[@]}"; do
        [[ "$_seen" == *" $_p "* ]] && continue
        _seen+="$_p "
        iptables -C INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport "$_p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p udp --dport "$_p" -j ACCEPT 2>/dev/null || true
        (( _cnt++ )) || true
    done
    echo -e "  ${GREEN}✓ 已重新放行 ${_cnt} 个代理端口 (Realm/Snell/SS)${NC}"
}

# 防火墙 flush 后重建独立策略链：代理端口、配额计数/暂停、CN 封禁、TCPing
# 这些规则不属于基础防火墙策略，iptables -F/-X 会一并清掉，需据持久化状态重建，
# 否则已超量/已到期的端口会被误开放，CN 封禁与 TCPing 短暂失效。
# $1 = 重置前被 CN 封禁的端口列表（空格分隔；flush 后逐端口重建）
_firewall_reapply_extras() {
    local _cn_ports_was="${1:-}"

    # 先放行所有代理端口（必须在配额暂停之前，暂停端口的 DROP 会插到更高优先级压制它）
    _firewall_reopen_proxy_ports

    # 配额：计数链 + 已暂停端口的 DROP（暂停状态持久化在 QUOTA_DATA，独立于 iptables）
    if [[ -f "$QUOTA_CONFIG" ]] && grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null; then
        quota_init 2>/dev/null || true
        if [[ -f "$QUOTA_DATA" ]]; then
            local _qp _qm _qi _qo _qai _qao _qpaused _qreason
            while IFS='|' read -r _qp _qm _qi _qo _qai _qao _qpaused _qreason; do
                [[ "$_qp" =~ ^[0-9]+$ ]] || continue
                [[ "$_qpaused" == "1" ]] && quota_pause_port "$_qp" "${_qreason:-manual}" 2>/dev/null || true
            done < "$QUOTA_DATA"
        fi
    fi

    # CN 封禁（逐端口重建被封禁端口）
    local _p; for _p in $_cn_ports_was; do _sbx_cn_enable "$_p" 2>/dev/null || true; done

    # TCPing 监控端口
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null && [[ -f "$TCPING_CONFIG_FILE" ]]; then
        local _tp; _tp=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
        if [[ "$_tp" =~ ^[0-9]+$ ]]; then
            iptables -C INPUT -p tcp --dport "$_tp" -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
                -m comment --comment "tcping-monitor-${_tp}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p tcp --dport "$_tp" -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
                -m comment --comment "tcping-monitor-${_tp}" -j ACCEPT 2>/dev/null || true
        fi
    fi

    # f2b 白名单（管理 IP 免疫）：放最后，-I INPUT 1 使其落在链顶部、优先级最高，
    # 确保白名单 IP 不被 SSH 限速/配额等规则误伤。函数内部已含 _persist_iptables。
    _f2b_apply_all_iptables 2>/dev/null || true

    _persist_iptables 2>/dev/null || true
}

do_init_firewall() {
    local _auto=0; [[ "${1:-}" == "--auto" ]] && _auto=1

    echo -e "${GREEN}================================================${NC}"
    echo -e "${L_CYAN}       防火墙安全策略初始化${NC}"
    echo -e "${GREEN}================================================${NC}"

    if ! command -v iptables >/dev/null 2>&1 || ! command -v iptables-save >/dev/null 2>&1 || \
       ! command -v iptables-restore >/dev/null 2>&1 || ! command -v at >/dev/null 2>&1; then
        echo -e "${RED}错误: 缺少依赖 (iptables/iptables-save/iptables-restore/at)，请先执行 [1] 安装依赖。${NC}"
        return
    fi

    # 记录重置前的独立策略状态，flush 后据此重建（避免误开放已暂停/封禁端口）
    local _cn_was_on=0 _cn_ports_was=""
    _cn_ports_was=$(_sbx_cn_blocked)
    [[ -n "$_cn_ports_was" ]] && _cn_was_on=1

    # 这里的逻辑是确保只有 iptables 在运行，避免 ufw/firewalld 干扰
    echo -e "${CYAN}正在检查并关闭冲突的防火墙服务 (ufw/firewalld)...${NC}"
    systemctl stop ufw >/dev/null 2>&1 || true
    systemctl disable ufw >/dev/null 2>&1 || true
    systemctl stop firewalld >/dev/null 2>&1 || true
    systemctl disable firewalld >/dev/null 2>&1 || true

    local mode_choice
    if [[ $_auto -eq 1 ]]; then
        mode_choice=1
    else
        echo -e "\n请选择防火墙模式:"
        echo -e " 1. ${GREEN}[推荐] 安全模式${NC} (仅开放 SSH/Web 端口，默认拒绝)"
        echo -e " 2. ${RED}[危险] 开放模式${NC} (关闭防火墙，放行所有流量)"
        echo -ne "${BLUE}请选择 [1-2] (1): ${NC}"
        read -r mode_choice
        mode_choice=${mode_choice:-1}
    fi

    if [ "$mode_choice" = "2" ]; then
        # --- 开放模式 (Disable Firewall) ---
        echo -e "\n${RED}>>> 正在执行: 关闭防火墙 (全放行)${NC}"
        
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
        iptables -X
        
        echo -e "策略状态: ${RED}ACCEPT (All Allowed)${NC}"
        
        if _persist_iptables; then
            echo -e "${GREEN}✓ 防火墙已关闭，策略已保存。${NC}"
            if [ "$_cn_was_on" = "1" ] || { [ -f "$QUOTA_CONFIG" ] && grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null; }; then
                echo -e "${YELLOW}⚠ 开放模式已清除 CN 封禁/配额暂停规则；配额定时器将在下轮(≤5min)重新强制限额。${NC}"
            fi
        else
            echo -e "${RED}保存失败!${NC}"
        fi
        return
    fi

    # --- 安全模式 (标准逻辑) ---
    local ssh_port
    ssh_port=$(get_current_ssh_port)
    if [[ $_auto -eq 0 ]]; then
        ssh_port=$(confirm_ssh_port "$ssh_port")
    else
        echo -e "\n${YELLOW}检测到 SSH 端口: ${GREEN}${ssh_port}${NC}"
    fi
    
    echo -e "\n${YELLOW}正在设置安全网 (2分钟后自动恢复)...${NC}"
    
    local revert_script
    revert_script=$(mktemp /root/.iptfw-revert-XXXXXX)
    chmod 700 "$revert_script"
    # 使用局引号 '\''EOF'\'' 阻止 shell 变量展开（防止 $0 注入）
    cat > "$revert_script" <<'REVERT_EOF'
#!/bin/bash
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
# N-01 修复: 支持 RHEL/CentOS 路径 (/etc/sysconfig/iptables)
_f=/etc/iptables/rules.v4
[ -f /etc/redhat-release ] && _f=/etc/sysconfig/iptables
mkdir -p "$(dirname "$_f")"
iptables-save > "$_f"
REVERT_EOF
    # 单独写入自删除逻辑，避免在 heredoc 内展开 $revert_script 变量
    echo "rm -f \"${revert_script}\"" >> "$revert_script"

    # 清理上次遗留的安全网作业，防止重复执行时多个 at 作业同时触发
    atq 2>/dev/null | awk '{print $1}' | while read -r _jid; do
        at -c "$_jid" 2>/dev/null | grep -q "iptfw-revert" && atrm "$_jid" 2>/dev/null || true
    done

    local job_id _at_out
    # S-01 修复：分离 at 与 grep，独立检测 at 的退出码
    # 若用管道 at | grep，set -e 下 grep 失败会掩盖 at 失败，导致安全网未建立但 DROP 策略已收紧
    if ! _at_out=$(at now + 2 minutes < "$revert_script" 2>&1); then
        echo -e "${RED}错误: at 命令执行失败（exit $?），无法创建安全网。${NC}" >&2
        rm -f "$revert_script"
        return
    fi
    job_id=$(echo "$_at_out" | grep -oP 'job \K[0-9]+' || echo "")

    if [ -z "$job_id" ]; then
        echo -e "${RED}错误: 无法解析 at job ID（atd 是否运行？）${NC}" >&2
        rm -f "$revert_script"
        return
    fi

    echo -e "${CYAN}正在应用防火墙策略 (Secure Mode)...${NC}"
    # 先清空规则（此时策略仍为 ACCEPT，不会断联）
    iptables -F
    iptables -X

    # 先添加所有 ACCEPT 规则，再收紧策略，消除断联窗口
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # SSH 速率限制：60s 内同 IP 超 15 次新连接先 LOG 再 DROP
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --set
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --rcheck --seconds 60 --hitcount 16 \
        -j LOG --log-prefix "SSH-BRUTE: " --log-level 4
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --rcheck --seconds 60 --hitcount 16 \
        -j DROP
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    # 不默认放行 80/443：本脚本不签证书（Hy2 用自签证书跑随机高位口），也不跑 web 服务。
    # 留着只是白给一个例外——万一 apt 顺带装进 nginx 之类，它会立刻暴露在公网。
    # 需要时用「防火墙规则 → 开放端口」按需开。
    iptables -A INPUT -p icmp --icmp-type 8 -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    # PMTUD: Destination Unreachable (type 3) 和 TTL Exceeded (type 11) 必须放行，
    # 否则 conntrack RELATED 无法覆盖所有 ICMP 错误，导致 MTU 黑洞
    iptables -A INPUT -p icmp --icmp-type 3 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type 11 -j ACCEPT

    iptables -P OUTPUT ACCEPT
    # ip_forward=1 已在 sysctl 中开启，放行已建立连接的转发流量（Realm/中继场景）
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # 记录被拦截流量，供选项 14 查看运行状态日志使用（限速 5/min 防止日志洪泛）
    iptables -A INPUT -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "IPT-DROP: " --log-level 4
    # 最后收紧默认策略（ACCEPT 规则已就位，不会断联）
    # 注意: iperf3 端口 (5201) 不在此处自动开放，如需测速请在菜单 [5] 手动开放
    iptables -P INPUT DROP
    iptables -P FORWARD DROP

    if _persist_iptables; then
        echo -e "${GREEN}✓ 策略应用成功并已保存。${NC}"
        echo -e "${GREEN}✓ 正在移除安全网...${NC}"
        atrm "$job_id" 2>/dev/null || true
        rm -f "$revert_script"
        # 重建被 flush 清掉的配额/CN封禁/TCPing 规则
        _firewall_reapply_extras "$_cn_ports_was"
        _harden_sshd
    else
        echo -e "${RED}保存失败! 可能是权限或路径问题。${NC}"
        echo -e "${YELLOW}安全网将在 2 分钟后自动回滚，请勿重启机器。${NC}"
    fi
}


# ==============================================================================
# UI 显示 (仪表盘)
# ==============================================================================

# policy 和 ir 由 show_menu 在调用前设置
_port_dot() {
    local port="$1" label="$2"
    if [ "$policy" == "ACCEPT" ]; then
        echo "$ir" | grep -qE -- "-p tcp.*--dport ${port}[^0-9].*-j DROP" \
            && echo -ne "   ${RED}○ ${label}:${port}${NC}" \
            || echo -ne "   ${L_GREEN}● ${label}:${port}${NC}"
    else
        echo "$ir" | grep -qE -- "-p tcp.*--dport ${port}[^0-9].*-j ACCEPT" \
            && echo -ne "   ${L_GREEN}● ${label}:${port}${NC}" \
            || echo -ne "   ${RED}○ ${label}:${port}${NC}"
    fi
}


toggle_ipv6() {
    clear
    echo -e "${L_BLUE}:: IPv6 管理 ::${NC}"
    
    local is_disabled=0
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        is_disabled=1
    fi
    
    if [ "$is_disabled" -eq 1 ]; then
        echo -e "当前状态: ${RED}已禁用${NC}"
        echo -e "${GREEN}正在开启 IPv6...${NC}"
        
        # 1. 删除禁用配置（先解开 interfaces 里的 IPv6 stanza，下面第 4 步要从中读回静态地址）
        _ipv6_ifaces_on
        rm -f /etc/sysctl.d/99-disable-ipv6.conf
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
        fi
        
        # 2. 内核层面应用 (sysctl)
        sysctl --system >/dev/null 2>&1 || true
        
        # 3. 暴力强制开启 (即使 sysctl 没立即生效)
        # 直接修改运行时的 procfs 参数，无需重启
        echo -e "${CYAN}正在激活网卡 IPv6 协议栈...${NC}"
        for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do 
            echo 0 > "$i" 2>/dev/null
        done
        
        # 4. 尝试获取地址：优先静态配置，fallback DHCPv6
        local ifaces
        ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" || true)

        local _v6_applied=0
        for iface in $ifaces; do
            # 从 /etc/network/interfaces 读取静态 IPv6 配置
            local _v6_addr _v6_gw _v6_dns
            _v6_addr=$(awk "/iface ${iface} inet6 static/{f=1} f && /^[[:space:]]*address/{print \$2; exit}" \
                       /etc/network/interfaces 2>/dev/null || true)
            _v6_gw=$(awk  "/iface ${iface} inet6 static/{f=1} f && /^[[:space:]]*gateway/{print \$2; exit}" \
                       /etc/network/interfaces 2>/dev/null || true)
            if [ -n "$_v6_addr" ]; then
                echo -e "${CYAN}正在应用静态 IPv6 配置 ($iface)...${NC}"
                ip -6 addr add "$_v6_addr" dev "$iface" 2>/dev/null || true
                # 网关可能在不同子网(路由型/64,如 Swiftnode)——普通 add 会因"不在链路"失败，
                # 回退加 onlink 标志强制视为直连。on-link 网关走前一条即可。
                if [ -n "$_v6_gw" ]; then
                    ip -6 route add default via "$_v6_gw" dev "$iface" 2>/dev/null \
                        || ip -6 route add default via "$_v6_gw" dev "$iface" onlink 2>/dev/null || true
                fi
                _v6_applied=1
            fi
        done

        # 无静态配置时 fallback DHCPv6
        if [ "$_v6_applied" -eq 0 ]; then
            echo -e "${CYAN}未检测到静态 IPv6 配置，尝试 DHCPv6...${NC}"
            if command -v dhclient >/dev/null 2>&1; then
                for iface in $ifaces; do
                    timeout 8 dhclient -6 -1 -nw "$iface" >/dev/null 2>&1 || true
                done
            else
                echo -e "${YELLOW}! dhclient 未安装，跳过 DHCPv6 请求${NC}"
            fi
        fi

        # 5. 最终检测：DAD 地址检测与路由收敛需数秒，以【真实出网】为准、多试几次，
        # 避免地址还在 tentative 就误判失败（旧逻辑只 grep 一次 global，脆而不准）。
        local _v6ip=""
        for _i6w in $(seq 1 10); do
            if ping -6 -c1 -W2 2606:4700:4700::1111 >/dev/null 2>&1 \
               || ping -6 -c1 -W2 2001:4860:4860::8888 >/dev/null 2>&1; then
                _v6ip=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}')
                break
            fi
            sleep 1
        done
        if [ -n "$_v6ip" ]; then
            echo -e "${GREEN}✓ IPv6 已开启并可出网：${_v6ip}${NC}"
        elif ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
            _v6ip=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}')
            echo -e "${YELLOW}✓ 已配置全局地址 ${_v6ip}，出网暂不通（供应商未就绪/需重启，或该网络无 IPv6 出口）${NC}"
        elif ip -6 addr | grep -q inet6; then
            echo -e "${YELLOW}✓ IPv6 协议栈已开启（仅本地链路，未获取公网地址）${NC}"
        else
            echo -e "${RED}! IPv6 开启失败。可能需要重启服务器。${NC}"
        fi
        
    else
        echo -e "当前状态: ${GREEN}已开启${NC}"
        echo -ne "${YELLOW}确认禁用 IPv6？默认禁用 [Y/n]: ${NC}"
        read -r _ipv6_confirm
        _ipv6_confirm="${_ipv6_confirm:-Y}"
        if [[ "${_ipv6_confirm,,}" != "y" ]]; then
            echo -e "${CYAN}已取消，IPv6 保持开启状态。${NC}"
            return
        fi
        echo -e "${YELLOW}正在禁用 IPv6...${NC}"
        _write_disable_ipv6_conf

        # 暴力强制禁用
        for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do 
            echo 1 > "$i" 2>/dev/null
        done
        
        echo -e "${RED}✓ IPv6 已禁用${NC}"
    fi
}


# ==============================================================================
# TCPing 监控端口管理
# ==============================================================================

TCPING_SERVICE_NAME="tcping-monitor"
TCPING_CONFIG_FILE="/etc/tcping-monitor.conf"

SSH_TG_SERVICE="ssh-tg-monitor"
SSH_TG_CONF="/etc/ssh-tg-monitor.conf"
SSH_TG_SCRIPT="/usr/local/bin/ssh-tg-monitor.sh"
F2B_WHITELIST="/etc/fail2ban/f2b-whitelist.conf"

# 获取本机公网 IPv4，依次尝试多个源，校验格式后返回


# 查找从 start_port 开始的第一个未占用端口
# 仅依据 ss 实际监听状态判断，不受防火墙规则影响
find_available_port() {
    local start_port=${1:-9999}
    local port=$start_port
    while [ "$port" -le 65535 ]; do
        if ! ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo "0"
    return 1
}

# 静默启用 TCPing 监控（用于一键初始化，不询问用户）
_tcping_setup_silent() {
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _p; _p=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        echo -e "  TCPing: ${C_GREEN}已运行 [端口 ${_p}]（跳过）${C_RESET}"
        return 0
    fi

    if ! command -v socat &>/dev/null; then
        apt-get install -y -qq socat 2>/dev/null || { echo -e "  TCPing: ${C_RED}socat 安装失败，跳过${C_RESET}"; return 1; }
    fi

    if ! id tcping &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin tcping 2>/dev/null || true
    fi

    local monitor_port
    monitor_port=$(find_available_port 9999)
    if [[ "$monitor_port" == "0" ]]; then
        echo -e "  TCPing: ${C_RED}找不到可用端口，跳过${C_RESET}"; return 1
    fi

    if [[ -f "$TCPING_CONFIG_FILE" ]]; then
        local _old_port; _old_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
        [[ -n "$_old_port" ]] && _safe_iptables_remove_rule "tcping-monitor" 2>/dev/null || true
    fi

    printf '# TCPing Monitor Configuration\nPORT=%s\n' "$monitor_port" > "$TCPING_CONFIG_FILE"

    cat > "/etc/systemd/system/${TCPING_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TCPing Monitor Port for Nezha Probe
After=network.target

[Service]
Type=simple
User=tcping
NoNewPrivileges=true
ExecStart=/usr/bin/socat TCP4-LISTEN:${monitor_port},reuseaddr,fork,max-children=100 EXEC:/bin/true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$TCPING_SERVICE_NAME" 2>/dev/null || { echo -e "  TCPing: ${C_RED}服务启动失败${C_RESET}"; return 1; }

    iptables -I INPUT 1 -p tcp --dport "$monitor_port" \
        -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
        -m comment --comment "tcping-monitor-${monitor_port}" -j ACCEPT 2>/dev/null || true
    _persist_iptables 2>/dev/null || true

    echo -e "  TCPing: ${C_GREEN}已启动 [端口 ${monitor_port}]${C_RESET}"
}

do_tcping_monitor() {
    clear
    echo -e "${L_BLUE}:: TCPing 监控端口管理 ::${NC}"
    echo -e "${CYAN}用于哪吒探针等监控系统的 TCPing 延迟检测${NC}\n"
    
    # 检测当前状态
    local current_status="${RED}未运行${NC}"
    local current_port="-"
    
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        current_status="${GREEN}运行中${NC}"
        if [ -f "$TCPING_CONFIG_FILE" ]; then
            current_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        fi
    fi
    
    echo -e "${L_BLUE}[ 当前状态 ]${NC}"
    echo -e "   服务: $current_status"
    if [ "$current_port" != "-" ]; then
        echo -e "   端口: ${GREEN}$current_port${NC}"
        # 获取公网 IPv4 地址
        local public_ip
        public_ip=$(get_public_ip)
        echo -e "   目标: ${GREEN}${public_ip}:${current_port}${NC}  ${CYAN}← 复制到哪吒 Dashboard${NC}"
    fi
    
    echo -e "\n${L_BLUE}[ 操作选项 ]${NC}"
    echo -e "  ${L_GREEN}1.${NC} 创建/重新配置 TCPing 监控端口 ${CYAN}(默认 9999)${NC}"
    echo -e "  ${L_GREEN}4.${NC} 手动指定端口重新安装"
    echo -e "  ${L_GREEN}2.${NC} 停止并移除 TCPing 监控"
    echo -e "  ${L_GREEN}3.${NC} 查看服务状态"
    echo -e "  ${L_GREEN}0.${NC} 返回主菜单"
    
    echo -ne "\n${L_PURPLE}请选择 [1]: ${NC}"
    read -r tcping_choice
    tcping_choice="${tcping_choice:-1}"

    case "$tcping_choice" in
        1)
            # 检查 socat 是否安装
            if ! command -v socat &>/dev/null; then
                echo -e "\n${YELLOW}正在安装 socat...${NC}"
                apt-get update -qq && apt-get install -y -qq socat
                if ! command -v socat &>/dev/null; then
                    echo -e "${RED}安装 socat 失败，请手动安装: apt install socat${NC}"
                    return
                fi
                echo -e "${GREEN}✓ socat 已安装${NC}"
            fi

            # 确保专用隔离用户存在（无 shell、无 home、不可登录）
            if ! id tcping &>/dev/null; then
                useradd --system --no-create-home --shell /usr/sbin/nologin tcping
                echo -e "${GREEN}✓ 专用用户 tcping 已创建${NC}"
            fi
            
            local monitor_port
            monitor_port=$(find_available_port 9999)
            if [ "$monitor_port" = "0" ]; then
                echo -e "${RED}错误: 无法找到可用端口 (9999-65535)${NC}"; return
            fi
            echo -e "  ${CYAN}自动选定端口: ${GREEN}${monitor_port}${NC}"
            
            echo -e "\n${CYAN}正在配置 TCPing 监控端口...${NC}"
            
            # 停止旧服务并清理孤儿进程
            systemctl stop "$TCPING_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$TCPING_SERVICE_NAME" 2>/dev/null || true
            pkill -9 -f "socat.*${monitor_port}" 2>/dev/null || true
            
            # 清理旧的防火墙规则
            if [ -f "$TCPING_CONFIG_FILE" ]; then
                local old_port
                old_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
                if [ -n "$old_port" ]; then
                    _safe_iptables_remove_rule "tcping-monitor"
                fi
            fi

            # 保存配置
            cat > "$TCPING_CONFIG_FILE" <<EOF
# TCPing Monitor Configuration
PORT=$monitor_port
EOF
            
            # 创建 systemd 服务
            cat > "/etc/systemd/system/${TCPING_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TCPing Monitor Port for Nezha Probe
After=network.target

[Service]
Type=simple
User=tcping
NoNewPrivileges=true
ExecStart=/usr/bin/socat TCP4-LISTEN:${monitor_port},reuseaddr,fork,max-children=100 EXEC:/bin/true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            
            systemctl daemon-reload 2>/dev/null || true
            if ! systemctl enable --now "$TCPING_SERVICE_NAME" 2>/dev/null; then
                echo -e "${RED}✗ 服务启动失败，防火墙规则未写入，请检查: journalctl -u $TCPING_SERVICE_NAME${NC}"
                return
            fi

            # 每源 IP 最多 3 个并发连接，防单 IP 连接洪水；不影响多节点监控（各 IP 独立计数）
            iptables -I INPUT 1 -p tcp --dport "$monitor_port" \
                -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
                -m comment --comment "tcping-monitor-$monitor_port" -j ACCEPT

            _persist_iptables
            
            # 验证服务状态
            sleep 1
            if systemctl is-active --quiet "$TCPING_SERVICE_NAME"; then
                echo -e "${GREEN}✓ TCPing 监控服务已启动${NC}"
                echo -e "\n${L_BLUE}[ 配置完成 ]${NC}"
                echo -e "   端口: ${GREEN}$monitor_port${NC}"
                echo -e "   状态: ${GREEN}运行中${NC}"
                echo -e "\n${CYAN}在哪吒 Dashboard 添加 TCPing 监控:${NC}"
                # 获取本机公网 IPv4 地址
                local public_ip
                public_ip=$(get_public_ip)
                echo -e "   目标: ${GREEN}${public_ip}:${monitor_port}${NC}"
                echo -e "\n${YELLOW}提示: 此端口仅用于 TCPing 连通性检测，无安全风险${NC}"
            else
                echo -e "${RED}✗ 服务启动失败，请检查日志: journalctl -u $TCPING_SERVICE_NAME${NC}"
            fi
            ;;
        
        2)
            echo -e "\n${YELLOW}正在停止并移除 TCPing 监控...${NC}"
            
            # 停止服务
            systemctl stop "$TCPING_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$TCPING_SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${TCPING_SERVICE_NAME}.service"
            systemctl daemon-reload 2>/dev/null || true
            
            # 清理防火墙规则（按注释 pattern 匹配，不依赖端口号）
            if _safe_iptables_remove_rule "tcping-monitor"; then
                _persist_iptables
                echo -e "${GREEN}✓ 防火墙规则已清理${NC}"
            fi
            
            rm -f "$TCPING_CONFIG_FILE"
            echo -e "${GREEN}✓ TCPing 监控已完全移除${NC}"
            ;;
        
        3)
            echo -e "\n${L_BLUE}[ 服务状态 ]${NC}"
            systemctl status "$TCPING_SERVICE_NAME" --no-pager 2>/dev/null || echo -e "${YELLOW}服务未安装${NC}"
            
            echo -e "\n${L_BLUE}[ 相关防火墙规则 ]${NC}"
            local _tcping_rules
            _tcping_rules=$(iptables -L INPUT -nv --line-numbers 2>/dev/null | grep -E "tcping-monitor" || true)
            if [[ -n "$_tcping_rules" ]]; then
                iptables -L INPUT -nv --line-numbers 2>/dev/null | head -2
                echo "$_tcping_rules"
            else
                echo -e "${YELLOW}无相关规则${NC}"
            fi
            ;;
        
        4)
            # 手动指定端口重新安装
            if ! command -v socat &>/dev/null; then
                echo -e "\n${YELLOW}正在安装 socat...${NC}"
                apt-get update -qq && apt-get install -y -qq socat
                if ! command -v socat &>/dev/null; then
                    echo -e "${RED}安装 socat 失败，请手动安装: apt install socat${NC}"; return
                fi
                echo -e "${GREEN}✓ socat 已安装${NC}"
            fi

            if ! id tcping &>/dev/null; then
                useradd --system --no-create-home --shell /usr/sbin/nologin tcping
                echo -e "${GREEN}✓ 专用用户 tcping 已创建${NC}"
            fi

            local monitor_port
            echo -ne "\n${CYAN}请输入端口号 (1-65535): ${NC}"
            read -r monitor_port
            if [[ ! "$monitor_port" =~ ^[0-9]+$ ]] || [[ "$monitor_port" -lt 1 || "$monitor_port" -gt 65535 ]]; then
                echo -e "${RED}错误: 端口无效${NC}"; return
            fi
            if ss -tuln 2>/dev/null | grep -qE ":${monitor_port}[^0-9]"; then
                echo -e "${RED}错误: 端口 ${monitor_port} 已被占用${NC}"; return
            fi

            echo -e "\n${CYAN}正在配置 TCPing 监控端口...${NC}"

            systemctl stop "$TCPING_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$TCPING_SERVICE_NAME" 2>/dev/null || true
            pkill -9 -f "socat.*${monitor_port}" 2>/dev/null || true

            if [ -f "$TCPING_CONFIG_FILE" ]; then
                local old_port
                old_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
                if [ -n "$old_port" ]; then
                    _safe_iptables_remove_rule "tcping-monitor"
                fi
            fi

            cat > "$TCPING_CONFIG_FILE" <<EOF
# TCPing Monitor Configuration
PORT=$monitor_port
EOF

            cat > "/etc/systemd/system/${TCPING_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TCPing Monitor Port for Nezha Probe
After=network.target

[Service]
Type=simple
User=tcping
NoNewPrivileges=true
ExecStart=/usr/bin/socat TCP4-LISTEN:${monitor_port},reuseaddr,fork,max-children=100 EXEC:/bin/true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload 2>/dev/null || true
            if ! systemctl enable --now "$TCPING_SERVICE_NAME" 2>/dev/null; then
                echo -e "${RED}✗ 服务启动失败，请检查: journalctl -u $TCPING_SERVICE_NAME${NC}"; return
            fi

            iptables -I INPUT 1 -p tcp --dport "$monitor_port" \
                -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
                -m comment --comment "tcping-monitor-$monitor_port" -j ACCEPT

            _persist_iptables

            sleep 1
            if systemctl is-active --quiet "$TCPING_SERVICE_NAME"; then
                echo -e "${GREEN}✓ TCPing 监控服务已启动${NC}"
                echo -e "\n${L_BLUE}[ 配置完成 ]${NC}"
                echo -e "   端口: ${GREEN}$monitor_port${NC}"
                echo -e "   状态: ${GREEN}运行中${NC}"
                echo -e "\n${CYAN}在哪吒 Dashboard 添加 TCPing 监控:${NC}"
                local public_ip
                public_ip=$(get_public_ip)
                echo -e "   目标: ${GREEN}${public_ip}:${monitor_port}${NC}"
                echo -e "\n${YELLOW}提示: 此端口仅用于 TCPing 连通性检测，无安全风险${NC}"
            else
                echo -e "${RED}✗ 服务启动失败，请检查日志: journalctl -u $TCPING_SERVICE_NAME${NC}"
            fi
            ;;

        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${NC}"; sleep 1
            ;;
    esac
}


# ==============================================================================
# 一键参数检测
# ==============================================================================

do_check_all() {
    clear
    echo -e "${L_PURPLE}================================================${NC}"
    echo -e "${L_CYAN}         一键参数检测${NC}"
    echo -e "${L_PURPLE}================================================${NC}"

    local _ok=0 _warn=0 _fail=0

    _ck_pass() { echo -e "   ${GREEN}✓${NC}  $1"; _ok=$((_ok + 1)); }
    _ck_warn() { echo -e "   ${YELLOW}!${NC}  $1"; _warn=$((_warn + 1)); }
    _ck_fail() { echo -e "   ${RED}✗${NC}  $1"; _fail=$((_fail + 1)); }

    _ck_sysctl() {
        local key=$1 expect=$2 op=${3:-eq} label=${4:-$1}
        local val
        val=$(sysctl -n "$key" 2>/dev/null)
        if [ -z "$val" ]; then
            _ck_warn "${label}  →  无法读取（模块未加载?）"
            return
        fi
        local hit=0
        case $op in
            eq) [ "$val"  =  "$expect" ] && hit=1 ;;
            ge) [ "$val" -ge "$expect" ] && hit=1 ;;
            le) [ "$val" -le "$expect" ] && hit=1 ;;
        esac
        if [ $hit -eq 1 ]; then
            _ck_pass "${label}  =  ${val}"
        else
            _ck_fail "${label}  =  ${val}  （期望 ${op} ${expect}）"
        fi
    }

    # ── 1-5. sysctl 参数（依赖配置文件）────────────────────
    local _sysctl_conf="/etc/sysctl.d/99-custom-tuning.conf"
    if [ ! -f "$_sysctl_conf" ]; then
        echo -e "\n${L_BLUE}[ sysctl 配置 ]${NC}"
        _ck_fail "99-custom-tuning.conf 不存在，TCP/缓冲区/Conntrack 参数均未配置（请运行选项 1）"
    else
        _ck_pass_file() {
            # 同时验证配置文件内容 + 内核实际值，两者都对才算通过
            local key=$1 expect=$2 op=${3:-eq} label=${4:-$1}
            local live file_val hit_live=0 hit_file=0
            live=$(sysctl -n "$key" 2>/dev/null)
            file_val=$(awk -F'=' "/^[[:space:]]*${key//./\\.}[[:space:]]*=/{gsub(/ /,\"\",\$2); print \$2; exit}" "$_sysctl_conf" 2>/dev/null)

            # 检查配置文件中是否有此项
            if [ -z "$file_val" ]; then
                _ck_warn "${label}  →  配置文件中无此项（使用内核默认值 ${live:-?}）"
                return
            fi
            # 检查实际生效值
            if [ -z "$live" ]; then
                _ck_warn "${label}  →  无法读取内核值（模块未加载?）"
                return
            fi
            case $op in
                eq) [ "$live" = "$expect"  ] && hit_live=1; [ "$file_val" = "$expect"  ] && hit_file=1 ;;
                ge) [ "$live" -ge "$expect" ] && hit_live=1; [ "$file_val" -ge "$expect" ] && hit_file=1 ;;
                le) [ "$live" -le "$expect" ] && hit_live=1; [ "$file_val" -le "$expect" ] && hit_file=1 ;;
            esac
            if [ $hit_live -eq 1 ] && [ $hit_file -eq 1 ]; then
                _ck_pass "${label}  =  ${live}"
            elif [ $hit_file -eq 1 ] && [ $hit_live -eq 0 ]; then
                _ck_warn "${label}  →  配置文件正确(${file_val})，但内核实际值 ${live} 不符（需重载 sysctl）"
            else
                _ck_fail "${label}  =  ${live}  （配置值 ${file_val}，期望 ${op} ${expect}）"
            fi
        }

        echo -e "\n${L_BLUE}[ TCP 内核调优 ]${NC}"
        _ck_pass_file net.ipv4.tcp_congestion_control     bbr      eq  "拥塞控制"
        _ck_pass_file net.core.default_qdisc              fq       eq  "队列调度"
        _ck_pass_file net.ipv4.tcp_timestamps             1        eq  "tcp_timestamps"
        _ck_pass_file net.ipv4.tcp_tw_reuse               1        eq  "TIME_WAIT 复用"
        _ck_pass_file net.ipv4.tcp_syncookies             1        eq  "SYN Cookies"
        _ck_pass_file net.ipv4.ip_forward                 1        eq  "IP 转发"
        _ck_pass_file net.ipv4.tcp_slow_start_after_idle  0        eq  "慢启动(空闲后)"
        _ck_pass_file net.ipv4.tcp_ecn                    2        eq  "ECN (仅对端支持时启用)"
        _ck_pass_file net.ipv4.tcp_no_metrics_save        1        eq  "路由指标缓存"
        _ck_pass_file fs.file-max                         1000000  ge  "文件句柄上限"

        echo -e "\n${L_BLUE}[ Keepalive ]${NC}"
        _ck_pass_file net.ipv4.tcp_keepalive_time    600   le  "Keepalive 启动(s)"
        _ck_pass_file net.ipv4.tcp_keepalive_intvl   30    le  "Keepalive 间隔(s)"
        _ck_pass_file net.ipv4.tcp_keepalive_probes  5     le  "Keepalive 探测次数"

        echo -e "\n${L_BLUE}[ 故障检测 ]${NC}"
        _ck_pass_file net.ipv4.tcp_syn_retries     3   le  "SYN 重试次数"
        _ck_pass_file net.ipv4.tcp_retries2        6   le  "数据重传上限"
        _ck_pass_file net.ipv4.tcp_orphan_retries  1   eq  "孤儿连接重试"
        _ck_pass_file net.ipv4.tcp_fin_timeout     20  le  "FIN 超时(s)"

        echo -e "\n${L_BLUE}[ 缓冲区 ]${NC}"
        _ck_pass_file net.core.rmem_max  8388608  ge  "最大读缓冲"
        _ck_pass_file net.core.wmem_max  8388608  ge  "最大写缓冲"

        echo -e "\n${L_BLUE}[ Conntrack ]${NC}"
        local _expected_ct
        _expected_ct=$(awk -F'=' '/nf_conntrack_max/{gsub(/ /,"",$2); print $2}' "$_sysctl_conf" 2>/dev/null)
        _expected_ct=${_expected_ct:-131072}
        _ck_pass_file net.netfilter.nf_conntrack_max                     "$_expected_ct"  ge  "Conntrack 上限"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_established  3600  le  "ESTABLISHED 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_time_wait    30    le  "TIME_WAIT 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_fin_wait     30    le  "FIN_WAIT 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_close_wait   15    le  "CLOSE_WAIT 超时"
    fi

    # ── 6. BBR 模块 & XanMod 内核 ───────────────────────
    echo -e "\n${L_BLUE}[ BBR 模块 & 内核 ]${NC}"
    local _avail_cc _active_cc
    _avail_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    _active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    # XanMod 内核检测
    if uname -r | grep -qi "xanmod"; then
        _ck_pass "XanMod 内核已运行 ($(uname -r | sed 's/-x64v.*//'))"
    else
        _ck_warn "未运行 XanMod 内核，x86_64 建议安装 XanMod 6.13+ 以获取 BBR v3（当前: $(uname -r)）"
    fi
    if echo "$_avail_cc" | grep -q "bbr"; then
        _ck_pass "BBR 在内核可用列表"
    else
        _ck_fail "BBR 不在内核可用列表（内核版本过低或模块未加载）"
    fi
    if [ "$_active_cc" = "bbr" ]; then
        local _bbr_ver_label=""
        [[ "$(_get_bbr_version)" == "v3" ]] && _bbr_ver_label=" (v3)" || _bbr_ver_label=" (v1)"
        _ck_pass "BBR${_bbr_ver_label} 当前激活"
    else
        _ck_fail "BBR 未激活（当前使用 ${_active_cc:-?}）"
    fi

    # ── 6.5. tc qdisc ─────────────────────────────────────
    echo -e "\n${L_BLUE}[ tc qdisc ]${NC}"
    local _def_if_ck _qdisc_info
    _def_if_ck=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$_def_if_ck" ] && command -v tc >/dev/null 2>&1; then
        _qdisc_info=$(tc qdisc show dev "$_def_if_ck" 2>/dev/null | head -1 || true)
        if echo "$_qdisc_info" | grep -q "fq "; then
            local _mr
            _mr=$(echo "$_qdisc_info" | grep -oP 'maxrate \K[^ ]+' || echo "?")
            _ck_pass "qdisc fq 已生效 → ${_def_if_ck}  maxrate=${_mr}"
        else
            _ck_warn "qdisc 未使用 fq（当前: ${_qdisc_info:-未知}），BBR 重传优化可能未生效"
        fi
    else
        _ck_warn "无法检测 tc qdisc（tc 未安装或无默认路由）"
    fi

    # ── 7. IPv6 ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ IPv6 ]${NC}"
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        _ck_sysctl net.ipv6.conf.all.disable_ipv6 1 eq "IPv6 已禁用"
    else
        _ck_warn "IPv6 未禁用（若需禁用请在菜单 [12] 切换）"
    fi

    # ── 8. Swap ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ Swap ]${NC}"
    local _swap_kb
    _swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "${_swap_kb:-0}" -gt 0 ]; then
        _ck_pass "Swap 已启用 $((_swap_kb / 1024)) MB"
    else
        _ck_warn "未启用 Swap（物理内存充足时可忽略）"
    fi

    # ── 9. 文件描述符 ────────────────────────────────────
    echo -e "\n${L_BLUE}[ 文件描述符 ]${NC}"
    # '*' 在 limits.conf 中不匹配 root，需同时检测 root 专属条目
    local _fd_val=""
    _fd_val=$(grep -rE '^(root|\*)\s+soft\s+nofile' \
        /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null \
        | awk '{print $NF}' | sort -n | tail -1 || true)
    if [ -n "$_fd_val" ]; then
        if [ "${_fd_val:-0}" -ge 512000 ]; then
            _ck_pass "limits.conf soft nofile = ${_fd_val}"
        else
            _ck_fail "limits.conf soft nofile = ${_fd_val}（期望 >= 512000，请重新运行选项 1 一键初始化）"
        fi
    else
        _ck_fail "limits.conf 未配置 nofile（请重新运行选项 1 一键初始化）"
    fi
    # 检查当前会话实际生效值
    local _ulimit_cur
    _ulimit_cur=$(ulimit -Sn 2>/dev/null || echo "unknown")
    if [[ "$_ulimit_cur" == "unlimited" ]] || { [[ "$_ulimit_cur" =~ ^[0-9]+$ ]] && [ "$_ulimit_cur" -ge 512000 ]; }; then
        _ck_pass "当前会话 ulimit -n = ${_ulimit_cur}"
    else
        _ck_warn "当前会话 ulimit -n = ${_ulimit_cur}（重新登录后自动生效）"
    fi

    # ── 10. DNS ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ DNS ]${NC}"
    if grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null && \
       grep -q "1.1.1.1" /etc/resolv.conf 2>/dev/null && \
       grep -q "94.140.14.14" /etc/resolv.conf 2>/dev/null; then
        _ck_pass "DNS 已配置（8.8.8.8 / 1.1.1.1 / 94.140.14.14）"
    else
        _ck_fail "DNS 配置异常，resolv.conf 未包含全部目标 DNS（请运行选项 1 重新初始化）"
    fi
    if [ -L /etc/resolv.conf ]; then
        _ck_warn "resolv.conf 是符号链接，chattr +i 无效（请运行选项 1 重新初始化）"
    else
        local _res_attrs
        _res_attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        if echo "$_res_attrs" | grep -q "i"; then
            _ck_pass "resolv.conf 已锁定（chattr +i）"
        else
            _ck_warn "resolv.conf 未锁定，可能被 DHCP/cloud-init 覆盖"
        fi
    fi

    # ── 11. 防火墙 ───────────────────────────────────────
    echo -e "\n${L_BLUE}[ 防火墙 ]${NC}"
    if ! command -v iptables >/dev/null 2>&1; then
        _ck_fail "iptables 未安装（请运行选项 1）"
    else
        local _fw_policy
        _fw_policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        case "$_fw_policy" in
            DROP)   _ck_pass "INPUT 策略 = DROP（安全模式）" ;;
            ACCEPT) _ck_warn "INPUT 策略 = ACCEPT（开放模式，无过滤防护）" ;;
            *)      _ck_fail "INPUT 策略 = ${_fw_policy:-未知}" ;;
        esac

        local _fw_rules
        _fw_rules=$(iptables -S INPUT 2>/dev/null | grep -c '^-A' 2>/dev/null) || _fw_rules=0
        if [ "${_fw_rules:-0}" -gt 0 ]; then
            _ck_pass "INPUT 规则 ${_fw_rules} 条"
        else
            _ck_warn "无 INPUT ACCEPT 规则（所有入站均被拒绝，含 SSH）"
        fi

        local _ssh_port
        _ssh_port=$(get_current_ssh_port 2>/dev/null || echo "22")
        if [ "$_fw_policy" = "ACCEPT" ] || iptables -C INPUT -p tcp --dport "$_ssh_port" -j ACCEPT 2>/dev/null; then
            _ck_pass "SSH 端口 ${_ssh_port} 已放行"
        else
            _ck_fail "SSH 端口 ${_ssh_port} 未放行！（有断联风险）"
        fi

        if systemctl is-enabled --quiet netfilter-persistent 2>/dev/null; then
            _ck_pass "netfilter-persistent 已启用（规则重启持久）"
        elif [ -f "/etc/iptables/rules.v4" ]; then
            _ck_warn "/etc/iptables/rules.v4 存在但 netfilter-persistent 未启用"
        else
            _ck_fail "防火墙规则未持久化（重启后将丢失，请运行选项 1）"
        fi
    fi

    # ── 12. 代理服务 ─────────────────────────────────────
    echo -e "\n${L_BLUE}[ 代理服务 ]${NC}"
    local _proxy_found=0
    if [ -f "/usr/local/bin/snell-server" ]; then
        _proxy_found=1
        if systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -q 'snell@'; then
            _ck_pass "Snell 运行中"
        else
            _ck_warn "Snell 已安装但未运行"
        fi
    fi
    if [ -x "/usr/local/bin/sing-box" ]; then
        _proxy_found=1
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            _ck_pass "sing-box 运行中"
        else
            _ck_warn "sing-box 已安装但未运行"
        fi
    fi
    if [ -f "/usr/local/bin/realm" ]; then
        _proxy_found=1
        if systemctl is-active --quiet realm 2>/dev/null; then
            _ck_pass "Realm 运行中"
        else
            _ck_warn "Realm 已安装但未运行"
        fi
    fi
    [ $_proxy_found -eq 0 ] && _ck_warn "未检测到代理服务（Snell/SS/Realm）"

    # ── 汇总 ─────────────────────────────────────────────
    local _total
    _total=$((_ok + _warn + _fail))
    echo -e "\n${L_PURPLE}================================================${NC}"
    printf "  检测项目: ${WHITE}%-4s${NC}  ${GREEN}通过: %-4s${NC}  ${YELLOW}警告: %-4s${NC}  ${RED}失败: %-4s${NC}\n" \
        "$_total" "$_ok" "$_warn" "$_fail"
    if [ $_fail -eq 0 ] && [ $_warn -eq 0 ]; then
        echo -e "  ${GREEN}所有参数均已正确配置！${NC}"
    elif [ $_fail -eq 0 ]; then
        echo -e "  ${YELLOW}存在 ${_warn} 个警告项，核心配置正常。${NC}"
    else
        echo -e "  ${RED}存在 ${_fail} 个失败项，请按提示重新运行对应选项修复。${NC}"
    fi
    echo -e "${L_PURPLE}================================================${NC}"
    # N-02: 清理内嵌函数，避免其串漏到全局命名空间后引用已销毁的局部计数器
    unset -f _ck_pass _ck_warn _ck_fail _ck_sysctl _ck_pass_file
}


# 开放单个协议端口（幂等：已存在则不重复添加）
_firewall_open_port() {
    local proto="$1" port="$2"
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
}


# ==============================================================================
# 一键初始化 & 系统更新
# ==============================================================================

do_retune_bandwidth() {
    clear
    echo -e "${L_BLUE}=== 带宽重调 (sysctl + tc) ===${NC}"
    echo
    local _def_if
    _def_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    local _cur_rmem; _cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    local _cur_maxrate="?"
    [ -n "$_def_if" ] && _cur_maxrate=$(tc qdisc show dev "$_def_if" 2>/dev/null | grep -oP 'maxrate \K[^ ]+' || echo "?")
    local _cur_bw_est="?"
    if [[ "$_cur_maxrate" =~ ^([0-9]+)Mbit$ ]]; then
        _cur_bw_est=$(( ${BASH_REMATCH[1]} * 100 / 98 ))
    fi
    local _bw_default="1000"
    [[ "$_cur_bw_est" =~ ^[0-9]+$ ]] && _bw_default="$_cur_bw_est"
    echo -e "  当前 rmem_max  : ${CYAN}$(( _cur_rmem / 1048576 )) MB${NC}"
    echo -e "  当前 tc maxrate: ${CYAN}${_cur_maxrate}${NC}  (对应带宽约 ${CYAN}${_cur_bw_est} Mbps${NC})"
    echo
    echo -e "  填入实际物理端口带宽，脚本自动重算 sysctl 缓冲区并更新 tc 限速"
    echo -ne "${L_PURPLE}输入新带宽 Mbps [${_bw_default}]: ${NC}"
    local bw_mbps; read -r bw_mbps
    bw_mbps="${bw_mbps:-${_bw_default}}"
    if ! [[ "$bw_mbps" =~ ^[0-9]+$ ]] || [ "$bw_mbps" -lt 10 ]; then
        echo -e "${RED}✗ 无效输入（需为正整数 Mbps）${NC}"; return 1
    fi
    local _pmem_kb; _pmem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local _pmem_mb=$(( _pmem_kb / 1024 ))
    local _cc; _cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo bbr)
    echo -e "${L_PURPLE}请选择机器角色:${NC}"
    echo -e "  ${L_PURPLE}[1]${NC} 优化线路 (中转/高并发, 池均分防单连接吃爆)"
    echo -e "  ${L_PURPLE}[2]${NC} 落地     (低并发/单连接给满 BDP)  ${GREEN}[默认]${NC}"
    echo -ne "${L_PURPLE}请选择 [2]: ${NC}"
    local _role_in; read -r _role_in
    local _role="edge"; [ "$(echo "$_role_in" | tr -d '[:space:]')" = "1" ] && _role="transit"

    echo -e "\n${L_BLUE}[ 1/3 ] 重新计算 sysctl 参数 (角色: ${_role})${NC}"
    _calc_sysctl_params "$_pmem_mb" "$bw_mbps" "$_role"
    _write_sysctl_conf "$bw_mbps" "$_pmem_mb" "$_cc"
    sysctl --system >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ sysctl 已更新${NC}"
    echo -e "    rmem_max     = ${CYAN}$(( _P_RMEM_MAX / 1048576 )) MB${NC}"
    echo -e "    tcp_rmem mid = ${CYAN}$(( _P_TCP_RMEM_MID / 1048576 )) MB${NC}"

    echo -e "\n${L_BLUE}[ 2/3 ] 更新 tc qdisc${NC}"
    # 小口子(≤1200M)口速≈单流瓶颈，用 100% 卡在拐点拿满吞吐；大口子单流非约束，留 2% 余量防聚合 bufferbloat
    local _fq_pct=100; [ "$bw_mbps" -gt 1200 ] && _fq_pct=98
    local _fq_maxrate=$(( bw_mbps * _fq_pct / 100 ))
    [ "$_fq_maxrate" -lt 100 ] && _fq_maxrate=100
    if [ -n "$_def_if" ]; then
        if tc qdisc replace dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null; then
            echo -e "  ${GREEN}✓ fq maxrate=${_fq_maxrate}mbit → ${_def_if}${NC}"
        else
            tc qdisc add dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null || true
            echo -e "  ${YELLOW}⚠ replace 失败，已尝试 add${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ 无默认路由，跳过 tc${NC}"
    fi

    echo -e "\n${L_BLUE}[ 3/3 ] 持久化${NC}"
    local _rc_local="/etc/rc.local" _rc_tmp
    _rc_tmp=$(mktemp)
    [ -f "$_rc_local" ] && cp "$_rc_local" "${_rc_local}.bak.$(TZ="$TZ_DEFAULT" date +%Y%m%d%H%M%S)" 2>/dev/null || true
    {
        if [ -f "$_rc_local" ]; then
            head -n 1 "$_rc_local" | grep -qE '^#!' && head -n 1 "$_rc_local" || echo '#!/bin/bash'
            grep -v "^#!" "$_rc_local" \
                | grep -v "tc qdisc replace.*root fq" \
                | grep -v 'IFACE=.*ip route show default' \
                | grep -v "^exit 0" || true
        else
            echo '#!/bin/bash'
        fi
        printf 'IFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' "$_fq_maxrate"
        echo 'exit 0'
    } > "$_rc_tmp" && mv "$_rc_tmp" "$_rc_local" || rm -f "$_rc_tmp"
    chmod +x "$_rc_local"
    if [ -d /etc/networkd-dispatcher/routable.d ]; then
        printf '#!/bin/bash\nIFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
            "$_fq_maxrate" > /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
        chmod +x /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
    fi
    echo -e "  ${GREEN}✓ rc.local + networkd-dispatcher 已更新${NC}"
    echo
    echo -e "${GREEN}✓ 带宽重调完成${NC}  新带宽: ${CYAN}${bw_mbps} Mbps${NC}  tc maxrate: ${CYAN}${_fq_maxrate}Mbit${NC}  rmem_max: ${CYAN}$(( _P_RMEM_MAX / 1048576 ))MB${NC}"
}

do_system_update() {
    clear
    echo -e "${L_BLUE}=== 系统更新 ===${NC}"
    echo

    local _kernel_before
    _kernel_before=$(uname -r)
    rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

    echo -e "${L_BLUE}[ 1/2 ] apt update${NC}"
    apt-get update || { echo -e "${RED}✗ apt update 失败${NC}"; return 1; }

    echo -e "\n${L_BLUE}[ 2/2 ] apt upgrade${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || { echo -e "${RED}✗ apt upgrade 失败${NC}"; return 1; }
    echo -e "\n${GREEN}✓ 系统更新完成${NC}"

    # 检测是否有新内核
    local _need_reboot=0 _new_kernel=""
    [ -f /var/run/reboot-required ] && _need_reboot=1
    _new_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null \
        | awk '/^ii/{print $2}' | sed 's/linux-image-//' \
        | grep -v 'dbg\|devel' | grep -E '^[0-9]' | sort -V | tail -1 || true)
    [ -n "$_new_kernel" ] && [ "$_new_kernel" != "$_kernel_before" ] && _need_reboot=1

    if [ $_need_reboot -eq 1 ]; then
        echo
        echo -e "${YELLOW}━━ 检测到新内核，需要重启 ━━${NC}"
        echo -e "  当前运行: ${CYAN}${_kernel_before}${NC}"
        [ -n "$_new_kernel" ] && [ "$_new_kernel" != "$_kernel_before" ] && \
            echo -e "  已安装:   ${GREEN}${_new_kernel}${NC}"
        [ -f /var/run/reboot-required.pkgs ] && \
            echo -e "  相关包:   ${WHITE}$(tr '\n' ' ' < /var/run/reboot-required.pkgs)${NC}"
        echo -ne "${L_PURPLE}立即重启？[Y/n]: ${NC}"
        read -r _r
        [[ ! "${_r:-Y}" =~ ^[Nn]$ ]] && { for _i in 3 2 1; do printf "\r${GREEN}%d 秒后重启...${NC}" $_i; sleep 1; done; echo; reboot; }
    else
        echo -e "  ${GREEN}内核无更新，无需重启${NC}"
    fi
}

do_quick_init() {
    clear
    echo -e "${L_PURPLE}══════════════════════ 一键初始化 ══════════════════════${NC}"
    echo -e "  ${CYAN}IPv6${NC} → ${CYAN}系统更新${NC} → ${CYAN}XanMod内核${NC} → ${CYAN}网络优化${NC} → ${CYAN}防火墙${NC} → ${CYAN}TG/Fail2Ban${NC} → ${CYAN}TCPing${NC}"
    echo -e "  带宽须人工确认，安装内核后需重启以启用 BBR v3"
    echo

    local _ok_sys=0 _ok_net=0 _ok_fw=0 _ok_f2b=0 _ok_tg=0
    local _net_bw=0 _rmem_mb=0 _cc="cubic"
    local _xanmod_done=0 _xanmod_pkg="" _xanmod_avx=""
    local _init_srv_name=""

    # ── [1/5] IPv6 ───────────────────────────────────────────
    local _cur_ipv6=""
    echo -e "\n${L_BLUE}── [1/5] IPv6 配置 ──────────────────────────────────────${NC}"
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        echo -e "  ${GREEN}✓${NC} IPv6: ${RED}已禁用（跳过）${NC}"
        # 早已禁用 IPv6 的机器不会走 _write_disable_ipv6_conf，此处补做 interfaces 校正
        # （本次修复之前禁用的机器都缺这一步，其 networking.service 每次开机都失败）
        if _ipv6_ifaces_off; then
            echo -e "  ${GREEN}✓${NC} 已注释 /etc/network/interfaces 的 IPv6 配置（否则 ifup 失败）"
        fi
    else
        _write_disable_ipv6_conf    # 内部已含 _ipv6_ifaces_off
        echo -e "  ${GREEN}✓${NC} IPv6: ${RED}已禁用${NC}（含 interfaces IPv6 配置）"
    fi

    # ── [2/5] 系统更新 & 依赖安装 ───────────────────────────
    echo -e "\n${L_BLUE}── [2/5] 系统更新 & 依赖安装 ──────────────────────────${NC}"

    if ! check_package_manager_lock; then return; fi

    local _dns_pkg="dnsutils"
    apt-cache show bind9-dnsutils >/dev/null 2>&1 && _dns_pkg="bind9-dnsutils"
    local _qi_deps=(
        curl wget ca-certificates apt-transport-https openssl
        unzip zip tar gzip xz-utils jq gnupg gnupg2 lsb-release
        bc net-tools iproute2 iputils-ping "$_dns_pkg" vim nano htop tree lsof
        screen psmisc bsdmainutils iptables iptables-persistent netfilter-persistent
        at mtr iperf3 ipset isc-dhcp-client conntrack procps systemd-timesyncd
        socat netcat-openbsd fail2ban python3-systemd
    )

    if ! dpkg-query -W -f='${Status}' "iptables-persistent" 2>/dev/null | grep -q "ok installed"; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
    fi

    (apt-get update -qq < /dev/null >/dev/null 2>&1) &
    local _upd_pid=$!
    show_spinner $_upd_pid "  更新软件源"
    wait $_upd_pid && echo -e "  ${GREEN}✓ 更新软件源${NC}" || echo -e "  ${YELLOW}⚠ 更新软件源失败（继续）${NC}"

    (DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq < /dev/null >/dev/null 2>&1) &
    local _upg_pid=$!
    show_spinner $_upg_pid "  升级系统组件"
    wait $_upg_pid && echo -e "  ${GREEN}✓ 升级系统组件${NC}" || echo -e "  ${YELLOW}⚠ 升级系统组件部分失败（继续）${NC}"

    local _to_install=() _pkg _qi_installed=0 _qi_notfound=0
    if apt-cache show software-properties-common >/dev/null 2>&1; then
        if ! dpkg-query -W -f='${Status}' "software-properties-common" 2>/dev/null | grep -q "ok installed"; then
            _to_install+=("software-properties-common")
        fi
    fi
    for _pkg in "${_qi_deps[@]}"; do
        if dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | grep -q "ok installed"; then
            (( _qi_installed++ )) || true
        elif apt-cache show "$_pkg" >/dev/null 2>&1; then
            _to_install+=("$_pkg")
        else
            (( _qi_notfound++ )) || true
        fi
    done
    local _qi_total=$(( _qi_installed + ${#_to_install[@]} + _qi_notfound ))

    local _step_ok=1
    if [ ${#_to_install[@]} -eq 0 ]; then
        echo -e "  ${GREEN}✓ 依赖: 共 ${_qi_total} 个，已全部安装${NC}"
    else
        echo -e "  ${CYAN}⟳ 依赖: ${_qi_installed} 已安装，${#_to_install[@]} 待安装: ${_to_install[*]}${NC}"
        (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${_to_install[@]}" < /dev/null >/dev/null 2>&1) &
        local _inst_pid=$!
        show_spinner $_inst_pid "  安装中"
        wait $_inst_pid || _step_ok=0

        local _install_fail=0  # H-02: 改名以区分 do_check_all 中的 _fail
        for _pkg in "${_to_install[@]}"; do
            dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | grep -q "ok installed" || \
                _install_fail=$(( _install_fail + 1 ))
        done
        local _install_ok=$(( ${#_to_install[@]} - _install_fail ))
        if [ $_install_fail -eq 0 ]; then
            echo -e "  ${GREEN}✓ 安装完成 (${_install_ok}/${#_to_install[@]})${NC}"
        else
            _step_ok=0
            echo -e "  ${RED}✗ 安装完成 ${_install_ok}/${#_to_install[@]}，${_install_fail} 个失败${NC}"
            echo -e "  ${YELLOW}  建议手动: apt-get install -y ${_to_install[*]}${NC}"
        fi
    fi

    # 必须放在依赖安装之后：上面装的 at 带 "Recommends: default-mta"，apt 默认装
    # Recommends，于是 exim4-daemon-light 会被一并拉回来 —— 早于此处卸载等于白卸。
    # 卸掉不影响 at：Recommends 是软依赖，atd 与防火墙安全网的定时回滚都不需要邮件。
    _purge_exim4

    # 依赖装完后获取服务器 IP 和地理信息并写缓存，后续启动直接读缓存无需 curl
    if command -v curl &>/dev/null; then
        local _ip
        _ip=$(get_public_ip 2>/dev/null || true)
        if [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            get_geo_info "$_ip" || true
            local _flag; _flag=$(get_flag_emoji "$SERVER_COUNTRY_CODE")
            echo -e "  ${GREEN}✓ 公网IP: ${CYAN}${SERVER_IP}${NC}  ${_flag} ${SERVER_COUNTRY_NAME}${SERVER_CITY:+ · ${SERVER_CITY}}"
            mkdir -p "$WORK_DIR"
            {
                printf 'SERVER_IP=%s\n'           "$SERVER_IP"
                printf 'SERVER_COUNTRY_CODE=%s\n' "$SERVER_COUNTRY_CODE"
                printf 'SERVER_COUNTRY_NAME=%s\n' "$SERVER_COUNTRY_NAME"
                printf 'SERVER_CITY=%s\n'         "$SERVER_CITY"
            } > "$CACHE_FILE"
            chmod 600 "$CACHE_FILE"
        fi
    fi

    systemctl enable --now atd >/dev/null 2>&1 || true
    systemctl enable --now iptables >/dev/null 2>&1 || true
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
    # iperf3 服务设为手动模式（避免随机自启监听 5201，需要时手动 iperf3 -s）
    if systemctl list-unit-files iperf3.service &>/dev/null; then
        systemctl stop iperf3 >/dev/null 2>&1 || true
        systemctl disable iperf3 >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ iperf3 服务已禁用 (手动运行模式)${NC}"
    fi

    # 自动时区设置（根据 IP 地理位置）
    local _tz=""
    for _tz_url in "https://ipinfo.io/timezone" "https://ipapi.co/timezone"; do
        _tz=$(curl -s --max-time 5 "$_tz_url" 2>/dev/null | tr -d '[:space:]')
        [[ "$_tz" =~ ^[A-Za-z]+/[A-Za-z_]+ ]] && break
        _tz=""
    done
    if [[ -n "$_tz" ]]; then
        timedatectl set-timezone "$_tz" >/dev/null 2>&1 && \
            echo -e "  ${GREEN}✓ 时区: ${_tz}${NC}" || \
            echo -e "  ${YELLOW}⚠ 时区设置失败: ${_tz}${NC}"
    else
        echo -e "  ${YELLOW}⚠ 时区自动检测失败，当前保持: $(timedatectl show -p Timezone --value 2>/dev/null)${NC}"
    fi

    # 写入时区自动同步脚本，每 24 小时检测一次（应对 IP 位置库延迟更新）
    cat > /usr/local/bin/sync-timezone.sh << 'EOF'
#!/usr/bin/env bash
_tz=""
for _url in "https://ipinfo.io/timezone" "https://ipapi.co/timezone"; do
    _tz=$(curl -s --max-time 5 "$_url" 2>/dev/null | tr -d '[:space:]')
    [[ "$_tz" =~ ^[A-Za-z]+/[A-Za-z_]+ ]] && break
    _tz=""
done
[ -z "$_tz" ] && exit 0
_cur=$(timedatectl show -p Timezone --value 2>/dev/null)
[ "$_tz" = "$_cur" ] && exit 0
timedatectl set-timezone "$_tz" && logger "sync-timezone: updated $_cur -> $_tz"
EOF
    chmod +x /usr/local/bin/sync-timezone.sh
    # 旧版用 cron，改用 systemd 定时器（精准可控、日志走 journal、无 MTA 邮件噪音）。
    # 先清掉旧 cron 条目，避免和定时器重复执行。
    if crontab -l 2>/dev/null | grep -q "sync-timezone"; then
        crontab -l 2>/dev/null | grep -v "sync-timezone" | crontab - 2>/dev/null || true
    fi
    cat > /etc/systemd/system/sync-timezone.service <<'EOF'
[Unit]
Description=Sync system timezone from geo-IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-timezone.sh
EOF
    cat > /etc/systemd/system/sync-timezone.timer <<'EOF'
[Unit]
Description=Daily timezone sync (Shanghai 03:00)

[Timer]
OnCalendar=*-*-* 03:00:00 Asia/Shanghai
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now sync-timezone.timer >/dev/null 2>&1
    echo -e "  ${GREEN}✓ 时区自动同步: systemd 每天 03:00（上海时区）${NC}"

    # NTP 时间同步
    if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
        echo -e "  ${GREEN}✓ NTP 时间同步: 已同步${NC}"
    else
        if systemctl enable --now systemd-timesyncd >/dev/null 2>&1 && \
           timedatectl set-ntp true >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ NTP 时间同步: 已启用${NC}"
        else
            echo -e "  ${YELLOW}⚠ NTP 时间同步启用失败，请手动检查 systemd-timesyncd${NC}"
        fi
    fi

    _ok_sys=$_step_ok

    # ── 服务器名称 ────────────────────────────────────────────
    echo -e "\n${L_BLUE}── 服务器名称 ───────────────────────────────────────────${NC}"
    echo -ne "  名称 (如 🇯🇵SR_JP_Std，回车自动填): "
    read -r _init_srv_name < /dev/tty || true

    # ── [3/5] XanMod 内核安装 (BBR v3) ──────────────────────
    echo -e "\n${L_BLUE}── [3/5] XanMod 内核 (BBR v3) ─────────────────────────${NC}"
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "  ${YELLOW}⚠ 跳过（XanMod 仅支持 x86_64，当前架构: $(uname -m)）${NC}"
        local _arm_bv; _arm_bv=$(_get_bbr_version)
        if [ "$_arm_bv" = "v3" ]; then
            echo -e "  ${GREEN}✓ 当前内核 $(uname -r) 已支持 BBR v3，无需 XanMod${NC}"
        else
            echo -e "  ${YELLOW}⚠ 当前内核 $(uname -r) 支持 BBR ${_arm_bv}，BBR v3 需主线内核 ≥ 6.9${NC}"
        fi
        _xanmod_done=2
    elif uname -r | grep -qi "xanmod"; then
        echo -e "  ${GREEN}✓ 已运行 XanMod ($(uname -r))，无需重新安装${NC}"
        _xanmod_done=2
    else
        if grep -q "avx2" /proc/cpuinfo; then
            _xanmod_pkg="linux-xanmod-x64v3"; _xanmod_avx="x64v3 (AVX2)"
        else
            _xanmod_pkg="linux-xanmod-x64v2"; _xanmod_avx="x64v2 (无AVX2)"
        fi
        echo -e "  CPU: ${CYAN}${_xanmod_avx}${NC} → 将安装 ${CYAN}${_xanmod_pkg}${NC}"
        local _pre_mem_mb _pre_swap_mb
        _pre_mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
        _pre_swap_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
        if [ "$_pre_mem_mb" -lt 400 ]; then
            echo -e "  ${RED}✗ 跳过（物理内存 ${_pre_mem_mb}MB < 400MB，XanMod 启动时会 OOM Panic）${NC}"
            echo -e "  ${CYAN}提示: 升级内存至 512MB+ 后可手动安装${NC}"
        else
            # RAM < 512MB 且无 Swap 时，临时建 512MB Swap 防止安装 OOM
            # 标志文件让 [4/5] _ensure_swap 在 XanMod 装完后按实际磁盘重建正式 Swap
            if [ "$_pre_mem_mb" -lt 512 ] && [ "$_pre_swap_mb" -eq 0 ]; then
                echo -e "  ${YELLOW}⚠ 内存 ${_pre_mem_mb}MB，临时创建 512MB Swap 供安装使用...${NC}"
                fallocate -l 512M /swapfile 2>/dev/null || \
                    dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1 || true
                touch /tmp/.swap_is_temp
            fi
            local _xm_ok=1
            # Debian 13 默认无 gpg 命令，须先装 gnupg2
            if ! command -v gpg >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg2 < /dev/null >/dev/null 2>&1 || true
            fi
            # 导入 GPG Key
            if [ ! -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then
                (curl -fsSL https://dl.xanmod.org/archive.key | \
                    gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null) &
                local _gpg_pid=$!
                show_spinner $_gpg_pid "  导入 XanMod GPG key"
                wait $_gpg_pid || { echo -e "  ${RED}✗ GPG key 导入失败${NC}"; _xm_ok=0; }
            fi
            if [ "$_xm_ok" -eq 1 ]; then
                # 写入仓库源
                local _xm_codename; _xm_codename=$(lsb_release -sc 2>/dev/null || grep -oP 'VERSION_CODENAME=\K\S+' /etc/os-release)
                echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${_xm_codename} main" \
                    > /etc/apt/sources.list.d/xanmod-release.list
                (apt-get update -qq < /dev/null >/dev/null 2>&1) &
                local _xm_pid=$!
                show_spinner $_xm_pid "  更新软件源 (含 XanMod)"
                wait $_xm_pid || true
                # 安装内核
                local _xm_img _xm_hdr
                _xm_img=$(apt-cache show "${_xanmod_pkg}" 2>/dev/null \
                    | grep -m1 "^Depends:" | grep -oP 'linux-image-\S+' | head -1) || true
                _xm_hdr="${_xm_img/image/headers}"
                if [ -z "$_xm_img" ]; then
                    echo -e "  ${RED}✗ 无法获取内核包名，请手动: apt-get install -y ${_xanmod_pkg}${NC}"
                else
                    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$_xm_img" "$_xm_hdr" < /dev/null >/dev/null 2>&1) &
                    _xm_pid=$!
                    show_spinner $_xm_pid "  安装 ${_xm_img}"
                    if wait $_xm_pid; then
                        sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
                        update-grub >/dev/null 2>&1 || true
                        echo -e "  ${GREEN}✓ 安装完成，GRUB 已更新，重启后自动加载 XanMod${NC}"
                        _xanmod_done=1
                    else
                        echo -e "  ${RED}✗ 安装失败，请手动: apt-get install -y ${_xm_img} ${_xm_hdr}${NC}"
                    fi
                fi
            fi
        fi
    fi

    # ── [4/5] 网络优化 (DNS + Swap + sysctl) ────────────────
    echo -e "\n${L_BLUE}── [4/5] 网络优化 (DNS + sysctl) ──────────────────────${NC}"
    local phys_mem_mb
    phys_mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "1024")

    # DNS
    # 若 /etc/resolv.conf 是符号链接（systemd-resolved 系统），先删除再创建真实文件
    # 否则 chattr +i 对 tmpfs 目标静默失败，重启后 DNS 被 systemd-resolved 覆盖
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    if [ -f /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf <<'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 94.140.14.14
options timeout:2 attempts:2
DNSEOF
        chattr +i /etc/resolv.conf 2>/dev/null || true
        echo -e "  ${GREEN}✓ DNS: 8.8.8.8 / 1.1.1.1 / 94.140.14.14 (已锁定)${NC}"
    fi

    # Swap（幂等，已存在则跳过）
    _ensure_swap

    # 带宽测速 + 端口速度（单一确认，同时用于 sysctl buffer 和 tc maxrate）
    printf "  测速中 (curl 8线程→Cloudflare)..."
    _measure_bandwidth 1000
    local bw_mbps=$_BW_MBPS
    echo -ne "  ${BLUE}端口速度 Mbps (回车用测速值，低于实际口速可手填) [${bw_mbps}]: ${NC}"
    local _port_input; read -r _port_input < /dev/tty || true
    _port_input=$(echo "$_port_input" | tr -d '[:space:]')
    [[ "$_port_input" =~ ^[0-9]+$ ]] && [ "$_port_input" -gt 0 ] && bw_mbps=$_port_input
    echo -e "  ${GREEN}✓ 端口速度: ${bw_mbps} Mbps${NC}"
    echo -e "  ${BLUE}请选择机器角色:${NC}"
    echo -e "    ${BLUE}[1]${NC} 优化线路 (中转/高并发)"
    echo -e "    ${BLUE}[2]${NC} 落地     (低并发/单连接给满 BDP)  ${GREEN}[默认]${NC}"
    echo -ne "  ${BLUE}请选择 [2]: ${NC}"
    local _role_in; read -r _role_in < /dev/tty || true
    local _role="edge"; [ "$(echo "$_role_in" | tr -d '[:space:]')" = "1" ] && _role="transit"
    echo -e "  ${GREEN}✓ 角色: $([ "$_role" = edge ] && echo '落地(单连接给满BDP)' || echo '优化线路(防单连接吃爆池)')${NC}"

    # BBR / 拥塞控制
    if [ "$_xanmod_done" -eq 1 ]; then
        # XanMod 已安装但未重启；预写 sysctl，重启后 BBR v3 自动生效
        _cc="bbr"
        modprobe tcp_bbr 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ BBR v3 待重启后生效 (${_xanmod_pkg}，sysctl 已预写入)${NC}"
    else
        modprobe tcp_bbr 2>/dev/null || true
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            _cc="bbr"
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
            sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
            if [ "$_xanmod_done" -eq 2 ]; then
                local _bv; _bv=$(_get_bbr_version)
                echo -e "  ${GREEN}✓ BBR ${_bv} 已生效 (XanMod $(uname -r | cut -d- -f1))${NC}"
            else
                echo -e "  ${GREEN}✓ BBR 已加载 (原版内核 BBR v1)${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠ BBR 模块不可用，将使用默认拥塞控制 (${_cc})${NC}"
        fi
    fi

    # 动态参数计算 & sysctl 写入
    _calc_sysctl_params "$phys_mem_mb" "$bw_mbps" "$_role"
    _write_sysctl_conf "$bw_mbps" "$phys_mem_mb" "$_cc"
    sysctl --system >/dev/null 2>&1 || true
    sysctl -w net.ipv4.route.flush=1 >/dev/null 2>&1 || true
    _apply_conntrack_sysctl "$_P_CONNTRACK_MAX"
    _apply_nofile_limits
    _apply_journald_limits

    _ok_net=1; _net_bw=$bw_mbps; _rmem_mb=$(( _P_RMEM_MAX / 1048576 ))
    echo -e "  ${GREEN}✓ sysctl 写入完成  rmem: ${_rmem_mb}MB  CC: ${_cc}${NC}"

    # sysctl default_qdisc=fq 只对新建接口生效，已有接口须用 tc 显式切换
    local _def_if _fq_maxrate _fq_pct
    _def_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$_def_if" ] && command -v tc >/dev/null 2>&1; then
        # 小口子(≤1200M)口速≈单流瓶颈，用 100% 卡在拐点拿满吞吐；大口子单流非约束，留 2% 余量防聚合 bufferbloat
        _fq_pct=100; [ "$bw_mbps" -gt 1200 ] && _fq_pct=98
        _fq_maxrate=$(( bw_mbps * _fq_pct / 100 ))
        [ "$_fq_maxrate" -lt 100 ] && _fq_maxrate=100
        if tc qdisc replace dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null; then
            echo -e "  ${GREEN}✓ qdisc fq maxrate=${_fq_maxrate}mbit(${bw_mbps}Mbps×${_fq_pct}%) flow_limit=250 → ${_def_if}${NC}"
            local _rc_local="/etc/rc.local" _rc_tmp
            _rc_tmp=$(mktemp)
            [ -f "$_rc_local" ] && cp "$_rc_local" "${_rc_local}.bak.$(TZ="$TZ_DEFAULT" date +%Y%m%d%H%M%S)" 2>/dev/null || true
            {
                if [ -f "$_rc_local" ]; then
                    head -n 1 "$_rc_local" | grep -qE '^#!' && head -n 1 "$_rc_local" || echo '#!/bin/bash'
                    grep -v "^#!" "$_rc_local" \
                        | grep -v "tc qdisc replace.*root fq" \
                        | grep -v 'IFACE=.*ip route show default' \
                        | grep -v "^exit 0" || true
                else
                    echo '#!/bin/bash'
                fi
                printf 'IFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
                    "$_fq_maxrate"
                echo 'exit 0'
            } > "$_rc_tmp" && mv "$_rc_tmp" "$_rc_local" || rm -f "$_rc_tmp"
            chmod +x "$_rc_local"
            if [ -d /etc/networkd-dispatcher/routable.d ]; then
                printf '#!/bin/bash\nIFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
                    "$_fq_maxrate" > /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
                chmod +x /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
            fi
        else
            echo -e "  ${YELLOW}⚠ qdisc fq 切换失败（继续）${NC}"
        fi
    fi

    # ── [5/5] 防火墙初始化 ──────────────────────────────────
    echo -e "\n${L_BLUE}── [5/5] 防火墙初始化 ──────────────────────────────────${NC}"
    if command -v iptables >/dev/null 2>&1 && command -v at >/dev/null 2>&1; then
        do_init_firewall --auto
        _ok_fw=1
    else
        echo -e "  ${YELLOW}⚠ iptables/at 未就绪，跳过（请检查步骤 2 的安装结果）${NC}"
    fi

    # TG 推送配置
    echo -e "\n${L_BLUE}── [+] TG 推送 ──────────────────────────────────────────${NC}"
    if [[ -f "$TG_CONF" ]] && grep -q "^TG_BOT_TOKEN=" "$TG_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}✓ 已配置（跳过）${NC}"
        _ok_tg=1
    else
        local _tg_ans
        while :; do
            echo -ne "  是否现在配置 TG 推送？[Y/n]: "
            read -r _tg_ans < /dev/tty || true
            case "$_tg_ans" in
                ""|[Yy]) _tg_input_tokens "$_init_srv_name" && _ok_tg=1 || true; break ;;
                [Nn])    echo -e "  ${YELLOW}⚠ 跳过（可后续从选项 3 配置）${NC}"; break ;;
                *)       echo -e "  ${YELLOW}请输入 Y 或 N（回车默认 Y）${NC}" ;;
            esac
        done
    fi

    # Fail2Ban 规则配置
    echo -e "\n${L_BLUE}── [+] Fail2Ban ─────────────────────────────────────────${NC}"
    if [[ -f /etc/fail2ban/jail.d/sshd.conf ]]; then
        echo -e "  ${GREEN}✓ 已配置（跳过）${NC}"
        _ok_f2b=1
    else
        _install_fail2ban && _ok_f2b=1 || true
    fi

    # TCPing 监控（依赖 socat，防火墙就绪后才有意义）
    echo -e "\n${L_BLUE}── [+] TCPing ────────────────────────────────────────────${NC}"
    if command -v socat &>/dev/null || apt-get install -y -qq socat >/dev/null 2>&1; then
        _tcping_setup_silent
        if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
            local _tp_port; _tp_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
            echo -e "  ${GREEN}✓ TCPing 已配置 (端口 ${_tp_port})${NC}"
        else
            echo -e "  ${YELLOW}⚠ TCPing 未启动${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ 跳过（socat 不可用）${NC}"
    fi

    # 自动更新（默认开启：每天检查正式版，预发布不动，坏版本被语法校验拦下）
    echo -e "\n${L_BLUE}── [+] 自动更新 ──────────────────────────────────────────${NC}"
    install_autoupdate
    if systemctl is-active --quiet vps-mgr-autoupdate.timer 2>/dev/null; then
        echo -e "  ${GREEN}✓ 已开启（每天检查正式版；预发布仅供手动测试）${NC}"
    else
        echo -e "  ${YELLOW}⚠ 开启失败${NC}"
    fi

    # ── 汇总报告 ─────────────────────────────────────────────
    echo
    echo -e "${L_PURPLE}─────────────────── 初始化汇总 ─────────────────────────${NC}"
    [ $_ok_sys -eq 1 ] \
        && echo -e "  系统更新    ${GREEN}✓${NC}" \
        || echo -e "  系统更新    ${RED}✗${NC}"
    if [ "$_xanmod_done" -eq 1 ]; then
        echo -e "  XanMod      ${GREEN}✓${NC}   ${WHITE}${_xanmod_pkg} 已安装，重启后生效${NC}"
    elif [ "$_xanmod_done" -eq 2 ]; then
        echo -e "  XanMod      ${GREEN}✓${NC}   ${WHITE}已运行 $(uname -r | sed 's/-x64v.*//')${NC}"
    else
        echo -e "  XanMod      ${YELLOW}跳过${NC}"
    fi
    [ $_ok_net -eq 1 ] \
        && echo -e "  网络优化    ${GREEN}✓${NC}   ${WHITE}${_net_bw}Mbps · rmem ${_rmem_mb}MB · CC: ${_cc}${NC}" \
        || echo -e "  网络优化    ${RED}✗${NC}"
    [ $_ok_fw -eq 1 ] \
        && echo -e "  防火墙      ${GREEN}✓${NC}" \
        || echo -e "  防火墙      ${YELLOW}跳过${NC}"
    [ $_ok_tg -eq 1 ] \
        && echo -e "  TG 推送     ${GREEN}✓${NC}" \
        || echo -e "  TG 推送     ${YELLOW}跳过${NC}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local _fb_banned; _fb_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")
        echo -e "  Fail2Ban    ${GREEN}✓${NC}   ${WHITE}封禁 ${_fb_banned} IP${NC}"
    else
        echo -e "  Fail2Ban    ${YELLOW}跳过${NC}"
    fi
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _tp; _tp=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        echo -e "  TCPing      ${GREEN}✓${NC}   ${WHITE}端口 ${_tp}${NC}"
    else
        echo -e "  TCPing      ${YELLOW}跳过${NC}"
    fi
    if [ "$_cc" = "bbr" ]; then
        if [ "$_xanmod_done" -eq 1 ]; then
            echo -e "  BBR v3      ${CYAN}⟳${NC}   ${WHITE}待重启后生效 (sysctl 已预写入)${NC}"
        elif [ "$_xanmod_done" -eq 2 ]; then
            echo -e "  BBR v3      ${GREEN}✓${NC}   ${WHITE}已生效 (XanMod 内核)${NC}"
        else
            echo -e "  BBR         ${GREEN}✓${NC}   ${WHITE}已启用 (原版内核 BBR v1)${NC}"
        fi
    else
        echo -e "  BBR         ${RED}✗${NC}   ${WHITE}内核不支持，当前使用 ${_cc}${NC}"
    fi
    echo -e "${L_PURPLE}─────────────────────────────────────────────────────────${NC}"
    # 新安装内核后给出重启提示
    if [ "$_xanmod_done" -eq 1 ]; then
        echo
        echo -e "  ${L_PURPLE}★ 请重启服务器以加载 XanMod 内核，BBR v3 方可生效${NC}"
        echo -ne "  ${L_PURPLE}立即重启？[Y/n]: ${NC}"
        local _rb_ans; read -r _rb_ans < /dev/tty || true
        [[ "${_rb_ans:-Y}" =~ ^[Nn]$ ]] || reboot
    fi
}


# ==============================================================================
# BBR 状态检测
# ==============================================================================

_get_bbr_version() {
    # M-02: 使用会话级缓存，内核内 BBR 版本在一次运行期间不会改变
    [ -n "$_G_BBR_VER" ] && { echo "$_G_BBR_VER"; return; }
    if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        _G_BBR_VER="none"; echo "none"; return
    fi
    # 通过模块版本号检测：modinfo tcp_bbr | version 字段，v3 补丁内核（XanMod 等）输出 3
    local _bmod
    _bmod=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/{print $2}')
    if [ "$_bmod" = "3" ]; then
        _G_BBR_VER="v3"; echo "v3"
    else
        _G_BBR_VER="v1"; echo "v1"
    fi
}


# ==============================================================================
# 主菜单
# ==============================================================================

# 全局日志辅助函数（定义在全局，避免在循环内重复定义污染命名空间）
_filter_fw_logs() {
    # L-04 修复: 匹配包含 DROP/REJECT/BLOCK 的内核日志行（包含 INPUT 方向 OUT= 为空的情况）
    grep -E --line-buffered 'IPT-DROP:|IN=[^ ]+.*\b(DROP|REJECT|BLOCK)\b' || true
}
_run_live_log() {
    if command -v journalctl &>/dev/null; then
        journalctl -k -f
    elif [ -f /var/log/kern.log ]; then
        tail -f /var/log/kern.log
    else
        dmesg -w
    fi
}
_run_static_log() {
    if command -v journalctl &>/dev/null; then
        journalctl -k -n 100 --no-pager
    elif [ -f /var/log/kern.log ]; then
        tail -n 100 /var/log/kern.log
    else
        dmesg | tail -n 100
    fi
}

# 两列菜单行输出函数：内部直接读取 COLUMNS，不依赖任何外部变量（H-03 修复）
_f2b_iptables_accept() {
    local _action="$1" _ip="$2"
    if [ "$_action" = "add" ]; then
        iptables -C INPUT -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT || {
                echo -e "${RED}错误: iptables 白名单添加失败: ${_ip}${NC}" >&2
                return 1
            }
    else
        iptables -D INPUT -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT 2>/dev/null || true
    fi
}

_f2b_apply_all_iptables() {
    [ -f "$F2B_WHITELIST" ] || return 0
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        if ! validate_ip_cidr "$_line"; then
            echo -e "${YELLOW}⚠ 白名单中无效条目，已跳过: ${_line}${NC}" >&2
            continue
        fi
        _f2b_iptables_accept add "$_line"
    done < "$F2B_WHITELIST"
    _persist_iptables
}

_f2b_build_ignoreip() {
    local _ips="127.0.0.1/8 ::1"
    if [ -f "$F2B_WHITELIST" ]; then
        while IFS= read -r _line; do
            [[ -z "$_line" || "$_line" == \#* ]] && continue
            _ips="$_ips $_line"
        done < "$F2B_WHITELIST"
    fi
    echo "$_ips"
}

_f2b_reload_whitelist() {
    local _ignoreip
    _ignoreip=$(_f2b_build_ignoreip)
    if [ -f /etc/fail2ban/jail.d/sshd.conf ]; then
        local _f2b_tmp; _f2b_tmp=$(mktemp)
        if grep -q "^ignoreip" /etc/fail2ban/jail.d/sshd.conf; then
            awk -v val="${_ignoreip}" \
                '/^ignoreip/{printf "ignoreip = %s\n", val; next} {print}' \
                /etc/fail2ban/jail.d/sshd.conf > "$_f2b_tmp" \
                && mv "$_f2b_tmp" /etc/fail2ban/jail.d/sshd.conf \
                || rm -f "$_f2b_tmp"
        else
            awk -v val="${_ignoreip}" \
                '/^\[sshd\]/{print; printf "ignoreip = %s\n", val; next} {print}' \
                /etc/fail2ban/jail.d/sshd.conf > "$_f2b_tmp" \
                && mv "$_f2b_tmp" /etc/fail2ban/jail.d/sshd.conf \
                || rm -f "$_f2b_tmp"
        fi
    fi
    systemctl is-active --quiet fail2ban 2>/dev/null && \
        fail2ban-client reload sshd >/dev/null 2>&1 || true
}

_install_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        echo -e "\n${L_CYAN}配置 Fail2Ban...${NC}"
    else
        echo -e "\n${L_CYAN}安装 Fail2Ban...${NC}"
        if ! command -v apt-get &>/dev/null; then
            echo -e "${RED}仅支持 apt 系统${NC}"; return 1
        fi
        apt-get update -qq || { echo -e "${RED}✗ apt-get update 失败${NC}"; return 1; }
        if ! apt-get install -y fail2ban python3-systemd >/dev/null 2>&1; then
            echo -e "${RED}✗ Fail2Ban 安装失败，请检查 apt 源${NC}"; return 1
        fi
        command -v fail2ban-client &>/dev/null || { echo -e "${RED}✗ 安装后未找到 fail2ban-client${NC}"; return 1; }
    fi

    local _ssh_port
    _ssh_port=$(get_current_ssh_port)
    local _f2b_action="%(action_)s"
    [ -f /etc/fail2ban/action.d/tg-notify.conf ] && \
        _f2b_action="${_f2b_action}
           tg-notify"
    cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled  = true
port     = ${_ssh_port}
maxretry = 3
bantime  = -1
findtime = 24h
backend  = systemd
ignoreip = $(_f2b_build_ignoreip)
action   = ${_f2b_action}
EOF
    _f2b_apply_all_iptables
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${GREEN}✓ Fail2Ban 已启动${NC}"
        echo -e "  SSH 配置: 24小时内失败 3 次 → 永久封禁  端口: ${_ssh_port}"
        fail2ban-client status sshd 2>/dev/null || true
    else
        echo -e "${RED}✗ fail2ban 启动失败，请检查: journalctl -u fail2ban${NC}"
    fi
}

_setup_ssh_tg_monitor() {
    echo -e "\n${L_CYAN}配置 SSH 登录 TG 通知${NC}"

    local _token="" _chat="" _alias="" _thread=""
    if [ -f "$SSH_TG_CONF" ]; then
        _token=$(grep "^TG_BOT_TOKEN=" "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        _chat=$(grep  "^TG_CHAT_ID="   "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        _thread=$(grep "^TG_THREAD_SSH=" "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        _alias=$(grep "^SERVER_NAME="  "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
    fi

    if [ -z "$_token" ] || [ -z "$_chat" ]; then
        echo -e "${RED}未找到 TG Token/话题群 Chat ID，请先在主菜单 ★3「TG 推送配置」中设置${NC}"
        return 1
    fi
    echo -e "  使用已配置的 Token=${_token:0:20}...  群=${_chat}${_thread:+  话题=${_thread}}"

    # 停止旧服务并杀掉所有残留进程
    systemctl stop "$SSH_TG_SERVICE" 2>/dev/null || true
    pkill -9 -f "$(basename "$SSH_TG_SCRIPT")" 2>/dev/null || true
    local _wait=0
    while pgrep -f "$(basename "$SSH_TG_SCRIPT")" >/dev/null 2>&1; do
        sleep 1; (( _wait++ )); [ "$_wait" -ge 5 ] && break
    done

    cat > "$SSH_TG_SCRIPT" <<'MONITOR_EOF'
#!/bin/bash
CONF="/etc/ssh-tg-monitor.conf"
[ -f "$CONF" ] || { echo "Config not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

SERVER_NAME=$(grep "^SERVER_NAME=" "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$(curl -4 -s --max-time 8 https://ip.sb 2>/dev/null \
               || curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null \
               || echo "unknown")
fi

# 纯字母数字标签 → 国旗 + #tag；已含 emoji/空格 → 直接显示
_srv_display() {
    local _n="$1"
    if [[ "$_n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        local _cc; _cc=$(grep "^SERVER_COUNTRY_CODE=" /opt/proxy-manager/server_info.cache 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
        local _f=""
        if [[ ${#_cc} -eq 2 && "$_cc" =~ ^[A-Za-z]+$ ]]; then
            _f=$(python3 -c "cc='${_cc^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
        fi
        echo "${_f:+${_f} }#${_n//-/_}"
    else
        echo "$_n"
    fi
}
send_tg() {
    # TG_THREAD_SSH 为空时不传 message_thread_id（普通群/频道场景仍可用）
    curl -s --max-time 10 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        ${TG_THREAD_SSH:+-d "message_thread_id=${TG_THREAD_SSH}"} \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$1" \
        >/dev/null 2>&1 || true
}

_wl_remark() {
    local _ip="$1" _wl="/etc/fail2ban/f2b-whitelist.conf"
    [ -f "$_wl" ] && grep -qxF "$_ip" "$_wl" && echo "管理IP"
}

_unit=""
for _u in ssh sshd; do
    systemctl cat "${_u}.service" &>/dev/null && _unit="$_u" && break
done
[ -z "$_unit" ] && { echo "SSH service not found" >&2; exit 1; }

journalctl -u "$_unit" --follow --lines=0 --output=cat 2>/dev/null \
| while IFS= read -r line; do
    ts=$(TZ="Asia/Shanghai" date '+%Y-%m-%d %H:%M:%S')
    SERVER_DISPLAY=$(_srv_display "$SERVER_NAME")
    if echo "$line" | grep -qE 'Accepted (password|publickey)'; then
        user=$(echo "$line"   | grep -oP 'for \K\S+(?= from)'  | head -1 || true)
        ip=$(echo "$line"     | grep -oP 'from \K[\d.]+'        | head -1 || true)
        method=$(echo "$line" | grep -oP '(?<=Accepted )\w+'    | head -1 || true)
        remark=$(_wl_remark "$ip")
        ip_label="<code>${ip:-unknown}</code>${remark:+ → #${remark}}"
        send_tg "✅ #SSH登录成功
服务器: ${SERVER_DISPLAY}
用户: ${user:-unknown}  来源: ${ip_label}
方式: ${method:-unknown}  时间: ${ts}"
    elif echo "$line" | grep -qE 'Failed (password|publickey) for'; then
        user=$(echo "$line" | grep -oP 'for (invalid user )?\K\S+(?= from)' | head -1 || true)
        ip=$(echo "$line"   | grep -oP 'from \K[\d.]+' | head -1 || true)
        remark=$(_wl_remark "$ip")
        ip_label="<code>${ip:-unknown}</code>${remark:+ → #${remark}}"
        send_tg "⚠️ #SSH登录失败
服务器: ${SERVER_DISPLAY}
用户: ${user:-unknown}  来源: ${ip_label}
时间: ${ts}"
    fi
done
MONITOR_EOF
    chmod 700 "$SSH_TG_SCRIPT"

    # fail2ban 封禁通知脚本
    mkdir -p /etc/fail2ban/action.d
    cat > /usr/local/bin/fail2ban-tg-notify.sh <<'F2B_EOF'
#!/bin/bash
CONF="/etc/ssh-tg-monitor.conf"
[ -f "$CONF" ] || exit 0
# shellcheck source=/dev/null
source "$CONF"
IP="$1" JAIL="$2" FAILURES="$3"
SERVER_NAME=$(grep "^SERVER_NAME=" "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$(curl -4 -s --max-time 5 https://ip.sb 2>/dev/null \
               || hostname -I 2>/dev/null | awk '{print $1}' \
               || echo "unknown")
fi
if [[ "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    _cc=$(grep "^SERVER_COUNTRY_CODE=" /opt/proxy-manager/server_info.cache 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
    _f=""
    [[ ${#_cc} -eq 2 && "$_cc" =~ ^[A-Za-z]+$ ]] && _f=$(python3 -c "cc='${_cc^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
    SERVER_DISPLAY="${_f:+${_f} }#${SERVER_NAME//-/_}"
else
    SERVER_DISPLAY="$SERVER_NAME"
fi
ts=$(TZ="Asia/Shanghai" date '+%Y-%m-%d %H:%M:%S')
curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    ${TG_THREAD_SSH:+-d "message_thread_id=${TG_THREAD_SSH}"} \
    -d "parse_mode=HTML" \
    --data-urlencode "text=🚫 #IP已封禁
服务器: ${SERVER_DISPLAY}
封禁IP: <code>${IP}</code>
原因: 登录失败${FAILURES}次 (永久封禁)
时间: ${ts}" \
    >/dev/null 2>&1 || true
F2B_EOF
    chmod 700 /usr/local/bin/fail2ban-tg-notify.sh

    cat > /etc/fail2ban/action.d/tg-notify.conf <<'F2B_ACT'
[Definition]
actionban = conntrack -D -s <ip> >/dev/null 2>&1 || true
            /usr/local/bin/fail2ban-tg-notify.sh <ip> <name> <failures>
actionunban =
F2B_ACT

    cat > "/etc/systemd/system/${SSH_TG_SERVICE}.service" <<EOF
[Unit]
Description=SSH Login TG Notifier
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SSH_TG_SCRIPT}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$SSH_TG_SERVICE" 2>/dev/null || true
    systemctl restart "$SSH_TG_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null; then
        # 发送启动测试消息
        local _ts _alias_display
        _ts=$(TZ="$TZ_DEFAULT" date '+%Y-%m-%d %H:%M:%S')
        if [[ "$_alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            local _cc_s _gf=""
            _cc_s=$(grep -E '^SERVER_COUNTRY_CODE=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            # cache 无效时现场查 geo
            if [[ -z "$_cc_s" || "$_cc_s" == "UN" || ${#_cc_s} -ne 2 ]]; then
                _cc_s=$(curl -sf --max-time 8 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]' || true)
            fi
            if [[ ${#_cc_s} -eq 2 && "$_cc_s" =~ ^[A-Za-z]+$ ]]; then
                _gf=$(python3 -c "cc='${_cc_s^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
            fi
            _alias_display="${_gf:+${_gf} }#${_alias}"
        else
            _alias_display="$_alias"
        fi
        curl -s --max-time 10 \
            "https://api.telegram.org/bot${_token}/sendMessage" \
            -d "chat_id=${_chat}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=✅ #SSH监控已启动
服务器: ${_alias_display}
时间: ${_ts}" >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ TG 推送服务已启动，已发送测试消息${NC}"
    else
        echo -e "${RED}✗ 服务启动失败，请检查: journalctl -u ${SSH_TG_SERVICE}${NC}"
    fi

}

do_ssh_security() {
    while true; do
        clear
        echo -e "${L_BLUE}:: Fail2Ban ::${NC}\n"

        local _fb_st
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local _banned
            _banned=$(fail2ban-client status sshd 2>/dev/null \
                      | grep "Currently banned" | awk '{print $NF}' || echo "?")
            _fb_st="${GREEN}运行中 (已封禁: ${_banned})${NC}"
        elif command -v fail2ban-client &>/dev/null; then
            _fb_st="${YELLOW}已安装未运行${NC}"
        else
            _fb_st="${RED}未安装${NC}"
        fi

        echo -e "  Fail2Ban : $_fb_st\n"
        local _wl_count
        _wl_count=$(awk '!/^#|^[[:space:]]*$/{c++} END{print c+0}' "$F2B_WHITELIST" 2>/dev/null || echo 0)
        echo -e "  1. 白名单管理  [${_wl_count} 个 IP]"
        echo -e "  2. 查看封禁 IP 列表"
        echo -e "  0. 返回\n"
        echo -ne "${BLUE}请选择 [0-2]: ${NC}"; read -r _sec_ch
        case "$_sec_ch" in
            1)
                clear
                echo -e "${L_BLUE}--- Fail2Ban 白名单 ---${NC}\n"
                echo -e "  当前白名单:"
                if [ -f "$F2B_WHITELIST" ] && grep -qv "^#\|^[[:space:]]*$" "$F2B_WHITELIST" 2>/dev/null; then
                    grep -v "^#\|^[[:space:]]*$" "$F2B_WHITELIST" | awk '{print $1}' | nl -ba | \
                        while IFS= read -r _l; do echo -e "    ${CYAN}${_l}${NC}"; done
                else
                    echo -e "    ${YELLOW}（空）${NC}"
                fi
                echo
                echo -ne "${L_PURPLE}输入要添加的 IP/CIDR (回车跳过): ${NC}"; read -r _wl_add < /dev/tty || true
                if [[ -n "$_wl_add" ]]; then
                    if validate_ip_cidr "$_wl_add"; then
                        echo "${_wl_add}" >> "$F2B_WHITELIST"
                        _f2b_reload_whitelist
                        _f2b_iptables_accept add "$_wl_add"
                        _persist_iptables
                        fail2ban-client set sshd unbanip "$_wl_add" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✓ ${_wl_add} 已加入白名单${NC}"
                    else
                        echo -e "${RED}✗ IP 格式无效${NC}"
                    fi
                fi
                echo -ne "${L_PURPLE}输入要删除的 IP (回车跳过): ${NC}"; read -r _wl_del < /dev/tty || true
                if [[ -n "$_wl_del" ]]; then
                    if grep -qxF "$_wl_del" "$F2B_WHITELIST" 2>/dev/null; then
                        local _wl_tmp; _wl_tmp=$(mktemp)
                        grep -vxF -- "$_wl_del" "$F2B_WHITELIST" > "$_wl_tmp" && mv "$_wl_tmp" "$F2B_WHITELIST" || rm -f "$_wl_tmp"
                        _f2b_reload_whitelist
                        _f2b_iptables_accept del "$_wl_del"
                        _persist_iptables
                        echo -e "${GREEN}✓ ${_wl_del} 已从白名单移除${NC}"
                    else
                        echo -e "${RED}✗ 未在白名单中找到该 IP${NC}"
                    fi
                fi
                pause
                ;;
            2)
                clear
                echo -e "${L_YELLOW}--- Fail2Ban 封禁 IP 列表 ---${NC}\n"
                if ! command -v fail2ban-client &>/dev/null; then
                    echo -e "${RED}Fail2Ban 未安装${NC}"; pause; continue
                fi
                fail2ban-client status sshd 2>/dev/null || echo -e "${YELLOW}fail2ban 未运行${NC}"
                echo
                echo -ne "${L_PURPLE}输入要解封的 IP (直接回车跳过): ${NC}"; read -r _unban_ip
                if [[ -n "$_unban_ip" ]]; then
                    if fail2ban-client set sshd unbanip "$_unban_ip" 2>/dev/null; then
                        echo -e "${GREEN}✓ ${_unban_ip} 已解封${NC}"
                    else
                        echo -e "${RED}✗ 解封失败，请确认 IP 是否在封禁列表中${NC}"
                    fi
                    pause
                fi
                ;;
            0|"") return ;;
            *) continue ;;
        esac
    done
}


# ==============================================================================
# 系统管理子菜单包装函数
# ==============================================================================

# 子菜单 5：系统维护 & 诊断
sys_maintenance_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== 系统维护 & 诊断 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 系统更新\n"
        printf " ${C_GREEN}2.${C_RESET} 带宽重调 (sysctl+tc)\n"
        printf " ${C_GREEN}3.${C_RESET} IPv6 管理\n"
        printf " ${C_GREEN}4.${C_RESET} 一键参数检测\n"
        printf " ${C_GREEN}5.${C_RESET} 查看系统详情\n"
        printf " ${C_GREEN}6.${C_RESET} 修改服务器名称\n"
        printf " ${C_GREEN}7.${C_RESET} TCPing 监控\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r _msub
        case "$_msub" in
            1) do_system_update || true; pause ;;
            2) do_retune_bandwidth || true; pause ;;
            3) toggle_ipv6; pause ;;
            4) do_check_all; pause ;;
            6) _set_server_name; pause ;;
            7) do_tcping_monitor; pause ;;
            5)
                clear
                echo -e "${L_GREEN}--- 系统深度信息 ---${NC}"
                echo -e "${L_CYAN}Kernel:${NC} $(uname -r)"
                echo -e "${L_CYAN}Uptime:${NC} $(uptime -p)"
                echo -e "${L_CYAN}CPU Model:${NC} $(grep 'model name' /proc/cpuinfo | head -1 | awk -F: '{print $2}' | sed 's/^[ \t]*//')"
                echo -e "${L_CYAN}Load Avg:${NC} $(uptime | awk -F'load average:' '{print $2}')"
                echo
                free -h
                echo
                echo -e "${L_BLUE}[ 网络连接 ]${NC}"
                if command -v ss &>/dev/null; then
                    echo -e "TCP: $(ss -s | grep TCP | head -1 | awk '{print $2}')   UDP: $(ss -s | grep UDP | head -1 | awk '{print $2}')"
                else
                    echo "TCP/UDP info unavailable (ss missing)"
                fi
                echo -e "\n${L_BLUE}[ 流量统计 (主要接口) ]${NC}"
                local DEF_IF; DEF_IF=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
                if [ -n "$DEF_IF" ]; then
                    echo -e "接口: ${GREEN}$DEF_IF${NC}"
                    ip -s link show "$DEF_IF" | awk '/RX:/{getline; print "RX: " $1 " bytes (" $2 " pkts)"} /TX:/{getline; print "TX: " $1 " bytes (" $2 " pkts)"}'
                else
                    echo "Default interface not found."
                fi
                echo -e "\n${L_BLUE}[ 磁盘使用 ]${NC}"
                df -hT | grep -E "^/dev|^Filesystem" | head -5
                pause
                ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# 子菜单 6：防火墙 & 规则
sys_firewall_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== 防火墙 & 规则 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 重置防火墙策略\n"
        printf " ${C_GREEN}2.${C_RESET} 开放端口\n"
        printf " ${C_GREEN}3.${C_RESET} 删除规则\n"
        printf " ${C_GREEN}4.${C_RESET} IP 黑白名单管理\n"
        printf " ${C_GREEN}5.${C_RESET} 查看详细规则\n"
        printf " ${C_GREEN}6.${C_RESET} 查看监听端口\n"
        printf " ${C_GREEN}7.${C_RESET} 查看系统日志\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r _fsub
        case "$_fsub" in
            1) do_init_firewall; pause ;;
            2)
                echo -ne "${BLUE}端口: ${NC}"; read -r p
                if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                    echo -e "${RED}无效端口号${NC}"; sleep 1; continue
                fi
                echo -ne "${BLUE}协议(tcp/udp/all)[tcp]: ${NC}"; read -r pr
                pr=${pr:-tcp}
                if [[ "$pr" != "tcp" && "$pr" != "udp" && "$pr" != "all" ]]; then
                    echo -e "${RED}无效协议，请输入 tcp/udp/all${NC}"; sleep 1; continue
                fi
                if [ "$pr" = "all" ]; then
                    _firewall_open_port "tcp" "$p"; _firewall_open_port "udp" "$p"
                else
                    _firewall_open_port "$pr" "$p"
                fi
                _persist_iptables
                echo -e "${GREEN}已开放${NC}"
                pause
                ;;
            3)
                local c del_mode del_port l
                echo -ne "${BLUE}链(INPUT/OUTPUT/FORWARD): ${NC}"; read -r c; c=${c:-INPUT}
                case "$c" in
                    INPUT|OUTPUT|FORWARD|PREROUTING|POSTROUTING) ;;
                    *) echo -e "${RED}无效链名${NC}"; sleep 1; continue ;;
                esac
                while true; do
                    clear
                    echo -e "${L_BLUE}:: 删除规则 ($c) ::${NC}"
                    echo -e "1. 按行号删除 (循环模式)"
                    echo -e "2. 按端口删除 (TCP+UDP 批量)"
                    echo -e "0. 返回"
                    echo
                    echo -ne "${L_PURPLE}请选择: ${NC}"; read -r del_mode
                    case "$del_mode" in
                        1)
                            while true; do
                                clear
                                iptables -L "$c" -nv --line-numbers
                                echo -e "\n${L_YELLOW}输入行号 (输入 0 返回上一级)${NC}"
                                echo -ne "${L_PURPLE}行号: ${NC}"; read -r l
                                if [[ -z "$l" ]]; then continue; fi
                                if [[ "$l" == "0" ]]; then break; fi
                                if ! [[ "$l" =~ ^[0-9]+$ ]]; then echo -e "${RED}无效数字${NC}"; sleep 1; continue; fi
                                if iptables -D "$c" "$l" 2>/dev/null; then
                                    _persist_iptables
                                    echo -e "${GREEN}规则 $l 已删除${NC}"
                                else
                                    echo -e "${RED}删除失败 (检查行号是否存在)${NC}"
                                fi
                                sleep 1
                            done
                            ;;
                        2)
                            echo -e "${L_BLUE}:: 本机监听端口 ::${NC}"
                            ss -tulpn 2>/dev/null | awk 'NR>1{
                                n=split($5,a,":");port=a[n]
                                proc=(NF>=7&&$7~/users/)?$7:"-"
                                gsub(/.*\(\("/,"",proc); gsub(/".*/, "",proc)
                                if(port+0>0) print port,proc
                            }' | sort -n | uniq | while read -r p name; do
                                echo -e "   -> ${GREEN}${p}${NC}\t(${name})"
                            done
                            echo
                            echo -ne "${L_PURPLE}请输入端口号: ${NC}"; read -r del_port
                            if [[ -n "$del_port" && "$del_port" =~ ^[0-9]+$ ]]; then
                                if _safe_iptables_remove_rule "dport ${del_port}[^0-9]" -E; then
                                    _persist_iptables
                                    echo -e "${GREEN}端口 $del_port 关联规则已全部移除${NC}"
                                else
                                    echo -e "${RED}删除失败，防火墙规则未更改${NC}"
                                fi
                                pause
                            else
                                echo -e "${RED}无效端口${NC}"; sleep 1
                            fi
                            ;;
                        0) break ;;
                        *) continue ;;
                    esac
                done
                ;;
            4)
                while true; do
                    clear
                    echo -e "${L_BLUE}:: IP 黑白名单管理 ::${NC}"
                    echo -e "1. 白名单 IP - 放行指定 IP/CIDR"
                    echo -e "2. 黑名单 IP - 屏蔽指定 IP/CIDR"
                    echo -e "0. 返回"
                    echo
                    echo -ne "${L_PURPLE}请选择: ${NC}"; read -r bw_choice
                    case "$bw_choice" in
                        1)
                            echo -ne "${BLUE}IP (支持CIDR): ${NC}"; read -r i
                            if [[ -z "$i" ]] || ! validate_ip_cidr "$i"; then
                                echo -e "${RED}无效 IP/CIDR${NC}"; sleep 1; continue
                            fi
                            iptables -C INPUT -s "$i" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s "$i" -j ACCEPT
                            _persist_iptables
                            echo -e "${GREEN}完成${NC}"; pause; break ;;
                        2)
                            echo -ne "${BLUE}IP (支持CIDR): ${NC}"; read -r i
                            if [[ -z "$i" ]] || ! validate_ip_cidr "$i"; then
                                echo -e "${RED}无效 IP/CIDR${NC}"; sleep 1; continue
                            fi
                            iptables -C INPUT -s "$i" -j DROP 2>/dev/null || iptables -A INPUT -s "$i" -j DROP
                            _persist_iptables
                            echo -e "${GREEN}完成${NC}"; pause; break ;;
                        0) break ;;
                        *) continue ;;
                    esac
                done
                ;;
            5) clear; iptables -L -nv --line-numbers; pause ;;
            6) clear; ss -tulpn; pause ;;
            7)
                echo -e "\n${L_BLUE}:: 日志查看模式 ::${NC}"
                echo -e "1. 拦截日志-静态 (仅显示被墙记录)"
                echo -e "2. 拦截日志-实时"
                echo -e "3. 完整日志-实时"
                echo -ne "${BLUE}请选择: ${NC}"; read -r log_opt
                case "$log_opt" in
                    1)
                        clear
                        echo -e "${L_YELLOW}--- 拦截日志 (最后 100 条) ---${NC}"
                        _run_static_log | _filter_fw_logs
                        pause
                        ;;
                    2)
                        echo -e "${L_YELLOW}正在监控拦截日志... (按任意键退出)${NC}"
                        _run_live_log | _filter_fw_logs &
                        local PID=$!
                        read -n 1 -s -r
                        local _pgid
                        _pgid=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')
                        if [ -n "$_pgid" ] && [ "$_pgid" != "$$" ]; then
                            kill -- -"$_pgid" 2>/dev/null || kill "$PID" 2>/dev/null || true
                        else
                            kill "$PID" 2>/dev/null || true
                        fi
                        ;;
                    3)
                        echo -e "${L_YELLOW}正在监控完整内核日志... (按任意键退出)${NC}"
                        _run_live_log &
                        local PID=$!
                        read -n 1 -s -r
                        kill "$PID" 2>/dev/null || true
                        ;;
                    *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
                esac
                ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ==============================================================================
# SECTION 7: 代理服务模块（来自 Snell+Realm+SS.sh）
# ==============================================================================


get_country_code_for_ip() {
    local ip=$1
    local code=""
    code=$(curl -s --max-time 3 "https://ipapi.co/${ip}/country/" | tr -d '[:space:]')
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        code=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/country" | tr -d '[:space:]')
    fi
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        code=$(curl -s --max-time 3 "https://ip-api.com/json/${ip}" | jq -r '.countryCode // empty' 2>/dev/null || true)
    fi
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        echo "UN"
    else
        echo "${code^^}"
    fi
}

check_system() {
    if ! command -v systemctl &>/dev/null; then
        die "此脚本需要 systemd 支持。"
    fi
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"
}

setup_log_rotation() {
    if command -v logrotate &>/dev/null; then
        # 总是覆盖写入最新的日志轮转配置，确保旧版本升级后能生效
        cat > /etc/logrotate.d/proxy-manager <<'EOF' || { msg_warn "logrotate 配置写入失败"; return 1; }
/var/log/proxy-manager.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 600 root root
}
EOF
        chmod 644 /etc/logrotate.d/proxy-manager
    fi
}

# ------------------------------------------------------------------------------
# 配置文件验证
# ------------------------------------------------------------------------------
validate_realm_config() {
    local config_file=$1
    [[ ! -f "$config_file" ]] && return 1
    # 校验 JSON 有效 + endpoints 为数组 + 每个 endpoint 含 listen/remote 字符串字段
    jq -e '
        (.endpoints | type == "array") and
        ([.endpoints[] | select((.listen | type) != "string" or (.remote | type) != "string")] | length == 0)
    ' "$config_file" >/dev/null 2>&1
}

# 创建 snell 模板服务文件 (snell@.service，%i = 端口号)
create_snell_template_service() {
    cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service (port %i)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="${SNELL_BIN}" -c "${SNELL_CONFIG_DIR}/snell-%i.conf"
Restart=on-failure
RestartSec=2
LimitNOFILE=${ULIMIT_NOFILE}
LimitNPROC=${ULIMIT_NOFILE}
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

# ------------------------------------------------------------------------------
# 网络与服务器信息
# ------------------------------------------------------------------------------




get_geo_info() {
    local ip=$1 data _parsed country_code="" country_name="" city=""
    local sources=(
        "https://ipapi.co/${ip}/json/"
        "https://ipinfo.io/${ip}/json"
        "https://ip-api.com/json/${ip}"
    )
    for api in "${sources[@]}"; do
        data=$(curl -sf --max-time 8 "$api" 2>/dev/null) || continue
        _parsed=$(printf '%s' "$data" | jq -r '
            if .country_code then
                [.country_code, (.country_name // .country // ""), (.city // "")]
            elif .countryCode then
                [.countryCode, (.country // ""), (.city // "")]
            elif .country then
                [.country, .country, (.city // "")]
            else empty
            end | @tsv' 2>/dev/null) || continue
        [[ -z "$_parsed" ]] && continue
        IFS=$'\t' read -r country_code country_name city <<< "$_parsed"
        country_code="${country_code^^}"
        [[ -n "$country_code" ]] && { SERVER_COUNTRY_CODE=$country_code; SERVER_COUNTRY_NAME=${country_name:-$country_code}; SERVER_CITY=${city:-Unknown}; return 0; }
    done
    return 1
}

# 安全解析缓存文件（仅提取白名单字段，不使用 source 以防代码注入）
_read_cache_value() {
    # $1: key, $2: file — awk 逐字段精确匹配，无正则注入风险
    local _val
    _val=$(awk -F= -v k="$1" \
        '$1 == k { v = substr($0, length(k)+2); gsub(/^["'"'"']|["'"'"']$/, "", v); print v; exit }' \
        "$2" 2>/dev/null || true)
    printf '%s' "$_val"
}

get_server_info() {
    if [[ -f "$CACHE_FILE" ]] && [[ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt $CACHE_TTL ]]; then
        local _ip _cc _cn _city
        _ip=$(_read_cache_value   "SERVER_IP"           "$CACHE_FILE")
        _cc=$(_read_cache_value   "SERVER_COUNTRY_CODE" "$CACHE_FILE")
        _cn=$(_read_cache_value   "SERVER_COUNTRY_NAME" "$CACHE_FILE")
        _city=$(_read_cache_value "SERVER_CITY"         "$CACHE_FILE")
        if [[ -n "$_cc" && "$_cc" != "UN" && "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            SERVER_COUNTRY_CODE="$_cc"
            SERVER_COUNTRY_NAME="${_cn:-$_cc}"
            SERVER_CITY="${_city:-Unknown}"
        fi
    else
        local _ip
        _ip=$(get_public_ip 2>/dev/null || true)
        if [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            get_geo_info "$_ip" || true
            mkdir -p "$WORK_DIR"
            {
                printf 'SERVER_IP=%s\n'           "$SERVER_IP"
                printf 'SERVER_COUNTRY_CODE=%s\n' "$SERVER_COUNTRY_CODE"
                printf 'SERVER_COUNTRY_NAME=%s\n' "$SERVER_COUNTRY_NAME"
                printf 'SERVER_CITY=%s\n'         "$SERVER_CITY"
            } > "$CACHE_FILE"
            chmod 600 "$CACHE_FILE"
        fi
    fi
}


# ------------------------------------------------------------------------------
# 核心服务管理逻辑
# ------------------------------------------------------------------------------

# 获取已安装的版本号
get_installed_version() {
    local service_name=$1
    local bin_path=$2
    local ver=""
    case "$service_name" in
        snell)
            # Snell 无 --version，读安装时落盘的版本号；缺失（旧脚本装的）则回退内置版本
            if [[ -f "$SNELL_BIN" ]]; then
                ver=$(cat "$SNELL_VERSION_FILE" 2>/dev/null || true)
                [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || ver="${SNELL_VERSION_OVERRIDE}"
            fi
            ;;
        realm)
            if [[ -f "$REALM_BIN" ]]; then
                # realm 输出形如: realm x.x.x 或带 v 前缀，同时兼容 stderr
                local raw
                raw=$("$REALM_BIN" --version 2>&1 || "$REALM_BIN" -V 2>&1 || true)
                ver=$(echo "$raw" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                [[ -n "$ver" && "$ver" != v* ]] && ver="v${ver}"
            fi
            ;;
    esac
    echo "${ver:-未知}"
}

check_service_status() {
    local service_name=$1
    local bin_path=$2

    if [[ ! -f "$bin_path" ]]; then
        printf '%b' "${C_RED}未安装${C_RESET}"
        return
    fi

    # Snell 使用模板服务 snell@.service，每个节点是独立实例
    if [[ "$service_name" == "snell" ]]; then
        if ! systemctl cat "snell@.service" &>/dev/null; then
            printf '%b' "${C_YELLOW}已安装 (模板服务丢失)${C_RESET}"
            return
        fi
        local active_cnt
        active_cnt=$(systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -c 'snell@' || echo 0)
        if [[ "$active_cnt" -gt 0 ]]; then
            printf '%b' "${C_GREEN}运行中 (${active_cnt} 实例)${C_RESET}"
        else
            printf '%b' "${C_YELLOW}已停止${C_RESET}"
        fi
        return
    fi

    if ! systemctl cat "${service_name}.service" &>/dev/null; then
        printf '%b' "${C_YELLOW}已安装 (服务丢失)${C_RESET}"
        return
    fi
    if systemctl is-active --quiet "${service_name}.service"; then
        printf '%b' "${C_GREEN}运行中${C_RESET}"
    elif systemctl is-enabled --quiet "${service_name}.service"; then
        printf '%b' "${C_YELLOW}已停止${C_RESET}"
    else
        printf '%b' "${C_RED}已禁用${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# 版本检查与更新
# ------------------------------------------------------------------------------

# 从 Surge KB 抓取 Snell 最新【稳定版】(排除 beta)。
# 锚定到 snell-server-vX.Y.Z-linux 下载链接取版本——页面上还混着 Surge 客户端等无关
# 版本号，直接 grep 全页会误取（如 v7.2.0）。'-linux' 紧跟补丁号，天然排除 bN 结尾的
# beta。任何一步失败都回退内置 SNELL_VERSION_OVERRIDE，保证抓取源挂了也不影响装/升级。
_snell_latest_stable() {
    local _html _ver
    _html=$(curl -fsSL --max-time 12 "$SNELL_KB_URL" 2>/dev/null) \
        || { echo "$SNELL_VERSION_OVERRIDE"; return; }
    _ver=$(printf '%s' "$_html" \
        | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+-linux' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)
    [[ "$_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$_ver" || echo "$SNELL_VERSION_OVERRIDE"
}

# 后台空闲检查新版本 (每24小时一次)，结果写入缓存
check_updates_background() {
    # 如果缓存文件存在且未超期，跳过
    if [[ -f "$UPDATE_CHECK_CACHE" ]] && \
       [[ $(( $(date +%s) - $(stat -c %Y "$UPDATE_CHECK_CACHE" 2>/dev/null || echo 0) )) -lt $UPDATE_CHECK_INTERVAL ]]; then
        return 0
    fi

    # 在后台执行，不阻塞启动（子 shell 继承函数作用域，变量天然隔离）
    (
        results=""
        NL=$'\n'

        # 检查 Snell (从 Surge KB 抓稳定版，无 GitHub API)
        snell_installed=""
        [[ -f "$SNELL_BIN" ]] && snell_installed=$(get_installed_version snell "$SNELL_BIN")
        if [[ -n "$snell_installed" && -f "$SNELL_BIN" ]]; then
            snell_latest=$(_snell_latest_stable)
            if [[ "$snell_installed" != "$snell_latest" && "$snell_installed" != "未知" ]]; then
                results+="snell:${snell_latest}${NL}"
            fi
        fi

        # 检查 Realm 最新版本
        _realm_latest_file=$(mktemp)
        trap 'rm -f "$_realm_latest_file"' EXIT
        if [[ -f "$REALM_BIN" ]]; then
            curl -s --max-time 10 "https://api.github.com/repos/zhboner/realm/releases/latest" \
                | jq -r '.tag_name // empty' > "$_realm_latest_file" 2>/dev/null &
        fi
        wait

        if [[ -f "$REALM_BIN" ]]; then
            realm_latest=$(cat "$_realm_latest_file" 2>/dev/null || true)
            rm -f "$_realm_latest_file"
            realm_installed=$(get_installed_version realm "$REALM_BIN")
            if [[ -n "$realm_latest" && -n "$realm_installed" && "$realm_latest" != "$realm_installed" && "$realm_installed" != "未知" ]]; then
                results+="realm:${realm_latest}${NL}"
            fi
        fi

        # 写入缓存 (真实换行)
        printf '%s' "$results" > "$UPDATE_CHECK_CACHE"
    ) &
    disown 2>/dev/null || true
}

# 读取缓存，返回某服务的最新版本 (如有)
get_cached_latest_version() {
    local service_name=$1
    if [[ ! -f "$UPDATE_CHECK_CACHE" ]]; then echo ""; return; fi
    grep -m1 "^${service_name}:" "$UPDATE_CHECK_CACHE" 2>/dev/null | cut -d: -f2 || true
}

# 更新单个服务
update_service() {
    local service_name=$1

    case "$service_name" in
        snell)
            if [[ ! -f "$SNELL_BIN" ]]; then msg_error "Snell 未安装。"; return; fi
            local installed _latest
            installed=$(get_installed_version snell "$SNELL_BIN")
            msg_step "正在从 Surge KB 查询最新稳定版..."
            _latest=$(_snell_latest_stable)
            printf "  当前已安装: ${C_YELLOW}%s${C_RESET}\n" "$installed"
            printf "  最新稳定版: ${C_GREEN}%s${C_RESET}\n" "$_latest"
            printf "\n${C_CYAN}请输入目标版本号或完整下载链接 (直接回车使用最新稳定版 %s):${C_RESET}\n" "$_latest"
            printf "  格式1 - 版本号: ${C_WHITE}v5.0.2${C_RESET}  (装 beta 如 v6.0.0b4 也可)\n"
            printf "  格式2 - 完整URL: ${C_WHITE}https://dl.nssurge.com/snell/snell-server-vX.X.X-linux-amd64.zip${C_RESET}\n"
            printf "${C_PURPLE}>>> ${C_RESET}"
            read -r snell_input
            snell_input="${snell_input// /}"

            local target_version snell_download_url
            if [[ -z "$snell_input" ]]; then
                target_version="$_latest"
                snell_download_url="https://dl.nssurge.com/snell/snell-server-${target_version}-linux-${SNELL_ARCH}.zip"
            elif [[ "$snell_input" =~ ^https:// ]]; then
                snell_download_url="$snell_input"
                target_version=$(echo "$snell_input" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "(自定义)")
            elif [[ "$snell_input" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?$ ]]; then
                [[ "$snell_input" != v* ]] && snell_input="v${snell_input}"
                target_version="$snell_input"
                snell_download_url="https://dl.nssurge.com/snell/snell-server-${target_version}-linux-${SNELL_ARCH}.zip"
            else
                msg_error "格式无法识别，请输入版本号 (如 v5.0.2) 或完整 URL。"
                return
            fi

            if [[ "$installed" == "$target_version" && "$target_version" != "(自定义)" ]]; then
                msg_info "Snell 已是 ${target_version}，无需更新。"
                printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
            fi

            msg_step "正在更新 Snell -> ${target_version}..."
            printf "  下载: ${C_CYAN}%s${C_RESET}\n" "$snell_download_url"
            install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$snell_download_url" "zip" "true"
            # 同步更新 template service 文件（含 OOMScoreAdjust/RestartSec/StartLimitIntervalSec）
            create_snell_template_service
            systemctl daemon-reload
            manage_services "restart" "snell"
            msg_success "Snell 已更新到 ${target_version}。"
            rm -f "$UPDATE_CHECK_CACHE"
            ;;
        sing-box)
            if [[ ! -x "$SBX_BIN" ]]; then msg_error "sing-box 未安装。"; return; fi
            local cur; cur=$("$SBX_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1 || true)
            msg_step "正在更新 sing-box (当前 ${cur:-?}，重新下载最新版)..."
            rm -f "$SBX_BIN"
            if sbx_install_core; then
                sbx_render || true
                msg_success "sing-box 已更新。"
                rm -f "$UPDATE_CHECK_CACHE"
            else
                msg_error "sing-box 更新失败。"
            fi
            ;;
        realm)
            if [[ ! -f "$REALM_BIN" ]]; then msg_error "Realm 未安装。"; return; fi
            local installed
            installed=$(get_installed_version realm "$REALM_BIN")
            msg_step "正在查询 Realm 最新版本..."
            local latest
            latest=$(curl -s --max-time 15 "https://api.github.com/repos/zhboner/realm/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
            if [[ -z "$latest" ]]; then msg_error "无法获取最新版本，请检查网络。"; return; fi
            printf "  已安装版本: ${C_YELLOW}%s${C_RESET}\n" "$installed"
            printf "  GitHub 最新: ${C_GREEN}%s${C_RESET}\n" "$latest"
            if [[ "$installed" == "$latest" ]]; then
                msg_info "Realm 已是最新版本，无需更新。"
                printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
            fi
            msg_step "正在更新 Realm ${installed} -> ${latest}..."
            local arch_name="x86_64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "aarch64" ]] && arch_name="aarch64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "armv7l"  ]] && arch_name="armv7-unknown-linux-gnueabihf"
            local url="https://github.com/zhboner/realm/releases/download/${latest}/realm-${arch_name}.tar.gz"
            install_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$url" "tar" "true"
            # 同步更新 service 文件（含 OOMScoreAdjust/RestartSec/StartLimitIntervalSec）
            create_realm_service_file
            systemctl daemon-reload
            _realm_safe_restart
            msg_success "Realm 已更新到 ${latest}。"
            rm -f "$UPDATE_CHECK_CACHE"
            ;;
        *) msg_error "未知服务: $service_name" ;;
    esac
}

install_service() {
    local service_name=$1
    local user=$2
    local bin_path=$3
    local config_dir=$4
    local download_url=$5
    local archive_type=$6
    local force_overwrite="${7:-false}"  # true = 更新场景，跳过覆盖确认

    msg_step "开始安装 ${service_name}..."
    if [[ -f "$bin_path" ]]; then
        if [[ "$force_overwrite" == "true" ]]; then
            msg_info "检测到旧版本，将直接替换二进制（配置文件不受影响）..."
        else
            printf "${C_YELLOW}%s 已存在, 是否覆盖安装? [y/N]: ${C_RESET}" "$service_name"
            read -r answer
            if [[ "${answer,,}" != "y" ]]; then
                msg_warn "安装已取消。"
                return 1
            fi
        fi
    fi

    systemctl stop "${service_name}@*.service" &>/dev/null || true
    systemctl stop "${service_name}.service" &>/dev/null || true
    if ! id "$user" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d /nonexistent "$user"
    fi
    mkdir -p "$config_dir"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # RETURN trap 仅在函数 return 时触发，die() 调用 exit，需在 die 前手动清理
    trap "rm -rf '$tmp_dir'" RETURN
    local archive_file="${tmp_dir}/archive"

    msg_step "正在下载 ${service_name}..."
    if ! wget -qO "$archive_file" "$download_url"; then
        rm -rf "$tmp_dir"
        die "下载失败。"
    fi
    # 完整性校验: 拦截 404/错误页被当成压缩包保存的情况（正常发布包远大于 1KB）
    local _dl_size
    _dl_size=$(stat -c %s "$archive_file" 2>/dev/null || echo 0)
    if [[ "${_dl_size:-0}" -lt 1024 ]]; then
        rm -rf "$tmp_dir"
        die "下载文件异常（仅 ${_dl_size} 字节，疑似下载地址失效或被重定向）。"
    fi

    msg_step "正在解压文件..."
    if [[ "$archive_type" == "zip" ]]; then
        if ! unzip -oq "$archive_file" -d "$tmp_dir"; then rm -rf "$tmp_dir"; die "ZIP 解压失败"; fi
    else
        if ! tar -xf "$archive_file" -C "$tmp_dir"; then rm -rf "$tmp_dir"; die "TAR 解压失败"; fi
    fi

    local bin_in_archive
    # 多文件场景下只取第一个匹配，避免 mv 失败
    bin_in_archive=$(find "$tmp_dir" -type f \( -name "snell-server" -o -name "ssserver" -o -name "realm" \) | head -n 1)
    if [[ -z "$bin_in_archive" ]]; then rm -rf "$tmp_dir"; die "找不到程序文件"; fi

    mv -f "$bin_in_archive" "$bin_path"
    chmod +x "$bin_path"
    rm -rf "$tmp_dir"

    # Snell 无 --version，从下载 URL 提取版本号落盘（含 beta，供后续比对）
    if [[ "$service_name" == "snell" ]]; then
        local _v; _v=$(printf '%s' "$download_url" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?' | head -1 || true)
        [[ -n "$_v" ]] && printf '%s\n' "$_v" > "$SNELL_VERSION_FILE"
    fi

    msg_info "${service_name} 核心程序已安装。"
}

# 根据 CPU 架构选择最优加密算法
# x86_64 有 AES-NI 硬件指令，aes-128-gcm 更快；ARM 无 AES-NI，chacha20 软件实现更快
# 为已有 SS config.json 补全全局优化参数（存量机器迁移用）
# fast_open  : TCP Fast Open，减少握手 RTT（需 sysctl tcp_fastopen=3，iptables+rely.sh 已配置）
# no_delay   : TCP_NODELAY，消除 Nagle 缓冲延迟
# mode       : tcp_and_udp，同时开启 UDP 中继（DNS/游戏加速等）
# timeout    : 连接空闲超时 300s，防止僵尸连接耗尽资源
# udp_timeout: UDP 关联超时 60s
install_realm() {
    if [[ "$SS_ARCH" == "unsupported" ]]; then die "不支持架构"; fi
    local arch="$SS_ARCH"

    local latest_tag
    latest_tag=$(get_latest_github_release "zhboner/realm" "v2.7.0")
    local arch_name=""
    case "$arch" in
        amd64) arch_name="x86_64-unknown-linux-gnu" ;;
        aarch64) arch_name="aarch64-unknown-linux-gnu" ;; 
        armv7l) arch_name="armv7-unknown-linux-gnueabihf" ;;
        *) die "不支持 Realm 的当前架构: $arch" ;;
    esac

    local url="https://github.com/zhboner/realm/releases/download/${latest_tag}/realm-${arch_name}.tar.gz"
    
    install_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$url" "tar" || return

    # 初始化空配置
    # network 块仅使用 realm 实际支持的键（未知键 realm 会静默忽略，不会报错也不会生效）：
    # tcp_timeout 5         : 连接落地的握手超时 5s，落地失效时快速放弃而非长时间挂起
    # tcp_keepalive 15      : keepalive 探测间隔 15s，及时发现并回收已死的落地连接
    # tcp_keepalive_probe 3 : 连续 3 次探测无响应即判定断开
    # （realm 默认即开启 TCP_NODELAY 与 splice 零拷贝，无需也无法在配置里显式声明）
    # dns.cache_size 512    : 缓存远端 DNS，避免每条连接重复解析（50+ 节点必要）
    # dns.min/max_ttl       : 60-3600s 缓存窗口，max_ttl 1h 避免50+节点高频DNS重解析
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        cat > "$REALM_CONFIG_FILE" <<'REALM_INIT_EOF'
{
  "log": {"level": "warn"},
  "dns": {
    "mode": "ipv4_then_ipv6",
    "min_ttl": 60,
    "max_ttl": 3600,
    "cache_size": 512
  },
  "network": {
    "tcp_timeout": 5,
    "tcp_keepalive": 15,
    "tcp_keepalive_probe": 3
  },
  "endpoints": []
}
REALM_INIT_EOF
        chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
        chmod 600 "$REALM_CONFIG_FILE"
    fi

    # 初始化元数据文件
    if [[ ! -f "$REALM_META_FILE" ]]; then
        echo '{}' > "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    fi

    create_realm_service_file
    
    systemctl daemon-reload
    manage_services "enable" "realm"
    manage_services "start" "realm"
    msg_success "Realm 安装完成。"

    # 安装后引导
    printf "\n${C_CYAN}是否立即添加转发规则?${C_RESET}\n"
    printf "   1) 智能粘贴 Snell 配置 (默认)\n"
    printf "   2) 手动输入 IP:Port\n"
    printf "   0) 暂不添加\n"
    printf "${C_PURPLE}请选择 [1]: ${C_RESET}"
    read -r guide_choice
    guide_choice=${guide_choice:-1}
    
    case $guide_choice in
        1) add_realm_forward_advanced "auto" ;;
        2) add_realm_forward "auto" ;;
        *) msg_info "已跳过配置，后续可在主菜单中管理。" ;;
    esac
}

uninstall_service() {
    local service_name=$1
    local user=$2
    local bin_path=$3
    local config_dir=$4
    local service_file_path=$5
    local config_file=$6

    printf "${C_RED}确认彻底卸载 %s 吗? [y/N]: ${C_RESET}" "$service_name"
    read -r answer
    if [[ "${answer,,}" != "y" ]]; then return; fi

    msg_step "正在卸载 ${service_name}..."
    if [[ "$service_name" == "snell" ]]; then
        # 停止并关闭所有 snell@ 实例
        local _sf _sp
        while IFS= read -r _sf; do
            _sp=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
            if [[ -n "$_sp" ]]; then
                systemctl stop    "snell@${_sp}.service" &>/dev/null || true
                systemctl disable "snell@${_sp}.service" &>/dev/null || true
                close_firewall_port "$_sp"
            fi
        done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null)
    else
        systemctl stop    "${service_name}.service" &>/dev/null || true
        systemctl disable "${service_name}.service" &>/dev/null || true
    fi

    if [[ "$service_name" != "snell" ]] && [[ -f "$config_file" ]]; then
        if [[ "$service_name" == "realm" ]]; then
            local ports
            ports=$(jq -r '.endpoints[]?.listen' "$config_file" 2>/dev/null | cut -d: -f2 || true)
            for p in $ports; do [[ -n "$p" ]] && close_firewall_port "$p"; done
        fi
    fi

    rm -f "$bin_path" "$service_file_path"
    rm -rf "$config_dir"
    if id "$user" &>/dev/null; then userdel "$user" &>/dev/null || true; fi
    systemctl daemon-reload
    msg_success "${service_name} 已成功卸载。"
}


# ------------------------------------------------------------------------------
# 防火墙管理
# ------------------------------------------------------------------------------


parse_snell_nodes() {
    local f port psk
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        port=$(awk '/^\[snell-server\]/{in_s=1} in_s&&/^listen/{n=split($NF,a,":");print a[n];exit}' "$f" 2>/dev/null || true)
        psk=$(awk '/^\[snell-server\]/{in_s=1} in_s&&/^psk[[:space:]]*=/{sub(/^psk[[:space:]]*=[[:space:]]*/,""); print; exit}' "$f" 2>/dev/null || true)
        [[ -n "$port" && -n "$psk" ]] && echo "$port $psk"
    done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
}

get_connection_stats() {
    local total_connections=0
    local connection_details=()
    
    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f -print -quit 2>/dev/null | grep -q . && \
       systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -q .; then
        while IFS=' ' read -r s_port _; do
            [[ -z "$s_port" ]] && continue
            local snell_conns
            snell_conns=$(ss -tn state established "sport = :$s_port" 2>/dev/null | wc -l)
            snell_conns=$((snell_conns - 1))
            [[ $snell_conns -lt 0 ]] && snell_conns=0
            if [[ $snell_conns -gt 0 ]]; then
                connection_details+=("Snell(${s_port}): ${snell_conns}")
                total_connections=$((total_connections + snell_conns))
            fi
        done < <(parse_snell_nodes)
    fi
    
    if [[ -x "$SBX_BIN" ]] && systemctl is-active --quiet "$SBX_SVC"; then
        local _sbef _sbproto _sblabel _sbport _sbconns
        for _sbef in "$SBX_ST"/ss-*.env "$SBX_ST"/socks-*.env; do
            [[ -e "$_sbef" ]] || continue
            _sbport=$(basename "$_sbef"); _sbproto=${_sbport%%-*}; _sbport=${_sbport#*-}; _sbport=${_sbport%.env}
            [[ "$_sbproto" == ss ]] && _sblabel="SS" || _sblabel="SOCKS5"
            _sbconns=$(ss -tn state established "sport = :$_sbport" 2>/dev/null | wc -l)
            _sbconns=$((_sbconns - 1))
            [[ $_sbconns -lt 0 ]] && _sbconns=0
            if [[ $_sbconns -gt 0 ]]; then
                connection_details+=("${_sblabel}(${_sbport}): ${_sbconns}")
                total_connections=$((total_connections + _sbconns))
            fi
        done
    fi

    if [[ -f "$REALM_CONFIG_FILE" ]] && systemctl is-active --quiet realm.service; then
        local realm_ports
        realm_ports=$(jq -r '.endpoints[]?.listen' "$REALM_CONFIG_FILE" 2>/dev/null | cut -d: -f2 || true)
        for port in $realm_ports; do
            if [[ -n "$port" ]]; then
                local realm_conns
                realm_conns=$(ss -tn state established "sport = :$port" 2>/dev/null | wc -l)
                realm_conns=$((realm_conns - 1))
                [[ $realm_conns -lt 0 ]] && realm_conns=0
                if [[ $realm_conns -gt 0 ]]; then
                    connection_details+=("Realm(${port}): ${realm_conns}")
                    total_connections=$((total_connections + realm_conns))
                fi
            fi
        done
    fi
    echo "$total_connections:${connection_details[*]}"
}

show_detailed_connections() {
    clear
    printf "${C_CYAN}=== 用户连接详情 (实时) ===${C_RESET}\n\n"
    
    if ! command -v ss &>/dev/null; then
        msg_error "系统中未找到 'ss' 命令，无法查看。"
    else
        echo "正在获取连接信息..."
        echo "------------------------------------------------------------------"
        # 直接输出所有 established 连接（ss 本身会带表头一行）
        ss -tn state established
        echo "------------------------------------------------------------------"
        printf "${C_GREEN}提示: 上方显示的是当前所有已建立的 TCP 连接。${C_RESET}\n"
    fi

    printf "\n${C_CYAN}按任意键返回主菜单...${C_RESET}"
    read -rsn1
}


# ------------------------------------------------------------------------------
# ACL 管理功能 (核心新增)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# CN IP 封禁功能 (SS 专用)
# ------------------------------------------------------------------------------

ensure_ipset_exists() {
    local set_name="ss_cn_block"
    if ! command -v ipset &>/dev/null; then msg_error "未安装 ipset 组件。"; return 1; fi
    
    if ! ipset list "$set_name" &>/dev/null; then
        msg_step "正在初始化 CN IP 数据库 (ipset)..."
        ipset create "$set_name" hash:net
        
        local cn_list_url="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
        local temp_list
        temp_list=$(mktemp)
        
        msg_info "正在下载最新 CN IP 列表..."
        if wget -qO "$temp_list" "$cn_list_url" && [[ -s "$temp_list" ]]; then
             msg_info "正在导入 IP 规则 (约 8000+ 条)..."
             grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$temp_list" \
                 | sed "s/^/add $set_name /" | ipset restore -!
             rm -f "$temp_list"
             msg_success "CN IP 列表导入完成。"
        else
             msg_error "下载失败或文件为空，请检查网络连接。"
             rm -f "$temp_list"
             ipset destroy "$set_name"
             return 1
        fi
    fi
    return 0
}

_snell_manage_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== Snell 节点管理 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 添加 Snell 节点\n"
        printf " ${C_GREEN}2.${C_RESET} 删除 Snell 节点\n"
        printf " ${C_GREEN}3.${C_RESET} 编辑配置文件\n"
        printf " ${C_GREEN}4.${C_RESET} 查看连接详情\n"
        printf " ${C_GREEN}5.${C_RESET} 重新安装 (保留配置)\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n\n"
        printf "${C_PURPLE}请选择: ${C_RESET}"
        read -r sub
        case "$sub" in
            1) add_snell_node            || true ;;
            2) delete_snell_node         || true ;;
            3) edit_config               || true ;;
            4) show_detailed_connections || true ;;
            5) manage_services "stop" "snell" || true
               rm -f "$SNELL_BIN"
               local _sv="${SNELL_VERSION_OVERRIDE}"
               local _url="https://dl.nssurge.com/snell/snell-server-${_sv}-linux-${SNELL_ARCH}.zip"
               if install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$_url" "zip"; then
                   create_snell_template_service
                   systemctl daemon-reload
                   manage_services "start" "snell" || true
                   msg_success "Snell 重新安装完成，已重启所有节点"
               fi ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}

manage_realm_menu() {
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then msg_error "Realm 未安装或配置文件缺失。"; return; fi
    
    while true; do
        clear
        printf "${C_CYAN}=== Realm 端口转发管理 ===${C_RESET}\n\n"
        printf "${C_BLUE}当前规则列表:${C_RESET}\n"
        if jq -e '.endpoints | length > 0' "$REALM_CONFIG_FILE" >/dev/null; then
            jq -r '.endpoints[] | "  [本地端口: \(.listen | split(":")[-1])] -> [远程: \(.remote)]"' "$REALM_CONFIG_FILE"
        else
            printf "  (暂无转发规则)\n"
        fi
        
        printf "\n"
        printf "   1) 智能粘贴 Snell 配置 (自动解析添加)\n"
        printf "   2) 手动添加转发规则 (IP:Port)\n"
        printf "   3) 删除转发规则\n"
        printf "   4) 编辑配置文件 (Snell/SS/Realm)\n"
        printf "   5) 查看连接详情 (实时)\n"
        printf "   6) 重新安装 (保留配置)\n"
        printf "   0) 返回主菜单\n\n"
        printf "${C_CYAN}请选择: ${C_RESET}"
        read -r choice

        case $choice in
            1) add_realm_forward_advanced ;;
            2) add_realm_forward ;;
            3) delete_realm_forward ;;
            4) edit_config ;;
            5) show_detailed_connections ;;
            6) manage_services "stop" "realm" || true
               rm -f "$REALM_BIN"
               install_realm || true ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
    done
}

# 检测失效的 Realm 转发规则并批量删除
check_realm_dead_forwards() {
    local _dead_strict_was_on=false
    [[ $- == *e* ]] && _dead_strict_was_on=true
    set +e
    set +o pipefail
    # shellcheck disable=SC2064
    trap '{ [[ $_dead_strict_was_on == true ]] && set -eo pipefail; }; trap - RETURN' RETURN

    clear
    printf "${C_CYAN}=== 检测失效的 Realm 转发规则 ===${C_RESET}\n"
    printf "${C_YELLOW}将对每条转发规则的远端目标进行 TCP 连通性检测（连探 3 次全失败才判失效，抗瞬时抖动）。${C_RESET}\n\n"

    local total
    total=$(jq '.endpoints | length' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
    if [[ $total -eq 0 ]]; then
        msg_info "暂无转发规则。"
        printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1
        return
    fi

    # 开始检测
    local dead_indices=()   # 失效的 JSON 索引
    local dead_info=()      # 失效的显示信息
    local i=0

    while IFS= read -r line; do
        local listen remote
        listen=$(echo "$line" | jq -r '.listen')
        remote=$(echo "$line" | jq -r '.remote')
        local l_port r_host r_port alias
        l_port=$(echo "$listen" | cut -d: -f2)
        r_host=$(echo "$remote" | cut -d: -f1)
        r_port=$(echo "$remote" | cut -d: -f2)
        alias=""
        [[ -f "$REALM_META_FILE" ]] && alias=$(jq -r --arg p "$l_port" '.[$p].alias // empty' "$REALM_META_FILE" 2>/dev/null || true)
        [[ -z "$alias" ]] && alias="${l_port} → ${r_host}:${r_port}"

        printf "  [%2d/%2d] 检测: %-30s -> %s:%s " "$((i+1))" "$total" "$alias" "$r_host" "$r_port"

        # TCP 连接测试：nc 优先，socat 兜底。
        # 连续探测 3 次(失败间隔 1s)，任一成功即判可达 —— 避免链路瞬时抖动把好落地误判为"失效"。
        local reachable=false _try
        for _try in 1 2 3; do
            if command -v nc &>/dev/null; then
                nc -z -w 4 "$r_host" "$r_port" 2>/dev/null && { reachable=true; break; }
            else
                socat /dev/null "TCP4:${r_host}:${r_port},connect-timeout=4" 2>/dev/null && { reachable=true; break; }
            fi
            [[ $_try -lt 3 ]] && sleep 1
        done

        if $reachable; then
            printf "${C_GREEN}[正常]${C_RESET}\n"
        else
            printf "${C_RED}[失效]${C_RESET}\n"
            dead_indices+=("$i")
            dead_info+=("  本地:${l_port} -> 远端:${r_host}:${r_port}  (${alias})")
        fi

        ((i++)) || true
    done < <(jq -c '.endpoints[]' "$REALM_CONFIG_FILE" 2>/dev/null)

    printf "\n"

    if [[ ${#dead_indices[@]} -eq 0 ]]; then
        msg_success "所有转发规则连採正常，无需清理。"
        return
    fi

    # 展示失效列表让用户确认
    printf "${C_RED}以下 ${#dead_indices[@]} 条规则检测失效:${C_RESET}\n"
    for info in "${dead_info[@]}"; do
        printf "${C_RED}%s${C_RESET}\n" "$info"
    done

    printf "\n${C_YELLOW}确认删除以上 ${#dead_indices[@]} 条失效规则？ [y/N]: ${C_RESET}"
    read -r confirm
    if [[ "${confirm,,}" != "y" ]]; then
        msg_info "已取消，未做任何修改。"
        return
    fi

    # 从后向前删除，避免索引偏移
    local sorted_indices=()
    mapfile -t sorted_indices < <(printf '%s\n' "${dead_indices[@]}" | sort -rn)

    for idx in "${sorted_indices[@]}"; do
        local del_listen del_port
        del_listen=$(jq -r ".endpoints[$idx].listen" "$REALM_CONFIG_FILE")
        del_port=$(echo "$del_listen" | cut -d: -f2)

        # 删除 JSON 并关闭防火墙端口
        local tmp_json
        tmp_json=$(mktemp)
        jq "del(.endpoints[$idx])" "$REALM_CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$REALM_CONFIG_FILE" || rm -f "$tmp_json"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"

        [[ -f "$REALM_META_FILE" ]] && {
            local meta_tmp
            meta_tmp=$(mktemp)
            jq --arg p "$del_port" 'del(.[$p])' "$REALM_META_FILE" > "$meta_tmp" && mv "$meta_tmp" "$REALM_META_FILE" || rm -f "$meta_tmp"
            chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        }

        close_firewall_port "$del_port" 2>/dev/null || true
    done

    msg_success "已删除 ${#dead_indices[@]} 条失效规则。"
    _realm_restart_hint

}

# 改完规则后的提示。走 msg + log_message 而非 msg_warn：要红字醒目，但日志里不能混进
# 颜色转义码（log_message 原样落盘）。
_realm_restart_hint() {
    local _m="配置已更新，需重启 Realm 才生效 —— 主菜单 [11] 重启 Realm（会断开现有连接，可挑时机）"
    msg "${C_RED}[警告] ${_m}${C_RESET}"
    log_message "WARN" "$_m"
}

# 配置文件是否比 realm 进程更新 —— 即改了规则却还没重启，转发仍按旧配置跑。
# 比对 mtime 与服务启动时间，不落状态文件：重启后自动不再成立，无残留可言。
# realm 不支持热重载（2.9.4 无 reload，上游亦无此机制），只能靠提醒兜住"改完忘重启"。
_realm_config_stale() {
    [[ -f "$REALM_CONFIG_FILE" ]] || return 1
    systemctl is-active --quiet realm 2>/dev/null || return 1
    local _cfg _svc _ts
    _cfg=$(stat -c %Y "$REALM_CONFIG_FILE" 2>/dev/null) || return 1
    _ts=$(systemctl show realm -p ActiveEnterTimestamp --value 2>/dev/null)
    [[ -n "$_ts" ]] || return 1
    _svc=$(date -d "$_ts" +%s 2>/dev/null) || return 1
    [[ -n "$_svc" && "$_cfg" -gt "$_svc" ]]
}

_realm_safe_restart() {
    if ! validate_realm_config "$REALM_CONFIG_FILE"; then
        msg_error "Realm 配置文件格式错误，已中止重启，请检查: $REALM_CONFIG_FILE"
        return 1
    fi
    local _bak="${REALM_CONFIG_FILE}.bak"
    cp "$REALM_CONFIG_FILE" "$_bak" 2>/dev/null || true
    if ! manage_services "restart" "realm"; then
        msg_warn "Realm 重启失败，正在回滚配置..."
        if [[ -f "$_bak" ]]; then
            mv "$_bak" "$REALM_CONFIG_FILE"
            chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
            chmod 600 "$REALM_CONFIG_FILE"
            manage_services "restart" "realm" || true
        fi
        msg_error "已回滚，请检查日志: journalctl -u realm"
        return 1
    fi
    rm -f "$_bak"
}

_process_realm_rule() {
    # 临时禁用严格模式，防止因解析错误导致脚本退出；RETURN 时自动恢复
    local _strict_was_on=false
    [[ $- == *e* ]] && _strict_was_on=true
    set +e
    set +o pipefail
    trap '{ [[ $_strict_was_on == true ]] && set -eo pipefail; }; trap - RETURN' RETURN

    local raw_config="$1"
    local silent_mode="${2:-false}" # true to suppress some success messages during batch

    # 提取信息：支持两类输入
    #   (A) 分享链接 URL(ss:// / hysteria2:// / hy2:// / vless:// / trojan:// / tuic://) → 取 @主机:端口(+#别名)
    #   (B) Surge Snell 配置行(name = snell, host, port, psk=..., listening=...)
    # Realm 只转发 TCP、协议对其透明，非 Snell 节点(SS/Hy2 等)只需拿到远端 host:port 即可。
    local remote_host="" remote_port="" psk="" manual_listening_port="" node_alias="" _escaped_host
    if [[ "$raw_config" =~ ^(ss|ssr|vless|vmess|trojan|hysteria2|hy2|tuic)://[^[:space:]]*@ ]]; then
        # URL 分支：删 scheme → 删 userinfo(贪婪到最后一个@) → 截到 / ? # 之前 = 纯 host:port
        local _hostport
        _hostport=$(printf '%s' "$raw_config" | sed -E 's|^[A-Za-z0-9]+://||; s|^.*@||; s|[/?#].*$||')
        remote_host=$(printf '%s' "$_hostport" | sed -E 's|:[0-9]+$||; s|^\[||; s|\]$||')
        remote_port=$(printf '%s' "$_hostport" | grep -oE '[0-9]+$' || true)
        node_alias=$(printf '%s' "$raw_config" | grep -oP '#\K.+$' | head -1 || true)
        # 别名含 %XX 时做 URL 解码，保留 emoji/中文
        [[ "$node_alias" == *%* ]] && node_alias=$(printf '%b' "${node_alias//%/\\x}" 2>/dev/null || printf '%s' "$node_alias")
    else
        # Surge Snell 配置行分支
        remote_host=$(echo "$raw_config" | grep -oP 'snell,\s*\K\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' | head -n 1 || true)
        if [[ -z "$remote_host" ]]; then
            remote_host=$(echo "$raw_config" | grep -oP 'snell,\s*\K[a-zA-Z0-9][-a-zA-Z0-9.]{0,253}' | head -n 1 || true)
        fi
        # 精准匹配 IP 之后紧跟的端口，避免误取 IP 第一段
        if [[ ! "$remote_host" =~ ^[0-9a-zA-Z._-]+$ ]]; then
            msg_warn "远端主机格式异常，跳过端口解析: $remote_host"
            return 1
        fi
        _escaped_host=$(echo "$remote_host" | sed 's/\./\\./g; s/\[/\\[/g; s/\]/\\]/g; s/+/\\+/g')
        remote_port=$(echo "$raw_config" | grep -oP "${_escaped_host},\s*\K\d+" | head -1 || true)
        psk=$(echo "$raw_config" | grep -oP 'psk=["'\'']?\K[^,"'\'']+' | head -n 1 || true)
        manual_listening_port=$(echo "$raw_config" | grep -oP 'listening=\K\d+' | head -n 1 || true)
        node_alias=$(echo "$raw_config" | grep -oP '^[^=]+(?=\s*=)' | xargs || true)
    fi
    
    local remote_ip=""
    
    if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        remote_ip="$remote_host"
    elif [[ -n "$remote_host" ]]; then
        remote_ip=$(getent hosts "$remote_host" 2>/dev/null | awk 'NR==1 {print $1}' || true)
        if [[ -z "$remote_ip" ]]; then
             remote_ip=$(dig +short "$remote_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
        fi
        if [[ -z "$remote_ip" ]]; then
             remote_ip=$(nslookup "$remote_host" 2>/dev/null | awk '/^Address: / {print $2}' | head -1 || true)
        fi
        if [[ -z "$remote_ip" ]] || [[ "$remote_ip" == "0.0.0.0" ]]; then
            if [[ "$silent_mode" == "false" ]]; then msg_error "无法解析主机名 '$remote_host'，请检查 DNS 或输入 IP 地址"; fi
            return 1
        fi
    fi

    if [[ -z "$remote_ip" || -z "$remote_port" ]]; then
        if [[ "$silent_mode" == "false" ]]; then msg_error "无法解析: $raw_config"; fi
        return 1
    fi
    
    local remote_addr="${remote_host}:${remote_port}"

    # 防止重复添加同一远端地址
    if jq -e --arg r "$remote_addr" '.endpoints[] | select(.remote == $r)' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        if [[ "$silent_mode" == "false" ]]; then msg_warn "该远端地址已存在转发规则: ${remote_addr}，跳过。"; fi
        return 1
    fi

    local local_port

    # === 端口分配逻辑 ===
    # 如果配置行里指定了 listening 端口 (且该端口确实可用)，则优先复用
    if [[ -n "$manual_listening_port" ]] && ! (ss -tln | grep -q ":${manual_listening_port} " || ss -uln | grep -q ":${manual_listening_port} "); then
         # 双重检查: 确保 config 文件里也没占用 (防止重复添加导致 JSON 冲突)
         if ! jq -e --argjson p "$manual_listening_port" '.endpoints[] | select(.listen | endswith(":" + ($p|tostring)))' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
             local_port="$manual_listening_port"
         else
             # 端口已被本配置文件占用，回退到随机
             local_port=$(get_available_port)
         fi
    else
         # 未指定或端口已占用，回退到随机
         local_port=$(get_available_port)
    fi
    
    local listen_addr="0.0.0.0:$local_port"

    # 1. 准备 config.json 临时文件（暂不提交）
    local temp_json
    temp_json=$(mktemp)
    if ! jq --arg l "$listen_addr" --arg r "$remote_addr" \
       '.endpoints += [{"listen": $l, "remote": $r}]' \
       "$REALM_CONFIG_FILE" > "$temp_json" || ! jq -e . "$temp_json" >/dev/null 2>&1; then
        rm -f "$temp_json"; msg_error "生成配置 JSON 失败，已中止。"; return 1
    fi

    # Smart Naming Logic
    local new_name=""
    local remote_country_code="UN"
    local flag=""

    if [[ -n "$node_alias" && -n "$manual_listening_port" ]]; then
         # 恢复模式: 保持原名，仅查询国旗用于元数据
         new_name="$node_alias"
         remote_country_code=$(get_country_code_for_ip "$remote_ip" || echo "UN")
         flag=$(get_flag_emoji "$remote_country_code")
    else
        # 新增模式: 走完整的智能命名逻辑
        remote_country_code=$(get_country_code_for_ip "$remote_ip" || echo "UN")
        flag=$(get_flag_emoji "$remote_country_code")
        local clean_alias
        clean_alias=$(echo "$node_alias" | tr -d '"' | sed 's/->/ → /g' | sed -E 's/\[\.([0-9]+)\]/_\1/g' | sed -E 's/\[[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)\]/_\1/g')

        local local_d
        local_d=$(echo "$SERVER_IP" | cut -d. -f4)
        local local_c
        local_c=$(echo "$SERVER_IP" | cut -d. -f3)
        local local_suffix="_${local_d}"
        local remote_d
        remote_d=$(echo "$remote_ip" | cut -d. -f4)
        local remote_suffix="_${remote_d}"
        local local_iso="${SERVER_COUNTRY_CODE}"
        local current_tag="${local_iso}${local_suffix}"

        # 智能判重与命名生成
        if [[ "$clean_alias" == *"${current_tag}" ]]; then
             new_name="$clean_alias"
        elif [[ "$clean_alias" == *" → "* ]]; then
             if [[ "$clean_alias" == *"_${local_d}" ]]; then local_suffix="_${local_c}.${local_d}"; fi
             local current_tag_c="${local_iso}${local_suffix}"
             if [[ "$clean_alias" == *"${current_tag_c}" ]]; then
                 new_name="$clean_alias"
             else
                 new_name="${clean_alias} → ${current_tag_c}"
             fi
        else
             if [[ "$clean_alias" == *"_"* ]] && [[ "$clean_alias" != *" → "* ]]; then
                  if [[ "$clean_alias" == *"_${local_d}" ]]; then local_suffix="_${local_c}.${local_d}"; fi
                  new_name="${clean_alias} → ${local_iso}${local_suffix}"
             else
                  if [[ "$remote_d" == "$local_d" ]]; then local_suffix="_${local_c}.${local_d}"; fi
                  new_name="${flag}${remote_suffix} → ${local_iso}${local_suffix}"
             fi
        fi
    fi

    # 2. 准备 metadata 临时文件（暂不提交）
    if [[ ! -f "$REALM_META_FILE" ]]; then echo '{}' > "$REALM_META_FILE"; chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"; chmod 600 "$REALM_META_FILE"; fi
    local safe_alias
    safe_alias=$(echo "$new_name" | tr -d '"\\')
    local meta_final
    meta_final=$(mktemp)
    if ! jq --arg p "$local_port" \
            --arg psk "$psk" \
            --arg alias "$safe_alias" \
            --arg cc "$remote_country_code" \
       '. + {($p): {"psk": $psk, "alias": $alias, "country_code": $cc}}' \
       "$REALM_META_FILE" > "$meta_final"; then
        rm -f "$temp_json" "$meta_final"; return 1
    fi

    # 3. 两个文件都就绪后一次性提交，保证原子性
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"
    mv "$meta_final" "$REALM_META_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
    chmod 600 "$REALM_META_FILE"

    open_firewall_port "$local_port" || msg_warn "防火墙端口 $local_port 放行失败，节点已添加但外部可能不可达，请手动检查 iptables。"

    if [[ "$silent_mode" == "false" ]]; then
        local display_prefix="$flag"
        if [[ "$new_name" == *" → "* ]]; then display_prefix=""; fi
        msg_success "添加成功: ${new_name} (Port $local_port)"
        if [[ -n "$psk" ]]; then
             printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" "$display_prefix" "$new_name" "$SERVER_IP" "$local_port" "$psk"
        fi
    else
        echo "   [OK] $new_name (Port: $local_port)"
    fi
    return 0
}

add_realm_forward_advanced() {
    local _restart_mode=${1:-"ask"}  # auto=直接重启（首次安装）  ask=询问（后期添加）
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        msg_error "Realm 未安装，请先从主菜单安装 Realm 转发服务。"
        return
    fi
    msg_step "智能添加转发规则（支持多行批量粘贴）"
    printf "${C_YELLOW}请粘贴落地机节点，支持多行/多协议：Snell 配置行 或 ss:// / hysteria2:// 等分享链接，粘贴完成后回车空行确认:${C_RESET}\n"

    local lines=() raw_config
    while IFS= read -r raw_config; do
        [[ -z "$raw_config" ]] && break
        lines+=("$raw_config")
    done

    if [[ ${#lines[@]} -eq 0 ]]; then msg_error "输入不能为空。"; return; fi

    local ok=0 fail=0
    local silent_mode="false"
    [[ ${#lines[@]} -gt 1 ]] && silent_mode="true"

    for raw_config in "${lines[@]}"; do
        if _process_realm_rule "$raw_config" "$silent_mode"; then
            (( ok++ )) || true
        else
            (( fail++ )) || true
        fi
    done

    [[ ${#lines[@]} -gt 1 ]] && printf "${C_CYAN}批量添加完成: ${C_GREEN}成功 %d${C_CYAN} / ${C_RED}失败 %d${C_RESET}\n" "$ok" "$fail"

    if [[ $ok -gt 0 ]]; then
        if [[ "$_restart_mode" == "auto" ]]; then
            _realm_safe_restart
        else
            _realm_restart_hint
        fi
    fi
}


add_realm_forward() {
    local _restart_mode=${1:-"ask"}  # auto=直接重启（首次安装）  ask=询问（后期添加）
    msg_step "添加 Realm 转发规则 (手动)"
    
    echo "请输入本地监听端口 (Local Port) [回车自动分配]:"
    local local_port input_port
    read -r input_port
    if [[ -z "$input_port" ]]; then
        local_port=$(get_available_port)
    elif [[ "$input_port" =~ ^[0-9]+$ ]] && [[ $input_port -ge 1 ]] && [[ $input_port -le 65535 ]]; then
        if ss -tln | grep -q ":${input_port} " || ss -uln | grep -q ":${input_port} "; then
            msg_error "端口 ${input_port} 已被占用，请选择其他端口。"
            return
        fi
        local_port=$input_port
    else
        msg_error "端口号无效，请输入 1-65535 之间的数字。"
        return
    fi
    
    printf "${C_CYAN}请输入目标地址 (格式 IP:Port, 例如 1.2.3.4:8080): ${C_RESET}"
    read -r remote_addr
    
    if [[ ! "$remote_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] && [[ ! "$remote_addr" =~ ^\[.*\]:[0-9]+$ ]] && [[ ! "$remote_addr" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
        msg_error "格式不正确，请确保为 IP:Port 格式。"
        return
    fi
    
    if jq -e --arg r "$remote_addr" '.endpoints[] | select(.remote == $r)' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        msg_warn "该远端地址已存在转发规则: ${remote_addr}，跳过。"
        return
    fi

    local listen_addr="0.0.0.0:$local_port"
    local temp_json
    temp_json=$(mktemp)

    # 构建新对象并追加
    jq --arg l "$listen_addr" --arg r "$remote_addr" \
       '.endpoints += [{"listen": $l, "remote": $r}]' \
       "$REALM_CONFIG_FILE" > "$temp_json"
       
    if ! jq -e . "$temp_json" >/dev/null; then
        msg_error "更新配置失败 (JSON 错误)。"
        rm -f "$temp_json"
        return
    fi
    
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"

    # 同步写入 metadata（别名使用 remote_addr，psk 留空）
    if [[ ! -f "$REALM_META_FILE" ]]; then
        echo '{}' > "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    fi
    local _meta_tmp
    _meta_tmp=$(mktemp)
    if jq --arg p "$local_port" --arg alias "$remote_addr" \
       '. + {($p): {"psk": "", "alias": $alias, "country_code": "UN"}}' \
       "$REALM_META_FILE" > "$_meta_tmp"; then
        mv "$_meta_tmp" "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    else
        rm -f "$_meta_tmp"
    fi

    open_firewall_port "$local_port" || msg_warn "防火墙端口 $local_port 放行失败，请手动检查 iptables。"
    msg_success "转发规则已添加: $local_port -> $remote_addr"
    if [[ "$_restart_mode" == "auto" ]]; then
        _realm_safe_restart
    else
        _realm_restart_hint
    fi
}

delete_realm_forward() {
    msg_step "删除 Realm 转发规则"

    local count
    count=$(jq '.endpoints | length' "$REALM_CONFIG_FILE")
    if [[ $count -eq 0 ]]; then msg_warn "没有规则可删除。"; return; fi

    echo "当前规则:"
    jq -r '.endpoints[] | "\(.listen | split(":")[1]) -> \(.remote)"' "$REALM_CONFIG_FILE" | cat -n

    printf "${C_CYAN}请输入要删除的本地端口号, 0 取消: ${C_RESET}"
    read -r deleted_port

    [[ "$deleted_port" == "0" ]] && return
    if [[ ! "$deleted_port" =~ ^[0-9]+$ ]]; then
        msg_error "无效端口号。"
        return
    fi

    # 按端口直接定位，避免序号与数组下标歧义
    if ! jq -e --arg p "$deleted_port" '.endpoints[] | select(.listen | endswith(":" + $p))' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        msg_error "未找到本地端口 $deleted_port 的转发规则。"
        return
    fi

    local temp_json
    temp_json=$(mktemp)
    if ! jq --arg p "$deleted_port" 'del(.endpoints[] | select(.listen | endswith(":" + $p)))' "$REALM_CONFIG_FILE" > "$temp_json"; then
        rm -f "$temp_json"; msg_error "删除规则失败 (jq 错误)。"; return
    fi
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"

    # 清理 metadata
    if [[ -f "$REALM_META_FILE" ]]; then
        local meta_temp
        meta_temp=$(mktemp)
        if jq --arg p "$deleted_port" 'del(.[$p])' "$REALM_META_FILE" > "$meta_temp"; then
            if ! mv "$meta_temp" "$REALM_META_FILE"; then
                msg_warn "metadata.json 更新失败，规则与元数据可能不同步"
                rm -f "$meta_temp"
            else
                chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
            fi
        else
            rm -f "$meta_temp"
        fi
    fi
    
    # 自动关闭防火墙端口
    close_firewall_port "$deleted_port"
    
    msg_success "规则已删除。"
    _realm_restart_hint
}


# ------------------------------------------------------------------------------
# Snell/SS 具体实现
# ------------------------------------------------------------------------------

# 返回 0=可用, 1=已占用（含系统监听端口和所有配置文件中声明的端口）
_check_port_available() {
    local port="$1"
    if ss -tln | grep -q ":${port} " || ss -uln | grep -q ":${port} "; then return 1; fi
    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f \
            -exec grep -ql ":${port}" {} \; 2>/dev/null | grep -q .; then return 1; fi
    if [[ -d "$SBX_ST" ]] && { [[ -e "$SBX_ST/ss-${port}.env" ]] || [[ -e "$SBX_ST/socks-${port}.env" ]] || [[ -e "$SBX_ST/hy2-${port}.env" ]]; }; then return 1; fi
    if [[ -f "$REALM_CONFIG_FILE" ]] && \
            jq -e --argjson p "$port" \
            '.endpoints[] | select(.listen | endswith(":" + ($p|tostring)))' \
            "$REALM_CONFIG_FILE" >/dev/null 2>&1; then return 1; fi
    return 0
}

get_available_port() {
    local port
    local attempts=0
    while [[ $attempts -lt 100 ]]; do
        if command -v shuf >/dev/null 2>&1; then
            port=$(shuf -i "${RAND_PORT_MIN}-${RAND_PORT_MAX}" -n 1)
        else
            # RANDOM 范围是 0-32767，两次组合扩展到 0-1073741823 再取模覆盖完整端口段
            port=$(( (RANDOM * 32768 + RANDOM) % (RAND_PORT_MAX - RAND_PORT_MIN + 1) + RAND_PORT_MIN ))
        fi
        if _check_port_available "$port"; then
            echo "$port"
            return 0
        fi
        attempts=$(( attempts + 1 ))
    done
    die "无法找到可用端口。"
}

get_port_interactive() {
    printf "${C_YELLOW}是否手动指定端口? (默认自动分配，亦可直接输入端口号) [y/N/Port]: ${C_RESET}" >&2
    read -r input

    # 尝试直接识别为端口号 (处理用户直接输入端口的情况)
    if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le 65535 ]]; then
        if ! _check_port_available "$input"; then
            msg_error "端口 ${input} 已被占用，将自动分配可用端口。" >&2
            get_available_port
            return 0
        fi
        echo "$input"
        return 0
    fi

    # 识别 yes/y
    if [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]; then
        while true; do
            printf "${C_CYAN}请输入端口号 (1-65535): ${C_RESET}" >&2
            read -r manual_port
            if [[ "$manual_port" =~ ^[0-9]+$ ]] && [[ "$manual_port" -ge 1 && "$manual_port" -le 65535 ]]; then
                if ! _check_port_available "$manual_port"; then
                    msg_error "端口 ${manual_port} 已被占用，请重新输入。" >&2
                    continue
                fi
                echo "$manual_port"
                return 0
            else
                msg_error "无效的端口号。"
            fi
        done
    else
        get_available_port
    fi
}

create_realm_service_file() {
    cat > "$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${REALM_USER}
Group=${REALM_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="${REALM_BIN}" -c "${REALM_CONFIG_FILE}"
Restart=always
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=262144
LimitNPROC=262144
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

create_service_file() {
    local service_file_path=$1
    local user=$2
    local bin_path=$3
    local config_file=$4
    local description=$5
    local nofile_limit="${6:-51200}"
    cat > "$service_file_path" <<EOF
[Unit]
Description=$description
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$user
Group=$user
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="$bin_path" -c "$config_file"
Restart=on-failure
RestartSec=2
LimitNOFILE=${nofile_limit}
LimitNPROC=${nofile_limit}
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

install_snell() {
    if [[ "$SNELL_ARCH" == "unsupported" ]]; then die "不支持架构"; fi

    local snell_version="${SNELL_VERSION_OVERRIDE}"
    local snell_download_url="https://dl.nssurge.com/snell/snell-server-${snell_version}-linux-${SNELL_ARCH}.zip"

    install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$snell_download_url" "zip" || return

    # 创建/更新模板服务文件
    create_snell_template_service
    systemctl daemon-reload

    msg_step "生成首个 Snell 节点配置..."
    local port
    port=$(get_port_interactive)
    local psk
    psk=$(openssl rand -base64 32)
    local node_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    cat > "$node_conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
    chown -R "${SNELL_USER}:${SNELL_USER}" "$SNELL_CONFIG_DIR"
    chmod 600 "$node_conf"

    systemctl daemon-reload
    systemctl enable "snell@${port}.service" 2>/dev/null || msg_warn "snell@${port} enable 失败，重启后不会自启。"
    systemctl start  "snell@${port}.service" || msg_warn "启动 snell@${port} 失败，请检查: journalctl -u snell@${port}.service"
    open_firewall_port "$port"
    msg_success "Snell 安装完成，端口: ${port}"
}

add_snell_node() {
    if [[ ! -f "$SNELL_BIN" ]]; then msg_error "Snell 未安装，请先安装。"; return; fi
    msg_step "添加新 Snell 节点..."
    local port
    port=$(get_port_interactive)
    local psk
    psk=$(openssl rand -base64 32)
    local node_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    cat > "$node_conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
    chown "${SNELL_USER}:${SNELL_USER}" "$node_conf"
    chmod 600 "$node_conf"
    systemctl daemon-reload
    systemctl enable "snell@${port}.service" 2>/dev/null || msg_warn "snell@${port} enable 失败，重启后不会自启。"
    systemctl start  "snell@${port}.service" || msg_warn "启动 snell@${port} 失败，请检查: journalctl -u snell@${port}.service"
    open_firewall_port "$port"
    msg_success "Snell 节点已添加，端口: ${port}"
}

delete_snell_node() {
    local configs=()
    mapfile -t configs < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
    local count=${#configs[@]}

    if [[ $count -eq 0 ]]; then
        msg_error "没有找到 Snell 节点配置。"
        return
    fi
    if [[ $count -eq 1 ]]; then
        msg_warn "当前只有一个节点，如需移除请卸载 Snell 服务（选项 17）。"
        return
    fi

    printf "${C_CYAN}当前 Snell 节点:${C_RESET}\n"
    local ports=()
    local i=1
    for f in "${configs[@]}"; do
        local p
        p=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$f" 2>/dev/null | head -1 || true)
        ports+=("$p")
        printf "  ${C_GREEN}%d.${C_RESET} 端口 %s\n" "$i" "$p"
        i=$((i + 1))
    done

    printf "\n${C_YELLOW}请输入要删除的节点编号 (0=取消): ${C_RESET}"
    read -r choice

    [[ "$choice" == "0" || -z "$choice" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt $count ]]; then
        msg_error "无效选项。"
        return
    fi

    local target_port="${ports[$((choice - 1))]}"
    local target_conf="${SNELL_CONFIG_DIR}/snell-${target_port}.conf"

    systemctl stop    "snell@${target_port}.service" &>/dev/null || true
    systemctl disable "snell@${target_port}.service" &>/dev/null || true
    rm -f "$target_conf"
    close_firewall_port "$target_port"
    msg_success "Snell 节点已删除，端口: ${target_port}"
}

# ------------------------------------------------------------------------------
# 主菜单与交互
# ------------------------------------------------------------------------------

manage_services() {
    local action=$1
    local service_param=$2
    case "${action}" in
        start|stop|restart|reload|enable|disable|status) ;;
        *) msg_warn "无效的操作: ${action}"; return 1 ;;
    esac
    case "${service_param}" in
        all|snell|sing-box|realm) ;;
        *) msg_warn "无效的服务名: ${service_param}"; return 1 ;;
    esac
    local services_to_manage=()
    if [[ "$service_param" == "all" || "$service_param" == "snell" ]]; then services_to_manage+=("snell"); fi
    if [[ "$service_param" == "all" || "$service_param" == "sing-box" ]]; then services_to_manage+=("sing-box"); fi
    if [[ "$service_param" == "all" || "$service_param" == "realm" ]]; then services_to_manage+=("realm"); fi

    for service in "${services_to_manage[@]}"; do
        # Snell 使用模板服务，对所有节点实例逐一操作
        if [[ "$service" == "snell" ]]; then
            local _snell_insts=()
            local _sf _sp
            while IFS= read -r _sf; do
                _sp=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
                [[ -n "$_sp" ]] && _snell_insts+=("snell@${_sp}.service")
            done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)

            if [[ ${#_snell_insts[@]} -eq 0 ]]; then
                msg_warn "未找到 Snell 节点配置，跳过。"
                continue
            fi
            for _inst in "${_snell_insts[@]}"; do
                if [[ "$action" == "enable" ]]; then
                    if systemctl enable "$_inst" &>/dev/null; then
                        msg_info "已启用 ${_inst}。"
                    else
                        msg_warn "启用 ${_inst} 失败。"
                    fi
                else
                    msg_info "正在 ${action} ${_inst}..."
                    if ! systemctl "$action" "$_inst"; then
                        msg_warn "${action} ${_inst} 失败。"
                    else
                        msg_success "${_inst} 已成功 ${action}。"
                    fi
                fi
            done
            continue
        fi

        if [[ "$action" == "enable" ]]; then
            if systemctl enable "${service}.service" &>/dev/null; then
                msg_info "已启用 ${service} 服务。"
            else
                msg_warn "启用 ${service} 服务失败。"
            fi
            continue
        fi
        msg_info "正在 ${action} ${service} 服务..."
        if ! systemctl "$action" "${service}.service"; then
            msg_warn "${action} ${service} 服务失败。"
        else
            msg_success "${service} 服务已成功 ${action}。"
        fi
    done
}

edit_config() {
    clear
    printf "${C_CYAN}=== 编辑配置文件 ===${C_RESET}\n"
    printf " ${C_GREEN}1.${C_RESET} 编辑 Snell 配置\n"
    printf " ${C_GREEN}2.${C_RESET} 编辑 sing-box 配置 (config.json，增删节点会重建)\n"
    printf " ${C_GREEN}3.${C_RESET} 编辑 Realm 转发配置\n"
    printf " ${C_GREEN}0.${C_RESET} 取消\n"
    printf "\n${C_PURPLE}请选择 [0-3]: ${C_RESET}"
    read -r edit_choice
    
    local target_file=""
    local service_name=""
    
    case $edit_choice in
        1)
            # 多实例：列出所有节点配置，让用户选择
            local _snell_confs=()
            mapfile -t _snell_confs < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
            if [[ ${#_snell_confs[@]} -eq 0 ]]; then
                msg_error "未找到 Snell 节点配置文件。"; return
            elif [[ ${#_snell_confs[@]} -eq 1 ]]; then
                target_file="${_snell_confs[0]}"
            else
                printf "${C_CYAN}请选择要编辑的节点:${C_RESET}\n"
                local _i=1
                for _cf in "${_snell_confs[@]}"; do
                    printf "  ${C_GREEN}%d.${C_RESET} %s\n" "$_i" "$(basename "$_cf")"
                    _i=$((_i+1))
                done
                printf "${C_PURPLE}>>> ${C_RESET}"
                read -r _sel
                if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#_snell_confs[@]} )); then
                    target_file="${_snell_confs[$((_sel-1))]}"
                else
                    msg_error "无效选择"; return
                fi
            fi
            service_name="snell"
            ;;
        2)
            target_file="$SBX_CONF"
            service_name="sing-box"
            ;;
        3)
            target_file="$REALM_CONFIG_FILE"
            service_name="realm"
            ;;
        0) return ;;
        *) msg_error "无效选项"; return ;;
    esac
    
    if [[ ! -f "$target_file" ]]; then
        msg_error "配置文件不存在: $target_file"
        return
    fi
    
    # Use nano or vim
    local editor
    if   command -v nano &>/dev/null; then editor="nano"
    elif command -v vim  &>/dev/null; then editor="vim"
    else editor="${VISUAL:-${EDITOR:-vi}}"
    fi
    
    "$editor" "$target_file"

    printf "${C_YELLOW}是否重启 %s 服务以应用修改? [Y/n]: ${C_RESET}" "$service_name"
    read -r restart_conf
    if [[ "${restart_conf,,}" != "n" ]]; then
        if [[ "$service_name" == "snell" ]]; then
            # 只重启修改的那个实例
            local _edit_port
            _edit_port=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$target_file" 2>/dev/null | head -1 || true)
            [[ -n "$_edit_port" ]] && systemctl restart "snell@${_edit_port}.service" || manage_services "restart" "snell"
        else
            manage_services "restart" "$service_name"
        fi
    fi

}

# $1=auto 时为非交互模式（systemd 定时器调用）：不提问、不 exec、日志走 stdout(journal)。
# 更新源固定 /releases/latest —— GitHub 只返回正式版，自动排除预发布，实现"预发布不自动更新"。
self_update() {
    local _mode="${1:-}" latest tmp_file self_path
    self_path=$(realpath "${BASH_SOURCE[0]}")

    [[ "$_mode" == auto ]] || msg_step "检查脚本更新..."
    latest=$(get_latest_github_release "$SELF_REPO") || return 1
    latest="${latest#v}"

    if [[ "$latest" == "$SCRIPT_VERSION" ]]; then
        [[ "$_mode" == auto ]] && echo "[auto-update] 已是最新 v${SCRIPT_VERSION}" \
                               || msg_success "已是最新版本 v${SCRIPT_VERSION}"
        return 0
    fi

    if [[ "$_mode" == auto ]]; then
        echo "[auto-update] 发现新版本 v${SCRIPT_VERSION} → v${latest}，开始更新"
    else
        printf "${C_YELLOW}发现新版本: v%s → v%s${C_RESET}\n" "$SCRIPT_VERSION" "$latest"
        printf "${C_PURPLE}是否更新? [Y/n]: ${C_RESET}"
        local _yn; read -r _yn
        [[ "${_yn:-Y}" =~ ^[Nn]$ ]] && return 0
    fi

    # 与脚本同目录建临时文件，确保后续 mv 是同文件系统内的原子替换
    tmp_file=$(mktemp "${self_path}.XXXXXX") || { msg_error "无法创建临时文件"; return 1; }
    trap "rm -f '$tmp_file'" RETURN

    if ! curl -fsSL --max-time 60 \
        "https://raw.githubusercontent.com/${SELF_REPO}/v${latest}/vps-mgr.sh" -o "$tmp_file"; then
        [[ "$_mode" == auto ]] && echo "[auto-update] 下载失败" >&2 || msg_error "下载失败，请检查网络"
        return 1
    fi

    # 语法校验：绝不用损坏的脚本覆盖正在使用的版本
    if ! bash -n "$tmp_file" 2>/dev/null; then
        [[ "$_mode" == auto ]] && echo "[auto-update] 语法校验失败，放弃" >&2 \
                               || msg_error "新版本语法校验失败，已放弃更新"
        return 1
    fi

    cp -p "$self_path" "${self_path}.bak" 2>/dev/null || true
    chmod +x "$tmp_file"
    mv "$tmp_file" "$self_path"
    trap - RETURN

    if [[ "$_mode" == auto ]]; then
        echo "[auto-update] 已更新到 v${latest}（旧版备份 ${self_path}.bak）"
        return 0   # 定时器场景不 exec —— 无交互终端，替换文件即可，下次开菜单即新版
    fi
    msg_success "已更新到 v${latest}（旧版备份: ${self_path}.bak）"
    msg_info "3 秒后重启脚本..."
    sleep 3
    exec "$self_path"
}

# 安装/开启每日自动更新定时器（仅正式版）。记录当前脚本路径，定时器认这个路径原地替换。
install_autoupdate() {
    local _self; _self=$(realpath "${BASH_SOURCE[0]}")
    cat > /etc/systemd/system/vps-mgr-autoupdate.service <<EOF
[Unit]
Description=vps-mgr auto-update (stable releases only)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${_self} auto-update
EOF
    # 固定用上海时区(而非机器本地时区)——各地机器在同一时刻统一更新，时间可预测：
    # 每天上海 05:00 起、1 小时内随机触发(05:00~06:00)。你在上海 05:00 前把新正式版测好即可。
    cat > /etc/systemd/system/vps-mgr-autoupdate.timer <<'EOF'
[Unit]
Description=Daily vps-mgr auto-update check (Shanghai 05:00-06:00)

[Timer]
OnCalendar=*-*-* 05:00:00 Asia/Shanghai
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now vps-mgr-autoupdate.timer >/dev/null 2>&1 || true
}

uninstall_autoupdate() {
    systemctl disable --now vps-mgr-autoupdate.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/vps-mgr-autoupdate.service /etc/systemd/system/vps-mgr-autoupdate.timer
    systemctl daemon-reload 2>/dev/null || true
}

_do_update_menu() {
    clear
    printf "${C_BLUE}=== 更新服务 ===${C_RESET}\n\n"
    local _sv _sn _ssv _ssn _rv _rn
    _sv=$(get_installed_version snell "$SNELL_BIN")
    _sn=$(get_cached_latest_version snell)
    _ssv=$([[ -x "$SBX_BIN" ]] && "$SBX_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1 || true)
    _ssn=""
    _rv=$(get_installed_version realm "$REALM_BIN")
    _rn=$(get_cached_latest_version realm)

    printf " ${C_GREEN}1.${C_RESET} Snell      "
    if [[ -f "$SNELL_BIN" ]]; then
        [[ -n "$_sn" && "$_sn" != "$_sv" ]] \
            && printf "  ${C_YELLOW}%s${C_RESET}  →  ${C_GREEN}%s${C_RESET} ${C_RED}[有更新]${C_RESET}\n" "$_sv" "$_sn" \
            || printf "  ${C_GREEN}%s${C_RESET}  (已是最新)\n" "$_sv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf " ${C_GREEN}2.${C_RESET} sing-box   "
    if [[ -x "$SBX_BIN" ]]; then
        printf "  ${C_GREEN}%s${C_RESET}  (选择以重新下载最新版)\n" "$_ssv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf " ${C_GREEN}3.${C_RESET} Realm      "
    if [[ -f "$REALM_BIN" ]]; then
        [[ -n "$_rn" && "$_rn" != "$_rv" ]] \
            && printf "  ${C_YELLOW}%s${C_RESET}  →  ${C_GREEN}%s${C_RESET} ${C_RED}[有更新]${C_RESET}\n" "$_rv" "$_rn" \
            || printf "  ${C_GREEN}%s${C_RESET}  (已是最新)\n" "$_rv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf "\n ${C_GREEN}4.${C_RESET} 一键更新全部有更新的服务\n"
    printf " ${C_GREEN}5.${C_RESET} 本脚本      ${C_GREEN}v%s${C_RESET}  (检查并更新)\n" "$SCRIPT_VERSION"
    local _au_st
    systemctl is-active --quiet vps-mgr-autoupdate.timer 2>/dev/null \
        && _au_st="${C_GREEN}已开启${C_RESET}" || _au_st="${C_DIM}已关闭${C_RESET}"
    printf " ${C_GREEN}6.${C_RESET} 自动更新    %b  (每天检查，仅正式版)\n" "$_au_st"
    printf " ${C_GREEN}0.${C_RESET} 返回\n"
    printf "\n${C_PURPLE}请选择: ${C_RESET}"
    read -r _upd_ch
    case "$_upd_ch" in
        1) [[ -f "$SNELL_BIN" ]] && update_service "snell" || msg_warn "Snell 未安装" ;;
        2) [[ -x "$SBX_BIN" ]] && update_service "sing-box" || msg_warn "sing-box 未安装" ;;
        3) [[ -f "$REALM_BIN" ]] && update_service "realm" || msg_warn "Realm 未安装" ;;
        4)
            local _did=0
            if [[ -f "$SNELL_BIN" && -n "$_sn" && "$_sn" != "$_sv" ]]; then
                update_service "snell"; _did=1
            fi
            if [[ -f "$REALM_BIN" && -n "$_rn" && "$_rn" != "$_rv" ]]; then
                update_service "realm"; _did=1
            fi
            [[ $_did -eq 0 ]] && printf "${C_GREEN}所有服务均已是最新版本${C_RESET}\n"
            ;;
        5) self_update ;;
        6) if systemctl is-active --quiet vps-mgr-autoupdate.timer 2>/dev/null; then
               uninstall_autoupdate; msg_info "自动更新已关闭"
           else
               install_autoupdate; msg_success "自动更新已开启（每天检查正式版，预发布不更新）"
           fi ;;
        0) return ;;
        *) msg_warn "无效选项" ;;
    esac
}

_do_uninstall_menu() {
    clear
    printf "${C_BLUE}=== 卸载服务 ===${C_RESET}\n\n"
    printf " ${C_GREEN}1.${C_RESET} 卸载 Snell\n"
    printf " ${C_GREEN}2.${C_RESET} 卸载 sing-box (SS/SOCKS5/Hy2 全部)\n"
    printf " ${C_GREEN}3.${C_RESET} 卸载 Realm\n"
    printf " ${C_GREEN}0.${C_RESET} 返回\n"
    printf "\n${C_PURPLE}请选择: ${C_RESET}"
    read -r _unin_ch
    case "$_unin_ch" in
        1) uninstall_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$SNELL_SERVICE_FILE" "" ;;
        2) sbx_uninstall ;;
        3) uninstall_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$REALM_SERVICE_FILE" "$REALM_CONFIG_FILE" ;;
        0) return ;;
        *) msg_warn "取消卸载" ;;
    esac
}



# ==============================================================================
# 流量配额常量
# ==============================================================================

readonly QUOTA_DIR="${WORK_DIR}/quota"
readonly QUOTA_CONFIG="${QUOTA_DIR}/quota.conf"
readonly QUOTA_DATA="${QUOTA_DIR}/quota.data"
readonly QUOTA_CHAIN_IN="QUOTA_IN"
readonly QUOTA_CHAIN_OUT="QUOTA_OUT"

# ==============================================================================
# 流量配额与到期管理模块
# ==============================================================================

_qbytes_human() {
    local b=${1:-0}
    if   (( b >= 1099511627776 )); then
        awk -v b="$b" 'BEGIN{v=b/1099511627776; printf (v==int(v))?"%.0f TB":"%.2f TB",v}'
    elif (( b >= 1073741824 )); then
        awk -v b="$b" 'BEGIN{v=b/1073741824;    printf (v==int(v))?"%.0f GB":"%.2f GB",v}'
    elif (( b >= 1048576 )); then
        awk -v b="$b" 'BEGIN{v=b/1048576;       printf (v==int(v))?"%.0f MB":"%.1f MB",v}'
    elif (( b >= 1024 )); then
        awk -v b="$b" 'BEGIN{printf "%.0f KB", b/1024}'
    else
        echo "${b} B"
    fi
}

_qhuman_to_bytes() {
    local s="${1^^}" num
    num=$(echo "$s" | tr -dc '0-9.')
    [[ -z "$num" || "$num" == "0" ]] && echo 0 && return
    if   [[ "$s" == *T* ]]; then awk "BEGIN{printf \"%d\", $num*1099511627776}"
    elif [[ "$s" == *G* ]]; then awk "BEGIN{printf \"%d\", $num*1073741824}"
    elif [[ "$s" == *M* ]]; then awk "BEGIN{printf \"%d\", $num*1048576}"
    elif [[ "$s" == *K* ]]; then awk "BEGIN{printf \"%d\", $num*1024}"
    else echo "${num%%.*}"
    fi
}

# TG notify without dying on missing config (safe for timer/non-interactive use)
_quota_tg_notify() {
    local msg="$1"
    _tg_resolve_channel quota
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    send_telegram "$msg" 2>/dev/null || true
}

# Ensure counting chains exist and are linked to INPUT/OUTPUT
quota_init() {
    mkdir -p "$QUOTA_DIR"
    [[ -f "$QUOTA_CONFIG" ]] || touch "$QUOTA_CONFIG"
    [[ -f "$QUOTA_DATA"   ]] || touch "$QUOTA_DATA"
    iptables -N "$QUOTA_CHAIN_IN"  2>/dev/null || true
    iptables -N "$QUOTA_CHAIN_OUT" 2>/dev/null || true
    iptables -C INPUT  -j "$QUOTA_CHAIN_IN"  2>/dev/null || \
        iptables -I INPUT  1 -j "$QUOTA_CHAIN_IN"
    iptables -C OUTPUT -j "$QUOTA_CHAIN_OUT" 2>/dev/null || \
        iptables -I OUTPUT 1 -j "$QUOTA_CHAIN_OUT"

    # Auto-reinstall timers if config exists, timer not running, and not manually disabled
    if grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null && \
       ! systemctl is-active --quiet quota-check.timer 2>/dev/null && \
       [[ ! -f "${QUOTA_DIR}/.timer_disabled" ]]; then
        install_quota_services >/dev/null 2>&1 || true
    fi
}

# Add RETURN rules in counting chains (byte counter accumulates on RETURN)
quota_add_counting_rules() {
    local port="$1"
    for proto in tcp udp; do
        iptables -C "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN 2>/dev/null || \
            iptables -A "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN
        iptables -C "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN 2>/dev/null || \
            iptables -A "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN
    done
}

quota_remove_counting_rules() {
    local port="$1"
    for proto in tcp udp; do
        iptables -D "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN 2>/dev/null || true
        iptables -D "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN 2>/dev/null || true
    done
}

# Read accumulated bytes from a counting chain for a specific port
# -x / --exact: prevents iptables from abbreviating large counts (1234K, 2M, etc.)
_quota_iptables_bytes() {
    local chain="$1" direction="$2" port="$3"
    iptables -nvxL "$chain" 2>/dev/null | \
        awk -v d="$direction" -v p="$port" \
            '$0 ~ (d":"p"( |$)") { sum += $2 } END { print sum+0 }'
}

quota_get_port_bytes() {
    local port="$1"
    local in_b out_b
    in_b=$(_quota_iptables_bytes "$QUOTA_CHAIN_IN"  "dpt" "$port")
    out_b=$(_quota_iptables_bytes "$QUOTA_CHAIN_OUT" "spt" "$port")
    echo "$in_b $out_b"
}

# Read port data: outputs "month iptbl_in iptbl_out acc_in acc_out paused pause_reason"
_quota_read_data() {
    local port="$1"
    local line
    line=$(grep -m1 "^${port}|" "$QUOTA_DATA" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        echo "$(TZ="$TZ_DEFAULT" date +%Y-%m) 0 0 0 0 0 -"
    else
        IFS='|' read -r _ month iptbl_in iptbl_out acc_in acc_out paused pause_reason <<< "$line"
        echo "${month:-$(TZ="$TZ_DEFAULT" date +%Y-%m)} ${iptbl_in:-0} ${iptbl_out:-0} ${acc_in:-0} ${acc_out:-0} ${paused:-0} ${pause_reason:--}"
    fi
}

# Write/update port data line atomically
_quota_write_data() {
    local port="$1" month="$2" iptbl_in="$3" iptbl_out="$4" \
          acc_in="$5" acc_out="$6" paused="$7" pause_reason="$8"
    local newline="${port}|${month}|${iptbl_in}|${iptbl_out}|${acc_in}|${acc_out}|${paused}|${pause_reason}"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN
    grep -v "^${port}|" "$QUOTA_DATA" > "$tmpfile" 2>/dev/null || true
    echo "$newline" >> "$tmpfile"
    mv "$tmpfile" "$QUOTA_DATA"
}

# Commit current iptables counters into accumulated data (mutating)
_quota_commit_port() {
    local port="$1" cur_month="$2"
    read -r month iptbl_in iptbl_out acc_in acc_out paused pause_reason \
        < <(_quota_read_data "$port")
    read -r cur_in cur_out < <(quota_get_port_bytes "$port")

    # New month: reset accumulators, take new snapshot baseline
    if [[ "$month" != "$cur_month" ]]; then
        _quota_write_data "$port" "$cur_month" "$cur_in" "$cur_out" \
            0 0 "$paused" "$pause_reason"
        return
    fi

    # Reboot/counter-reset detection: if current < snapshot, old bytes are gone
    (( cur_in  < iptbl_in  )) && iptbl_in=0
    (( cur_out < iptbl_out )) && iptbl_out=0

    _quota_write_data "$port" "$cur_month" "$cur_in" "$cur_out" \
        $(( acc_in  + cur_in  - iptbl_in  )) \
        $(( acc_out + cur_out - iptbl_out )) \
        "$paused" "$pause_reason"
}

# Pause a port by inserting DROP rules before the counting chain
quota_pause_port() {
    local port="$1" reason="${2:-manual}"
    for proto in tcp udp; do
        iptables -C INPUT  -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || \
        iptables -I INPUT  1 -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP
        iptables -C OUTPUT -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || \
        iptables -I OUTPUT 1 -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP
    done
    read -r month iptbl_in iptbl_out acc_in acc_out _p _r < <(_quota_read_data "$port")
    _quota_write_data "$port" "$month" "$iptbl_in" "$iptbl_out" \
        "$acc_in" "$acc_out" 1 "$reason"
}

# Resume a port by removing DROP rules
quota_resume_port() {
    local port="$1"
    for proto in tcp udp; do
        iptables -D INPUT  -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || true
    done
    read -r month iptbl_in iptbl_out acc_in acc_out _p _r < <(_quota_read_data "$port")
    _quota_write_data "$port" "$month" "$iptbl_in" "$iptbl_out" \
        "$acc_in" "$acc_out" 0 "-"
}

# Periodic check: enforce quota/expiry, auto-resume on new month (called by timer)
quota_check_all() {
    [[ ! -f "$QUOTA_CONFIG" ]] && return 0

    # 防并发：定时器与交互操作可能同时触发，后者静默跳过
    local _qlock="/run/proxy-manager-quota.lock"
    local _qpid="/run/proxy-manager-quota.pid"
    exec 8>"$_qlock"
    if ! flock -n 8 2>/dev/null; then
        local _pid
        _pid=$(cat "$_qpid" 2>/dev/null || true)
        if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null; then
            return 0
        fi
        return 0
    fi
    echo $$ > "$_qpid"
    trap "rm -f '$_qpid'" RETURN

    quota_init
    # 清理过期告警标记：.warned_<口>_<月> / .expwarn_<口>_<到期日> 会逐月累积；
    # 超过 35 天的必属往月/已过期（当月标记最多约 31 天），删之不会误清当前有效标记
    find "$QUOTA_DIR" -maxdepth 1 -type f \( -name '.warned_*' -o -name '.expwarn_*' \) \
        -mtime +35 -delete 2>/dev/null || true
    local cur_month cur_date node_id
    cur_month=$(TZ="$TZ_DEFAULT" date +%Y-%m)
    cur_date=$(TZ="$TZ_DEFAULT" date +%Y-%m-%d)
    node_id=$(get_node_id)

    while IFS='|' read -r port alias quota_bytes expiry _bw; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue

        _quota_commit_port "$port" "$cur_month"
        read -r _m _ii _io acc_in acc_out paused pause_reason \
            < <(_quota_read_data "$port")
        local total
        total=$(( acc_in + acc_out ))

        # ── 新月自动恢复 (quota暂停) ─────────────────────────────────────
        if [[ "$paused" == "1" && "$pause_reason" == "quota" ]]; then
            if [[ "${quota_bytes:-0}" -eq 0 || "$total" -lt "${quota_bytes}" ]]; then
                quota_resume_port "$port"
                _quota_tg_notify "🟢 流量已重置 ${node_id}
#${alias} 端口 ${port} 新月份流量已重置，自动恢复运行。"
                paused=0; pause_reason="-"
            fi
        fi

        # ── 到期7天自动删除 ──────────────────────────────────────────────
        if [[ "$paused" == "1" && "$pause_reason" == "expiry" && "$expiry" != "-" && -n "$expiry" ]]; then
            local _exp_ts _days_since
            _exp_ts=$(TZ="$TZ_DEFAULT" date -d "$expiry" +%s 2>/dev/null || echo 0)
            _days_since=$(( ( $(date +%s) - _exp_ts ) / 86400 ))
            if (( _days_since >= 7 )); then
                _quota_auto_delete "$port" "$alias"
                continue
            fi
        fi

        [[ "$paused" == "1" ]] && continue  # already paused, skip further checks

        # ── 到期检查 ─────────────────────────────────────────────────────
        if [[ "$expiry" != "-" && -n "$expiry" && "$cur_date" > "$expiry" ]]; then
            quota_pause_port "$port" "expiry"
            _quota_tg_notify "⏰ 端口已到期 ${node_id}
#${alias} 端口 ${port} 已于 ${expiry} 到期，已自动暂停。"
            continue
        fi
        # 到期前1天提醒（每个到期日只推一次）
        if [[ "$expiry" != "-" && -n "$expiry" ]]; then
            local tomorrow
            tomorrow=$(TZ="$TZ_DEFAULT" date -d "tomorrow" +%Y-%m-%d 2>/dev/null || TZ="$TZ_DEFAULT" date -v+1d +%Y-%m-%d 2>/dev/null || true)
            local _exp_warn_flag="${QUOTA_DIR}/.expwarn_${port}_${expiry}"
            if [[ "$expiry" == "$tomorrow" && ! -f "$_exp_warn_flag" ]]; then
                _quota_tg_notify "🟡 到期预警 ${node_id}
#${alias} 端口 ${port} 明天 (${expiry}) 到期，请及时处理。"
                touch "$_exp_warn_flag"
            fi
        fi

        # ── 流量超限检查 ─────────────────────────────────────────────────
        if [[ "${quota_bytes:-0}" -gt 0 && "$total" -ge "$quota_bytes" ]]; then
            quota_pause_port "$port" "quota"
            local used_h limit_h
            used_h=$(_qbytes_human "$total")
            limit_h=$(_qbytes_human "$quota_bytes")
            _quota_tg_notify "🚫 流量超限 ${node_id}
#${alias} 端口 ${port} 流量已达 ${used_h}/${limit_h}，已自动暂停。"
            continue
        fi

        # ── 流量75%预警 ─────────────────────────────────────────────────
        if [[ "${quota_bytes:-0}" -gt 0 ]]; then
            local warn_threshold
            warn_threshold=$(( quota_bytes * 3 / 4 ))
            local warn_flag="${QUOTA_DIR}/.warned_${port}_$(TZ="$TZ_DEFAULT" date +%Y-%m)"
            if [[ "$total" -ge "$warn_threshold" && ! -f "$warn_flag" ]]; then
                local used_h limit_h pct
                pct=$(( total * 100 / quota_bytes ))
                used_h=$(_qbytes_human "$total")
                limit_h=$(_qbytes_human "$quota_bytes")
                _quota_tg_notify "⚠️ 流量预警 ${node_id}
#${alias} 端口 ${port} 流量已用 ${pct}%（${used_h}/${limit_h}），请注意。"
                touch "$warn_flag"
            fi
        fi

    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)
}

# Build a visual progress bar (10 blocks)
_quota_bar() {
    local used="$1" total="$2"
    local pct=0 filled=0
    [[ "${total:-0}" -gt 0 ]] && pct=$(( used * 100 / total )) && \
        filled=$(( pct * 10 / 100 ))
    [[ $filled -gt 10 ]] && filled=10
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=filled; i<10; i++ )); do bar+="░"; done
    echo "$bar" "$pct"
}

# Daily 21:00 quota report pushed to Telegram
quota_daily_report() {
    [[ ! -f "$QUOTA_CONFIG" ]] && return 0
    quota_init
    local cur_month cur_date node_id
    cur_month=$(TZ="$TZ_DEFAULT" date +%Y-%m)
    cur_date=$(TZ="$TZ_DEFAULT" date +%Y-%m-%d)
    node_id=$(get_node_id)

    local msg="📊 配额日报 ${cur_date} ${node_id}"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n'
    local has_port=0

    while IFS='|' read -r port alias quota_bytes expiry _bw; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        has_port=1

        _quota_commit_port "$port" "$cur_month"
        read -r _m _ii _io acc_in acc_out paused pause_reason \
            < <(_quota_read_data "$port")
        local total
        total=$(( acc_in + acc_out ))

        local icon="🟢"
        [[ "$paused" == "1" ]] && icon="🔴"
        msg+="${icon} #${alias} (端口 ${port})"$'\n'

        if [[ "${quota_bytes:-0}" -gt 0 ]]; then
            read -r bar pct < <(_quota_bar "$total" "$quota_bytes")
            local used_h limit_h remain remain_h
            used_h=$(_qbytes_human "$total")
            limit_h=$(_qbytes_human "$quota_bytes")
            remain=$(( quota_bytes - total ))
            [[ $remain -lt 0 ]] && remain=0
            remain_h=$(_qbytes_human "$remain")
            msg+="  [${bar}] ${pct}%"$'\n'
            msg+="  已用 ${used_h} / 限制 ${limit_h} / 剩余 ${remain_h}"$'\n'
        else
            local used_h
            used_h=$(_qbytes_human "$total")
            msg+="  已用 ${used_h}（无流量限制）"$'\n'
        fi

        if [[ "$expiry" != "-" && -n "$expiry" ]]; then
            local days_left _exp_ts
            _exp_ts=$(TZ="$TZ_DEFAULT" date -d "$expiry" +%s 2>/dev/null || echo 0)
            days_left=$(( ( _exp_ts - $(date +%s) ) / 86400 ))
            if (( days_left < 0 )); then
                msg+="  到期: ${expiry} 🔴 已过期"$'\n'
            else
                msg+="  到期: ${expiry}（剩余 ${days_left} 天）"$'\n'
            fi
        fi

        if [[ "$paused" == "1" ]]; then
            local reason_txt="手动暂停"
            [[ "$pause_reason" == "quota"  ]] && reason_txt="流量超限"
            [[ "$pause_reason" == "expiry" ]] && reason_txt="已到期"
            msg+="  状态: 已暂停（${reason_txt}）"$'\n'
        fi

        msg+="━━━━━━━━━━━━━━━━━━"$'\n'
    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

    [[ $has_port -eq 0 ]] && msg+="（暂无配置端口）"$'\n'

    _quota_tg_notify "$msg"
}

# Write/update a config entry for a port
_quota_write_config() {
    local port="$1" alias="$2" quota_bytes="$3" expiry="$4" bw_kbps="$5"
    local newline="${port}|${alias}|${quota_bytes}|${expiry}|${bw_kbps}"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$tmpfile" 2>/dev/null || true
    echo "$newline" >> "$tmpfile"
    mv "$tmpfile" "$QUOTA_CONFIG"
}

# Interactive: add or update a port's quota settings
quota_set_port() {
    quota_init
    printf "\n${C_CYAN}=== 添加/修改端口配额 ===${C_RESET}\n\n"

    # ── 自动发现已安装服务的端口 ──────────────────────────────────────
    local -a _disc_ports=() _disc_descs=()
    local _p _desc

    # Snell（多实例，每个配置文件一个节点）
    while IFS= read -r _sf; do
        _p=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
        [[ -n "$_p" ]] && _disc_ports+=("$_p") && _disc_descs+=("Snell          端口 ${_p}")
    done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)

    # sing-box SS (多节点多端口)
    if [[ -d "$SBX_ST" ]]; then
        local _ssf
        for _ssf in "$SBX_ST"/ss-*.env; do
            [[ -e "$_ssf" ]] || continue
            _p=$(basename "$_ssf"); _p=${_p#ss-}; _p=${_p%.env}
            [[ "$_p" =~ ^[0-9]+$ ]] || continue
            local _ss_method
            _ss_method=$(grep -oE '^S_METHOD=.*' "$_ssf" 2>/dev/null | cut -d= -f2- || true)
            _disc_ports+=("$_p")
            _disc_descs+=("sing-box SS    端口 ${_p}  (${_ss_method:-?})")
        done
    fi

    # Realm (从 metadata 取别名，无 metadata 则用 listen→remote)
    if [[ -f "$REALM_CONFIG_FILE" ]]; then
        while IFS= read -r _line; do
            local _listen _remote _lport _ralias
            _listen=$(jq -r '.listen' <<< "$_line" 2>/dev/null || true)
            _remote=$(jq -r '.remote' <<< "$_line" 2>/dev/null || true)
            _lport=$(echo "$_listen" | cut -d: -f2)
            [[ "$_lport" =~ ^[0-9]+$ ]] || continue
            _ralias=""
            [[ -f "$REALM_META_FILE" ]] && \
                _ralias=$(jq -r --arg p "$_lport" '.[$p].alias // empty' \
                    "$REALM_META_FILE" 2>/dev/null || true)
            [[ -z "$_ralias" ]] && _ralias="${_lport} → ${_remote}"
            _disc_ports+=("$_lport")
            _disc_descs+=("Realm          端口 ${_lport}  ${_ralias}")
        done < <(jq -c '.endpoints[]?' "$REALM_CONFIG_FILE" 2>/dev/null || true)
    fi

    # ── 显示选择列表 ───────────────────────────────────────────────────
    local port=""
    if [[ ${#_disc_ports[@]} -gt 0 ]]; then
        printf "${C_BLUE}检测到以下服务端口:${C_RESET}\n"
        local _i
        for _i in "${!_disc_ports[@]}"; do
            local _already=""
            grep -q "^${_disc_ports[$_i]}|" "$QUOTA_CONFIG" 2>/dev/null && \
                _already=" ${C_YELLOW}[已配置]${C_RESET}"
            printf "  ${C_GREEN}%2d.${C_RESET} %s%b\n" \
                "$(( _i + 1 ))" "${_disc_descs[$_i]}" "$_already"
        done
        printf "  ${C_GREEN}%2d.${C_RESET} 手动输入端口号\n" "$(( ${#_disc_ports[@]} + 1 ))"
        printf "\n${C_CYAN}请选择 [1-%d]: ${C_RESET}" "$(( ${#_disc_ports[@]} + 1 ))"
        read -r _sel
        if [[ "$_sel" =~ ^[0-9]+$ ]] && \
           (( _sel >= 1 && _sel <= ${#_disc_ports[@]} )); then
            port="${_disc_ports[$(( _sel - 1 ))]}"
            printf "已选择端口: ${C_CYAN}%s${C_RESET}\n\n" "$port"
        else
            printf "端口号: "; read -r port
        fi
    else
        printf "端口号: "; read -r port
    fi

    [[ ! "$port" =~ ^[0-9]+$ ]] && { msg_error "无效端口号"; return; }

    # Pre-fill existing values if port already configured
    local old_alias="" old_quota="" old_expiry="" old_bw=""
    local existing
    existing=$(grep -m1 "^${port}|" "$QUOTA_CONFIG" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        IFS='|' read -r _ old_alias old_quota old_expiry old_bw <<< "$existing"
    fi

    # 自动填入别名（从 Realm metadata 或服务类型）
    if [[ -z "$old_alias" ]]; then
        for _i in "${!_disc_ports[@]}"; do
            if [[ "${_disc_ports[$_i]}" == "$port" ]]; then
                # Extract: "Realm  端口 9003  HK → ..." → "HK → ..."
                # Or:      "Snell  端口 9001"            → "Snell:9001"
                local _raw="${_disc_descs[$_i]}"
                local _after_port
                _after_port=$(echo "$_raw" | sed 's/.*端口 [0-9]\+  *//')
                if [[ -n "$_after_port" && "$_after_port" != "$_raw" ]]; then
                    old_alias="$_after_port"
                else
                    # Snell/SS: no alias after port, use service type
                    old_alias=$(echo "$_raw" | awk '{print $1}')":${port}"
                fi
                break
            fi
        done
    fi

    printf "别名 [${old_alias:-Port${port}}]: "; read -r alias
    [[ -z "$alias" ]] && alias="${old_alias:-Port${port}}"
    alias="${alias//|/ }"   # 过滤管道符，防止破坏 pipe-delimited 配置文件格式

    printf "月流量限制 GB (纯数字=GB，也可加单位如 500MB，0=无限制) [${old_quota:+$(_qbytes_human "$old_quota")}]: "
    read -r quota_input
    local quota_bytes=0
    if [[ -n "$quota_input" ]]; then
        if [[ "$quota_input" == "0" ]]; then
            quota_bytes=0
        elif [[ "$quota_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            # 纯数字默认单位 GB
            quota_bytes=$(_qhuman_to_bytes "${quota_input}GB")
        else
            quota_bytes=$(_qhuman_to_bytes "$quota_input")
        fi
    else
        quota_bytes="${old_quota:-0}"
    fi

    printf "到期日期 (YYYY-MM-DD 或 YYYY-M-D，直接回车=无到期) [${old_expiry:--}]: "; read -r expiry
    if [[ -z "$expiry" ]]; then
        expiry="${old_expiry:--}"
    fi
    if [[ "$expiry" != "-" ]]; then
        # 补零：2026-4-3 → 2026-04-03
        expiry=$(awk -F- '{printf "%04d-%02d-%02d", $1, $2, $3}' <<< "$expiry" 2>/dev/null || true)
        if [[ ! "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            msg_error "日期格式错误，示例: 2026-05-31"; return
        fi
    fi

    local bw_kbps="${old_bw:-0}"

    _quota_write_config "$port" "$alias" "$quota_bytes" "$expiry" "$bw_kbps"
    quota_add_counting_rules "$port"

    msg_info "端口 ${port}【${alias}】配额已保存"
    [[ "$quota_bytes" -gt 0 ]] && \
        printf "  月流量限制: %s\n" "$(_qbytes_human "$quota_bytes")"
    [[ "$expiry" != "-" ]] && \
        printf "  到期日期:   %s\n" "$expiry"

    # Auto-install timers on first use
    if ! systemctl is-active --quiet quota-check.timer 2>/dev/null; then
        msg_info "首次配置配额，自动安装定时巡检服务..."
        install_quota_services
    fi
}

# Show configured quota ports as a numbered list; sets $port on selection.
# Returns 1 if no ports configured or user cancels.
_quota_pick_port() {
    local _prompt="${1:-请选择端口}"
    local -a _qports=() _qaliases=()
    local _cur_month
    _cur_month=$(TZ="$TZ_DEFAULT" date +%Y-%m)

    while IFS='|' read -r _p _a _qb _exp _bw; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        _qports+=("$_p")
        # Build status suffix
        local _suf="" _paused
        read -r _m _ii _io _ai _ao _paused _r < <(_quota_read_data "$_p")
        local _total
        _total=$(( _ai + _ao ))
        local _used_h
        _used_h=$(_qbytes_human "$_total")
        if [[ "$_paused" == "1" ]]; then
            _suf=" ${C_RED}[暂停]${C_RESET}"
        fi
        local _limit_str="无限制"
        [[ "${_qb:-0}" -gt 0 ]] && _limit_str="限 $(_qbytes_human "$_qb")"
        local _exp_str=""
        [[ "$_exp" != "-" && -n "$_exp" ]] && _exp_str=" 到期${_exp}"
        _qaliases+=("$(printf "端口 %-6s %-16s 已用 %-10s %s%s" \
            "$_p" "$_a" "$_used_h" "$_limit_str" "$_exp_str")")
    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

    if [[ ${#_qports[@]} -eq 0 ]]; then
        msg_warn "暂无已配置配额的端口"; return 1
    fi

    printf "\n"
    local _i
    for _i in "${!_qports[@]}"; do
        printf "  ${C_GREEN}%2d.${C_RESET} %b%b\n" \
            "$(( _i + 1 ))" "${_qaliases[$_i]}" ""
    done
    printf "\n${C_CYAN}%s [1-%d，0=取消]: ${C_RESET}" "$_prompt" "${#_qports[@]}"
    read -r _sel
    [[ "$_sel" == "0" || -z "$_sel" ]] && return 1
    if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#_qports[@]} )); then
        port="${_qports[$(( _sel - 1 ))]}"
        return 0
    fi
    msg_error "无效选择"; return 1
}

# 非交互：到期7天自动删除（在 quota_check_all 锁内调用，不重复加锁）
_quota_auto_delete() {
    local port="$1" alias="$2"
    local node_id; node_id=$(get_node_id)

    # ── Snell ──────────────────────────────────────────────────────────
    local snell_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    if [[ -f "$snell_conf" ]]; then
        systemctl stop    "snell@${port}.service" 2>/dev/null || true
        systemctl disable "snell@${port}.service" 2>/dev/null || true
        rm -f "$snell_conf"
        close_firewall_port "$port" 2>/dev/null || true
    fi

    # ── sing-box SS ────────────────────────────────────────────────────
    if [[ -e "$SBX_ST/ss-${port}.env" ]]; then
        rm -f "$SBX_ST/ss-${port}.env"
        _sbx_cn_disable "$port" 2>/dev/null || true
        sbx_render 2>/dev/null || true
        close_firewall_port "$port" 2>/dev/null || true
    fi

    # ── Realm ──────────────────────────────────────────────────────────
    if [[ -f "$REALM_CONFIG_FILE" ]]; then
        local realm_idx
        realm_idx=$(jq --arg p "$port" \
            '.endpoints | to_entries[] | select(.value.listen | endswith(":"+$p)) | .key' \
            "$REALM_CONFIG_FILE" 2>/dev/null | head -1)
        if [[ -n "$realm_idx" ]]; then
            local tmp_realm
            tmp_realm=$(mktemp)
            if jq "del(.endpoints[$realm_idx])" "$REALM_CONFIG_FILE" > "$tmp_realm"; then
                mv "$tmp_realm" "$REALM_CONFIG_FILE"
                chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE" 2>/dev/null || true
            else
                rm -f "$tmp_realm"
            fi
            if [[ -f "$REALM_META_FILE" ]]; then
                local tmp_meta
                tmp_meta=$(mktemp)
                jq --arg p "$port" 'del(.[$p])' "$REALM_META_FILE" > "$tmp_meta" \
                    && mv "$tmp_meta" "$REALM_META_FILE" \
                    || rm -f "$tmp_meta"
            fi
            close_firewall_port "$port" 2>/dev/null || true
            _realm_safe_restart || true
        fi
    fi

    # ── 配额配置和数据 ─────────────────────────────────────────────────
    quota_remove_counting_rules "$port" 2>/dev/null || true
    local t1 t2
    t1=$(mktemp); t2=$(mktemp)
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$t1" 2>/dev/null || true
    mv "$t1" "$QUOTA_CONFIG"
    grep -v "^${port}|" "$QUOTA_DATA"   > "$t2" 2>/dev/null || true
    mv "$t2" "$QUOTA_DATA"
    rm -f "${QUOTA_DIR}/.warned_${port}_"* "${QUOTA_DIR}/.expwarn_${port}_"*

    _quota_tg_notify "🗑️ 端口已删除 ${node_id}
#${alias} 端口 ${port} 到期超过 7 天未续期，已自动删除。"
    log_message "INFO" "端口 ${port}【${alias}】到期 7 天自动删除"
}

# Interactive: delete a port's quota settings
quota_delete_port() {
    local port
    _quota_pick_port "选择要删除配额的端口" || return 0
    printf "${C_YELLOW}确认删除端口 ${port} 的配额配置？[y/N]: ${C_RESET}"
    read -r _confirm
    [[ "${_confirm,,}" != "y" ]] && { msg_info "已取消"; return; }
    # 获取配额锁，防止与后台 quota-check 定时器并发写 QUOTA_DATA
    # exec 10> 打开进程级 FD，操作完必须 exec 10>&- 关闭，否则锁持续整个脚本会话
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_remove_counting_rules "$port"
    quota_resume_port "$port"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'; exec 10>&-" RETURN
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$QUOTA_CONFIG"
    local tmpfile2
    tmpfile2=$(mktemp)
    trap "rm -f '$tmpfile2'; exec 10>&-" RETURN
    grep -v "^${port}|" "$QUOTA_DATA"   > "$tmpfile2" 2>/dev/null || true
    mv "$tmpfile2" "$QUOTA_DATA"
    rm -f "${QUOTA_DIR}/.warned_${port}_"*
    exec 10>&-
    msg_info "端口 ${port} 配额配置已删除"
}

quota_manual_pause() {
    local port
    _quota_pick_port "选择要暂停的端口" || return 0
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_pause_port "$port" "manual"
    exec 10>&-
    msg_info "端口 ${port} 已手动暂停"
}

quota_manual_resume() {
    local port
    _quota_pick_port "选择要恢复的端口" || return 0
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_resume_port "$port"
    exec 10>&-
    msg_info "端口 ${port} 已恢复"
}

# Install/reinstall quota systemd timers
install_quota_services() {
    local script_path
    script_path=$(realpath "$0")
    local _unit_dir="/etc/systemd/system"
    local _tmp
    _tmp=$(mktemp -d)
    trap "rm -rf '$_tmp'" RETURN

    cat > "${_tmp}/quota-check.service" <<EOF
[Unit]
Description=Proxy Quota Check
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" quota-check
NoNewPrivileges=true
PrivateTmp=true
EOF

    cat > "${_tmp}/quota-check.timer" <<EOF
[Unit]
Description=Proxy Quota Check Timer (every 5 min)

[Timer]
OnBootSec=60
OnUnitActiveSec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > "${_tmp}/quota-daily.service" <<EOF
[Unit]
Description=Proxy Quota Daily Report (21:00)

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" quota-daily
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WORK_DIR} /var/log/proxy-manager.log
EOF

    cat > "${_tmp}/quota-daily.timer" <<EOF
[Unit]
Description=Proxy Quota Daily Report Timer (21:00)

[Timer]
OnCalendar=*-*-* 21:00:00
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF

    for _f in quota-check.service quota-check.timer quota-daily.service quota-daily.timer; do
        mv "${_tmp}/${_f}" "${_unit_dir}/${_f}"
    done
    # _tmp will be cleaned by trap RETURN

    systemctl daemon-reload
    systemctl enable quota-check.timer || msg_warn "启用 quota-check.timer 失败"
    systemctl enable quota-daily.timer || msg_warn "启用 quota-daily.timer 失败"
    systemctl start  quota-check.timer || msg_warn "启动 quota-check.timer 失败"
    systemctl start  quota-daily.timer || msg_warn "启动 quota-daily.timer 失败"

    rm -f "${QUOTA_DIR}/.timer_disabled"
    msg_info "配额检测定时器已启动 → quota-check.timer（每5分钟）"
    msg_info "配额日报定时器已启动 → quota-daily.timer（每日 21:00）"
    printf "\n${C_GREEN}安装完成！每5分钟自动检测，21:00 推送日报到 Telegram。${C_RESET}\n"
}

uninstall_quota_services() {
    for unit in quota-check quota-daily; do
        systemctl stop    "${unit}.timer"   2>/dev/null || true
        systemctl disable "${unit}.timer"   2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}.service" \
              "/etc/systemd/system/${unit}.timer"
    done
    systemctl daemon-reload
    touch "${QUOTA_DIR}/.timer_disabled"
    msg_info "配额定时器已卸载"
}

manage_quota_menu() {
    while true; do
        clear
        printf "${C_CYAN}╔══════════════════════════════════════╗${C_RESET}\n"
        printf "${C_CYAN}║       流量配额与到期管理              ║${C_RESET}\n"
        printf "${C_CYAN}╚══════════════════════════════════════╝${C_RESET}\n\n"

        # Show current status table
        quota_init
        local cur_month cur_date
        cur_month=$(TZ="$TZ_DEFAULT" date +%Y-%m)
        cur_date=$(TZ="$TZ_DEFAULT" date +%Y-%m-%d)
        local count=0

        printf " ${C_YELLOW}端口   别名           [───进度───] 占比 已用      /配额        到期             状态${C_RESET}\n"
        printf " \033[2m%s\033[0m\n" "────────────────────────────────────────────────────────────────────────────────────"

        while IFS='|' read -r port alias quota_bytes expiry _bw; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            count=$(( count + 1 ))
            _quota_commit_port "$port" "$cur_month"
            read -r _m _ii _io acc_in acc_out paused _r < <(_quota_read_data "$port")
            local total
            total=$(( acc_in + acc_out ))
            local used_h
            used_h=$(_qbytes_human "$total")

            local status_col="${C_GREEN}运行${C_RESET}"
            [[ "$paused" == "1" ]] && status_col="${C_RED}暂停${C_RESET}"

            if [[ "${quota_bytes:-0}" -gt 0 ]]; then
                read -r bar pct < <(_quota_bar "$total" "$quota_bytes")
                local limit_h
                limit_h=$(_qbytes_human "$quota_bytes")
                printf " %-6s %-14s [%s] %3d%% %-10s/%-10s" \
                    "$port" "$alias" "$bar" "$pct" "$used_h" "$limit_h"
            else
                printf " %-6s %-14s %-36s" "$port" "$alias" "已用: ${used_h}（无限制）"
            fi

            if [[ "$expiry" != "-" && -n "$expiry" ]]; then
                local days_left _exp_ts
                _exp_ts=$(TZ="$TZ_DEFAULT" date -d "$expiry" +%s 2>/dev/null || echo 0)
                days_left=$(( ( _exp_ts - $(date +%s) ) / 86400 ))
                printf " 到期%s(%dd)" "$expiry" "$days_left"
            fi
            printf " [%b]\n" "$status_col"
        done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

        if [[ $count -eq 0 ]]; then
            printf " ${C_YELLOW}暂无配置端口，请先选择 1 添加${C_RESET}\n"
        fi

        local _timer_st
        if systemctl is-active --quiet quota-check.timer 2>/dev/null; then
            _timer_st="${C_GREEN}运行中${C_RESET}"
        else
            _timer_st="${C_RED}未安装${C_RESET}"
        fi

        printf "\n"
        printf " ${C_GREEN}1.${C_RESET} 添加/修改端口配额设置\n"
        printf " ${C_GREEN}2.${C_RESET} 删除端口配额设置\n"
        printf " ${C_GREEN}3.${C_RESET} 手动暂停端口\n"
        printf " ${C_GREEN}4.${C_RESET} 手动恢复端口\n"
        printf " ${C_GREEN}5.${C_RESET} 立即推送配额日报\n"
        printf " ${C_GREEN}6.${C_RESET} 安装/重装配额定时器  [定时巡检: %b]\n" "$_timer_st"
        printf " ${C_GREEN}7.${C_RESET} 卸载配额定时器\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r q_choice

        printf "\n"
        case $q_choice in
            1) quota_set_port       || true ;;
            2) quota_delete_port    || true ;;
            3) quota_manual_pause   || true ;;
            4) quota_manual_resume  || true ;;
            5) quota_daily_report || true ;;
            6) install_quota_services  || true ;;
            7) uninstall_quota_services || true ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}

# ==============================================================================
# SECTION 10: sing-box 统一代理（SS / SS2022；后续 SOCKS5 / Hysteria2）
# ==============================================================================
# 设计：每节点一个 env 小文件 (/etc/sb-server/ss-端口.env)，sbx_render 据此重建
# /etc/sing-box/config.json。ACL 域名封禁=route reject(仅作用 SS)；CN IP 封禁=
# 分端口 iptables + ipset(共享周更 timer)。全部按 set -euo pipefail 编写。

# ---- 基础 helper ----
# sing-box 发布包架构名(与 detect_arch 的 aarch64/armv7l 不同，单列)
_sbx_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        *) echo "" ;;
    esac
}

_sbx_ip() {
    if [[ -n "${SERVER_IP:-}" && "$SERVER_IP" != "127.0.0.1" ]]; then
        echo "$SERVER_IP"; return 0
    fi
    curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || echo "127.0.0.1"
}

_sbx_port() { shuf -i "${RAND_PORT_MIN}"-"${RAND_PORT_MAX}" -n1; }

# 列出某协议所有节点端口(升序)
_sbx_ports_of() {
    local f p
    for f in "$SBX_ST"/"$1"-*.env; do
        [[ -e "$f" ]] || continue
        p=$(basename "$f"); p=${p#"$1"-}; echo "${p%.env}"
    done | sort -n
}
_sbx_any()   { _sbx_ports_of "$1" | grep -q .; }
_sbx_count() { _sbx_ports_of "$1" | grep -c . || true; }

# 节点后缀：ss2022(2022方法) / ss(aes-128) / hy2 / socks
_sbx_env_suffix() {
    case "$(basename "$1")" in
        hy2-*)   echo hy2 ;;
        socks-*) echo socks ;;
        ss-*)    local _m; _m=$(grep -oE '^S_METHOD=.*' "$1" 2>/dev/null | cut -d= -f2- || true)
                 [[ "$_m" == "2022-blake3-aes-256-gcm" ]] && echo ss2022 || echo ss ;;
    esac
}

# 节点显示名：优先 国旗_SERVER_NAME(主菜单选项1设置,存 TG_CONF)；否则回落 国旗_末段-后缀[-序号]
_sbx_name_for() {
    local f="$1" ip="$2" sfx flag base tport ports p i=0 idx=1 srv
    flag=$(get_flag_emoji "${SERVER_COUNTRY_CODE:-}")
    srv=$(grep "^SERVER_NAME=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]\$//" || true)
    if [[ -n "$srv" ]]; then
        case "$srv" in "$flag"*) echo "$srv" ;; *) [[ -n "$flag" ]] && echo "${flag}_${srv}" || echo "$srv" ;; esac
        return 0
    fi
    sfx=$(_sbx_env_suffix "$f"); base="${flag}_$(echo "$ip" | cut -d. -f4)"
    tport=$(basename "$f"); tport=${tport#*-}; tport=${tport%.env}
    ports=$(for g in "$SBX_ST"/ss-*.env "$SBX_ST"/socks-*.env "$SBX_ST"/hy2-*.env; do
                [[ -e "$g" ]] || continue
                [[ "$(_sbx_env_suffix "$g")" == "$sfx" ]] || continue
                p=$(basename "$g"); p=${p#*-}; echo "${p%.env}"
            done | sort -n)
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        i=$((i + 1)); [[ "$p" == "$tport" ]] && idx=$i
    done <<< "$ports"
    [[ "$idx" -le 1 ]] && echo "${base}-${sfx}" || echo "${base}-${sfx}-${idx}"
}

# 选未占用端口(避开监听/Snell/Realm 已用端口)
_sbx_pick_port() {
    local p n=0
    while [[ $n -lt 30 ]]; do
        p=$(_sbx_port)
        _check_port_available "$p" 2>/dev/null && { echo "$p"; return 0; }
        n=$((n + 1))
    done
    _sbx_port
}

# ---- 安装 sing-box 核心二进制 ----
sbx_install_core() {
    [[ -x "$SBX_BIN" ]] && { msg_success "sing-box 已安装: $("$SBX_BIN" version 2>/dev/null | head -1)"; return 0; }
    local a; a=$(_sbx_arch)
    [[ -z "$a" ]] && { msg_error "不支持的架构 $(uname -m)"; return 1; }
    msg_step "下载最新 sing-box ($a)..."
    local ver url tmp
    ver=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
            | grep -oE '"tag_name": *"v[^"]+"' | head -1 | grep -oE 'v[0-9.]+' || true)
    [[ -z "$ver" ]] && { msg_error "获取 sing-box 版本号失败"; return 1; }
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-${a}.tar.gz"
    tmp=$(mktemp -d)
    if ! curl -fsSL "$url" -o "$tmp/s.tgz"; then
        msg_error "下载失败: $url"; rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/s.tgz" -C "$tmp" || ! install -m0755 "$tmp"/sing-box-*/sing-box "$SBX_BIN"; then
        msg_error "解压或安装 sing-box 失败"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    mkdir -p "$SBX_ETC" "$SBX_ST"
    cat > "/etc/systemd/system/${SBX_SVC}.service" <<EOF
[Unit]
Description=sing-box server
After=network.target nss-lookup.target

[Service]
ExecStart=$SBX_BIN run -c $SBX_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    msg_success "sing-box ${ver} 安装完成"
}

# ---- 重建 config.json 并重启 ----
sbx_render() {
    local ib="" f
    local -a ss_tags=()
    for f in "$SBX_ST"/ss-*.env; do
        [[ -e "$f" ]] || continue
        local S_PORT="" S_PW="" S_METHOD=""
        # shellcheck disable=SC1090
        . "$f"
        [[ -n "$ib" ]] && ib+=$',\n'
        ss_tags+=("ss-${S_PORT}")
        ib+=$(printf '    { "type":"shadowsocks","tag":"ss-%s","listen":"::","listen_port":%s,"method":"%s","password":"%s" }' \
                "$S_PORT" "$S_PORT" "$S_METHOD" "$S_PW")
    done
    for f in "$SBX_ST"/socks-*.env; do
        [[ -e "$f" ]] || continue
        local SK_PORT="" SK_USER="" SK_PW=""
        # shellcheck disable=SC1090
        . "$f"
        [[ -n "$ib" ]] && ib+=$',\n'
        ib+=$(printf '    { "type":"socks","tag":"socks-%s","listen":"::","listen_port":%s,"users":[{"username":"%s","password":"%s"}] }' \
                "$SK_PORT" "$SK_PORT" "$SK_USER" "$SK_PW")
    done
    for f in "$SBX_ST"/hy2-*.env; do
        [[ -e "$f" ]] || continue
        local H_PORT="" H_PW="" H_OBFS="" H_UP="" H_DOWN="" H_CRT="" H_KEY=""
        # shellcheck disable=SC1090
        . "$f"
        [[ -n "$ib" ]] && ib+=$',\n'
        ib+=$(printf '    { "type":"hysteria2","tag":"hy2-%s","listen":"::","listen_port":%s,"up_mbps":%s,"down_mbps":%s,"obfs":{"type":"salamander","password":"%s"},"users":[{"password":"%s"}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"%s","key_path":"%s"}}' \
                "$H_PORT" "$H_PORT" "$H_UP" "$H_DOWN" "$H_OBFS" "$H_PW" "$H_CRT" "$H_KEY")
    done
    if [[ -z "$ib" ]]; then
        systemctl stop "$SBX_SVC" 2>/dev/null || true
        msg_warn "已无启用协议，sing-box 已停止"
        return 0
    fi
    local route=""
    if [[ ${#ss_tags[@]} -gt 0 && -f "$SBX_ST/acl.enabled" && -s "$SBX_ACL" ]]; then
        local _doms _tags
        _doms=$(grep -vE '^[[:space:]]*(#|$)' "$SBX_ACL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/.*/"&"/' | paste -sd, - || true)
        _tags=$(printf '"%s",' "${ss_tags[@]}"); _tags="[${_tags%,}]"
        [[ -n "$_doms" ]] && route=$(printf ',\n  "route":{"rules":[{"inbound":%s,"domain_suffix":[%s],"action":"reject"}]}' "$_tags" "$_doms")
    fi
    mkdir -p "$SBX_ETC"
    cat > "$SBX_CONF" <<EOF
{ "log":{"level":"warn","timestamp":true},
  "inbounds":[
$ib
  ],
  "outbounds":[{"type":"direct","tag":"direct"}]${route} }
EOF
    local _chk
    if ! _chk=$("$SBX_BIN" check -c "$SBX_CONF" 2>&1); then
        msg_error "sing-box 配置校验失败:"
        printf '%s\n' "$_chk"
        return 1
    fi
    systemctl enable "$SBX_SVC" >/dev/null 2>&1 || true
    systemctl restart "$SBX_SVC"
    sleep 1
    if systemctl is-active --quiet "$SBX_SVC"; then
        msg_success "sing-box 已运行"
    else
        msg_error "sing-box 启动失败"
        journalctl -u "$SBX_SVC" -n15 --no-pager 2>/dev/null || true
        return 1
    fi
}

# ---- 客户端配置输出 ----
_sbx_show_one() {
    local f="$1" ip nm
    ip=$(_sbx_ip); nm=$(_sbx_name_for "$f" "$ip")
    case "$(basename "$f")" in
        ss-*)
            local S_PORT="" S_PW="" S_METHOD="" u
            # shellcheck disable=SC1090
            . "$f"
            u=$(printf '%s:%s' "$S_METHOD" "$S_PW" | base64 -w0 2>/dev/null || true)
            printf "${C_GREEN}ss://%s@%s:%s#%s${C_RESET}\n" "$u" "$ip" "$S_PORT" "$nm"
            ;;
        socks-*)
            local SK_PORT="" SK_USER="" SK_PW="" SK_WL=""
            # shellcheck disable=SC1090
            . "$f"
            printf "${C_GREEN}socks5://%s:%s@%s:%s${C_RESET}" "$SK_USER" "$SK_PW" "$ip" "$SK_PORT"
            # 白名单为空 = 端口全拒绝：节点看着正常却连不上，唯一线索就在这里，必须提示。
            # 已配置则不显示 IP —— 占版面，要看去 sing-box 菜单的 SOCKS5 白名单管理。
            [[ -z "$SK_WL" ]] && printf "   ${C_RED}⚠ 白名单为空，端口全拒绝${C_RESET}"
            printf "\n"
            ;;
        hy2-*)
            local H_PORT="" H_PW="" H_OBFS="" H_SNI=""
            # shellcheck disable=SC1090
            . "$f"
            printf "${C_GREEN}hysteria2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s&insecure=1#%s${C_RESET}\n" \
                "$H_PW" "$ip" "$H_PORT" "$H_SNI" "$H_OBFS" "$nm"
            ;;
    esac
}

sbx_show_ss() {
    _sbx_any ss || { msg_warn "未安装 SS 节点"; return 0; }
    local f
    for f in "$SBX_ST"/ss-*.env; do [[ -e "$f" ]] || continue; echo; _sbx_show_one "$f"; done
}

# ---- 安装一个 SS 节点 ----
sbx_install_ss() {
    sbx_install_core || return 1
    local port pw method m
    echo " SS 加密方法:"
    echo "  1) 2022-blake3-aes-256-gcm  (默认,推荐)"
    echo "  2) aes-128-gcm              (兼容旧客户端)"
    read -rp "选择 [1]: " m || true
    m=${m:-1}
    case "$m" in
        2) method="aes-128-gcm";             pw=$(openssl rand -base64 16) ;;
        *) method="2022-blake3-aes-256-gcm"; pw=$(openssl rand -base64 32) ;;
    esac
    port=$(_sbx_pick_port)
    printf 'S_PORT=%s\nS_PW=%s\nS_METHOD=%s\n' "$port" "$pw" "$method" > "$SBX_ST/ss-${port}.env"
    chmod 600 "$SBX_ST/ss-${port}.env"
    sbx_render || return 1
    open_firewall_port "$port"
    echo
    _sbx_show_one "$SBX_ST/ss-${port}.env"
}

# ---- 删除某协议的单个节点 ----
_sbx_del_node() {
    local proto="$1" ip f p i=0 dp n
    local -a ports=()
    ip=$(_sbx_ip)
    _sbx_any "$proto" || { msg_warn "无 $proto 节点"; return 0; }
    echo "选择要删除的 ${proto} 节点:"
    for f in "$SBX_ST"/"$proto"-*.env; do
        [[ -e "$f" ]] || continue
        i=$((i + 1)); p=$(basename "$f"); p=${p#"$proto"-}; p=${p%.env}; ports+=("$p")
        printf "  %d) %s  (端口 %s)\n" "$i" "$(_sbx_name_for "$f" "$ip")" "$p"
    done
    read -rp "序号(回车取消): " n || true
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    { [[ "$n" -ge 1 && "$n" -le ${#ports[@]} ]]; } || { msg_warn "无效序号"; return 0; }
    dp="${ports[$((n - 1))]}"
    rm -f "$SBX_ST/${proto}-${dp}.env"
    [[ "$proto" == hy2 ]] && rm -f "$SBX_ST/hy2-${dp}.crt" "$SBX_ST/hy2-${dp}.key"
    [[ "$proto" == socks ]] && _sbx_socks_fw_clear "$dp" 2>/dev/null || true
    _sbx_cn_disable "$dp" 2>/dev/null || true
    close_firewall_port "$dp" 2>/dev/null || true
    sbx_render 2>/dev/null || true
    msg_success "已删除 ${proto} 端口 ${dp}"
}

# ---- SS 管理子菜单 ----
_sbx_manage_ss() {
    while true; do
        clear
        printf "${C_GREEN}== 管理 SS (共 %s 个) ==${C_RESET}\n" "$(_sbx_count ss)"
        systemctl is-active --quiet "$SBX_SVC" 2>/dev/null && msg_success "sing-box 运行中" || msg_warn "sing-box 未运行"
        printf "   CN封禁(分端口) : %b\n" "$(_sbx_cn_summary)"
        printf "   ACL域名封禁(防泄露): %b\n" "$(_sbx_acl_status)"
        echo " 1) 查看所有节点  2) 新增节点  3) 删除某节点"
        echo " 4) 开关CN封禁  5) 更新CN库  6) 开关ACL  7) 加ACL域名  8) 看ACL列表  0) 返回"
        local c
        read -rp "选择: " c || true
        case "$c" in
            1) sbx_show_ss; pause ;;
            2) sbx_install_ss; pause ;;
            3) _sbx_del_node ss; pause ;;
            4) _sbx_cn_toggle; sleep 1.5 ;;
            5) _sbx_cn_update; sleep 1 ;;
            6) _sbx_acl_toggle; sleep 1 ;;
            7) _sbx_acl_add; sleep 1 ;;
            8) _sbx_acl_view ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# SOCKS5：sing-box socks inbound（用户密码）+ iptables 源 IP 白名单（强制层）
# 白名单走每端口独立链 SBX_SK_<port>：放行白名单源 + 默认 DROP；空白名单=全拒绝。
# ==============================================================================
# 应用某端口的源 IP 白名单（IPv4，TCP）。$1=端口，其余=白名单 CIDR/IP（可空）
_sbx_socks_fw_apply() {
    local p="$1"; shift
    local ch="SBX_SK_${p}" c
    iptables -N "$ch" 2>/dev/null || iptables -F "$ch"
    for c in "$@"; do iptables -A "$ch" -s "$c" -j ACCEPT; done
    iptables -A "$ch" -j DROP
    iptables -C INPUT -p tcp --dport "$p" -j "$ch" 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j "$ch"
    _sbx_cn_save
}
# 清除某端口的白名单链
_sbx_socks_fw_clear() {
    local p="$1"; local ch="SBX_SK_${p}"
    iptables -D INPUT -p tcp --dport "$p" -j "$ch" 2>/dev/null || true
    iptables -F "$ch" 2>/dev/null || true
    iptables -X "$ch" 2>/dev/null || true
    _sbx_cn_save
}

# ---- 安装一个 SOCKS5 节点 ----
sbx_install_socks() {
    sbx_install_core || return 1
    local port user pw wl
    echo " SOCKS5 源 IP 白名单（强制层，叠加在用户名/密码之上）"
    echo " 多个用空格或逗号分隔，支持单 IP 或 CIDR，例: 1.2.3.4 10.0.0.0/24"
    read -rp "白名单(留空=该端口拒绝所有连接): " wl || true
    wl=$(echo "$wl" | tr ',' ' ' | xargs 2>/dev/null || true)
    if [[ -z "$wl" ]]; then
        msg_warn "白名单为空——该 SOCKS5 端口将拒绝所有连接（用户密码也连不上）。"
        local _yn; read -rp "仍要继续？y/N: " _yn || true
        [[ "$_yn" =~ ^[Yy]$ ]] || { msg_warn "已取消"; return 0; }
    fi
    port=$(_sbx_pick_port)
    user="u$(openssl rand -hex 3)"
    pw=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
    { printf 'SK_PORT=%s\nSK_USER=%s\nSK_PW=%s\nSK_WL="%s"\n' "$port" "$user" "$pw" "$wl"; } > "$SBX_ST/socks-${port}.env"
    chmod 600 "$SBX_ST/socks-${port}.env"
    sbx_render || return 1
    # shellcheck disable=SC2086
    _sbx_socks_fw_apply "$port" $wl
    echo
    _sbx_show_one "$SBX_ST/socks-${port}.env"
}

sbx_show_socks() {
    _sbx_any socks || { msg_warn "未安装 SOCKS5 节点"; return 0; }
    local f
    for f in "$SBX_ST"/socks-*.env; do [[ -e "$f" ]] || continue; echo; _sbx_show_one "$f"; done
}

# ---- 修改某 SOCKS5 节点的白名单 ----
_sbx_socks_edit_wl() {
    _sbx_any socks || { msg_warn "无 SOCKS5 节点"; return 0; }
    local f i=0 p n wl; local -a ports=()
    echo "选择要改白名单的 SOCKS5 节点:"
    for f in "$SBX_ST"/socks-*.env; do
        [[ -e "$f" ]] || continue
        i=$((i + 1)); p=$(basename "$f"); p=${p#socks-}; p=${p%.env}; ports+=("$p")
        local SK_WL=""; # shellcheck disable=SC1090
        . "$f"
        printf "  %d) 端口 %s  白名单: %s\n" "$i" "$p" "${SK_WL:-（空,全拒绝）}"
    done
    read -rp "序号(回车取消): " n || true
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    { [[ "$n" -ge 1 && "$n" -le ${#ports[@]} ]]; } || { msg_warn "无效序号"; return 0; }
    p="${ports[$((n - 1))]}"
    echo "当前白名单将被覆盖。多个用空格/逗号分隔，留空=该端口拒绝所有。"
    read -rp "新白名单: " wl || true
    wl=$(echo "$wl" | tr ',' ' ' | xargs 2>/dev/null || true)
    local SK_PORT="" SK_USER="" SK_PW=""; # shellcheck disable=SC1090
    . "$SBX_ST/socks-${p}.env"
    { printf 'SK_PORT=%s\nSK_USER=%s\nSK_PW=%s\nSK_WL="%s"\n' "$SK_PORT" "$SK_USER" "$SK_PW" "$wl"; } > "$SBX_ST/socks-${p}.env"
    chmod 600 "$SBX_ST/socks-${p}.env"
    # shellcheck disable=SC2086
    _sbx_socks_fw_apply "$p" $wl
    msg_success "已更新端口 ${p} 白名单"
}

# ---- SOCKS5 管理子菜单 ----
_sbx_manage_socks() {
    while true; do
        clear
        printf "${C_GREEN}== 管理 SOCKS5 (共 %s 个) ==${C_RESET}\n" "$(_sbx_count socks)"
        systemctl is-active --quiet "$SBX_SVC" 2>/dev/null && msg_success "sing-box 运行中" || msg_warn "sing-box 未运行"
        echo " 1) 查看所有节点  2) 新增节点  3) 删除某节点  4) 改白名单  0) 返回"
        local c
        read -rp "选择: " c || true
        case "$c" in
            1) sbx_show_socks; pause ;;
            2) sbx_install_socks; pause ;;
            3) _sbx_del_node socks; pause ;;
            4) _sbx_socks_edit_wl; pause ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# Hysteria2：sing-box hysteria2 inbound（自签 EC 证书 + salamander 混淆，无需域名）
# ==============================================================================
# ---- 安装一个 Hysteria2 节点 ----
sbx_install_hy2() {
    sbx_install_core || return 1
    local port pw obfs up down sni crt key
    sni="www.bing.com"
    read -rp "本机【上行】Mbps (填实际带宽, 如 50): " up || true
    [[ "$up" =~ ^[0-9]+$ ]] || up=50
    read -rp "本机【下行】Mbps (填实际带宽, 如 200): " down || true
    [[ "$down" =~ ^[0-9]+$ ]] || down=200
    port=$(_sbx_pick_port)
    pw=$(openssl rand -base64 16)
    obfs=$(openssl rand -base64 12)
    crt="$SBX_ST/hy2-${port}.crt"; key="$SBX_ST/hy2-${port}.key"
    if ! openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null \
        || ! openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=$sni" 2>/dev/null; then
        msg_error "自签证书生成失败"; rm -f "$key" "$crt"; return 1
    fi
    chmod 600 "$key" "$crt"
    printf 'H_PORT=%s\nH_PW=%s\nH_OBFS=%s\nH_UP=%s\nH_DOWN=%s\nH_SNI=%s\nH_CRT=%s\nH_KEY=%s\n' \
        "$port" "$pw" "$obfs" "$up" "$down" "$sni" "$crt" "$key" > "$SBX_ST/hy2-${port}.env"
    chmod 600 "$SBX_ST/hy2-${port}.env"
    sbx_render || return 1
    open_firewall_port "$port"
    echo
    _sbx_show_one "$SBX_ST/hy2-${port}.env"
}

sbx_show_hy2() {
    _sbx_any hy2 || { msg_warn "未安装 Hysteria2 节点"; return 0; }
    local f
    for f in "$SBX_ST"/hy2-*.env; do [[ -e "$f" ]] || continue; echo; _sbx_show_one "$f"; done
}

# ---- Hysteria2 管理子菜单 ----
_sbx_manage_hy2() {
    while true; do
        clear
        printf "${C_GREEN}== 管理 Hysteria2 (共 %s 个) ==${C_RESET}\n" "$(_sbx_count hy2)"
        systemctl is-active --quiet "$SBX_SVC" 2>/dev/null && msg_success "sing-box 运行中" || msg_warn "sing-box 未运行"
        echo " 1) 查看所有节点  2) 新增节点  3) 删除某节点  0) 返回"
        local c
        read -rp "选择: " c || true
        case "$c" in
            1) sbx_show_hy2; pause ;;
            2) sbx_install_hy2; pause ;;
            3) _sbx_del_node hy2; pause ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ---- 卸载 sing-box（全部协议 + 服务 + 二进制）----
sbx_uninstall() {
    systemctl disable --now "$SBX_SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SBX_SVC}.service"
    local _f _p
    for _f in "$SBX_ST"/ss-*.env "$SBX_ST"/socks-*.env "$SBX_ST"/hy2-*.env; do
        [[ -e "$_f" ]] || continue
        _p=$(basename "$_f"); _p=${_p#*-}; _p=${_p%.env}
        [[ "$(basename "$_f")" == socks-* ]] && _sbx_socks_fw_clear "$_p" 2>/dev/null || true
        _sbx_cn_disable "$_p" 2>/dev/null || true
        close_firewall_port "$_p" 2>/dev/null || true
    done
    rm -rf "$SBX_ETC" "$SBX_ST"
    rm -f "$SBX_BIN"
    systemctl daemon-reload
    msg_success "sing-box 已卸载（服务/配置/节点/二进制已清除）。"
}

# ---- sing-box 顶层入口(主菜单 9) ----
sbx_proxy_menu() {
    if [[ ! -x "$SBX_BIN" ]]; then
        sbx_install_core || { pause; return; }
    fi
    while true; do
        clear
        printf "${C_CYAN}=== sing-box 统一代理 ===${C_RESET}\n"
        systemctl is-active --quiet "$SBX_SVC" 2>/dev/null && msg_success "sing-box 运行中" || msg_warn "sing-box 未运行"
        printf "\n"
        printf " ${C_GREEN}1.${C_RESET} SS / SS2022   (%s 个)\n" "$(_sbx_count ss)"
        printf " ${C_GREEN}2.${C_RESET} SOCKS5        (%s 个)\n" "$(_sbx_count socks)"
        printf " ${C_GREEN}3.${C_RESET} Hysteria2     (%s 个)\n" "$(_sbx_count hy2)"
        printf " ${C_PURPLE}--------------------------------${C_RESET}\n"
        printf " ${C_GREEN}4.${C_RESET} 启停 sing-box\n"
        printf " ${C_GREEN}5.${C_RESET} 查看全部节点配置\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        local c
        read -rp $'\n选择: ' c || true
        case "$c" in
            1) _sbx_manage_ss ;;
            2) _sbx_manage_socks ;;
            3) _sbx_manage_hy2 ;;
            4)
                local s
                read -rp "1)启动 2)停止 3)重启 : " s || true
                case "$s" in
                    1) systemctl start "$SBX_SVC" && msg_success "已启动" || msg_error "启动失败" ;;
                    2) systemctl stop "$SBX_SVC"  && msg_success "已停止" || msg_error "停止失败" ;;
                    3) systemctl restart "$SBX_SVC" && msg_success "已重启" || msg_error "重启失败" ;;
                esac
                pause ;;
            5)
                if _sbx_any ss || _sbx_any socks || _sbx_any hy2; then
                    _sbx_any ss && sbx_show_ss
                    _sbx_any socks && sbx_show_socks
                    _sbx_any hy2 && sbx_show_hy2
                else
                    msg_warn "暂无节点"
                fi
                pause ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# ACL 域名封禁（route reject，仅作用于 SS 入站）—— 替换旧 .acl 版
# ==============================================================================
_sbx_acl_status() {
    if [[ -f "$SBX_ST/acl.enabled" ]]; then
        printf "${C_GREEN}已开启${C_RESET}"
    else
        printf "${C_YELLOW}已关闭${C_RESET}"
    fi
}

_sbx_acl_defaults() {
    cat <<'EOF'
ip138.com
whoer.net
ipinfo.io
ifconfig.me
ifconfig.co
ip-api.com
ipip.net
myip.com
myip.la
ip.sb
ipleak.net
browserleaks.com
dnsleak.com
showmyip.com
whatismyip.com
ping0.cc
ipaddress.com
EOF
}

_sbx_acl_ensure() {
    if [[ ! -f "$SBX_ACL" ]]; then
        mkdir -p "$SBX_ST" 2>/dev/null || true
        _sbx_acl_defaults > "$SBX_ACL"
        chmod 600 "$SBX_ACL"
    fi
}

_sbx_acl_toggle() {
    if ! _sbx_any ss; then msg_error "未安装 sing-box SS 入站，域名封禁仅作用于 SS。"; return 0; fi
    _sbx_acl_ensure
    if [[ -f "$SBX_ST/acl.enabled" ]]; then
        rm -f "$SBX_ST/acl.enabled"; msg_success "已关闭防检测功能（域名封禁）。"
    else
        : > "$SBX_ST/acl.enabled"; msg_success "已开启防检测功能（域名封禁）。"
    fi
    sbx_render || msg_error "sing-box 配置应用失败。"
}

_sbx_acl_add() {
    _sbx_acl_ensure
    printf "${C_CYAN}请输入要屏蔽的域名 (例如 whoer.net；匹配该域名及其子域): ${C_RESET}"
    local entry
    read -r entry || true
    if [[ -z "${entry:-}" ]]; then msg_error "输入不能为空。"; return 0; fi
    if grep -qxF "$entry" "$SBX_ACL"; then msg_warn "'$entry' 已存在。"; return 0; fi
    echo "$entry" >> "$SBX_ACL"
    msg_success "已添加封禁域名: $entry"
    if [[ -f "$SBX_ST/acl.enabled" ]]; then
        sbx_render || msg_error "sing-box 配置应用失败。"
    else
        msg_info "提示: 域名封禁当前处于关闭状态，规则将在开启后生效。"
    fi
}

_sbx_acl_view() {
    _sbx_acl_ensure
    echo "=== 当前屏蔽域名列表 ==="
    cat "$SBX_ACL"
    echo "===================="
    printf "${C_CYAN}按任意键返回...${C_RESET}"
    read -rsn1 || true
}

# ==============================================================================
# CN IP 封禁（分端口 iptables + ipset；周更 timer 为内联 ExecStart，无需子命令）
# ==============================================================================
_sbx_cn_port_on() { iptables -C INPUT -p tcp --dport "$1" -m set --match-set ss_cn_block src -j DROP 2>/dev/null; }
_sbx_cn_blocked() { iptables-save 2>/dev/null | grep 'match-set ss_cn_block src' | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -un || true; }
_sbx_cn_any() { [[ -n "$(_sbx_cn_blocked)" ]]; }
_sbx_cn_save() {
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true
    else mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; fi
}
_sbx_cn_enable() {
    local p="$1"
    ensure_ipset_exists || return 1
    iptables -C INPUT -p tcp --dport "$p" -m set --match-set ss_cn_block src -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -m set --match-set ss_cn_block src -j DROP
    iptables -C INPUT -p udp --dport "$p" -m set --match-set ss_cn_block src -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -m set --match-set ss_cn_block src -j DROP
    _sbx_cn_timer
}
_sbx_cn_disable() {
    local p="$1"
    iptables -D INPUT -p tcp --dport "$p" -m set --match-set ss_cn_block src -j DROP 2>/dev/null || true
    iptables -D INPUT -p udp --dport "$p" -m set --match-set ss_cn_block src -j DROP 2>/dev/null || true
    if ! _sbx_cn_any; then
        systemctl stop ss-cn-update.timer &>/dev/null || true
        systemctl disable ss-cn-update.timer &>/dev/null || true
        rm -f /etc/systemd/system/ss-cn-update.timer /etc/systemd/system/ss-cn-update.service
        systemctl daemon-reload
    fi
}
_sbx_cn_summary() {
    local f p sfx out=""
    for f in "$SBX_ST"/ss-*.env; do
        [[ -e "$f" ]] || continue
        p=$(basename "$f"); p=${p#ss-}; p=${p%.env}; sfx=$(_sbx_env_suffix "$f")
        if _sbx_cn_port_on "$p"; then out+="${C_GREEN}${sfx}:${p}开${C_RESET} "; else out+="${C_YELLOW}${sfx}:${p}关${C_RESET} "; fi
    done
    [[ -z "$out" ]] && out="${C_YELLOW}无SS节点${C_RESET}"
    printf '%b' "$out"
}

_sbx_cn_toggle() {
    _sbx_any ss || { msg_error "未安装 sing-box SS 入站，无法应用 CN 封禁。"; return 0; }
    local ip f p i=0 nm n tp
    local -a ports=()
    ip=$(_sbx_ip)
    echo "SS 节点 CN封禁状态(开=屏蔽中国大陆源IP直连该端口):"
    for f in "$SBX_ST"/ss-*.env; do
        [[ -e "$f" ]] || continue
        p=$(basename "$f"); p=${p#ss-}; p=${p%.env}
        i=$((i + 1)); ports+=("$p"); nm=$(_sbx_name_for "$f" "$ip")
        if _sbx_cn_port_on "$p"; then printf "  %d) %-22s 端口 %-6s ${C_GREEN}[已开·屏蔽国内]${C_RESET}\n" "$i" "$nm" "$p"
        else printf "  %d) %-22s 端口 %-6s ${C_YELLOW}[已关·国内可连]${C_RESET}\n" "$i" "$nm" "$p"; fi
    done
    read -rp "选要【切换】的节点序号(回车取消): " n || true
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    { [[ "$n" -ge 1 && "$n" -le ${#ports[@]} ]]; } || { msg_error "无效序号"; return 0; }
    tp="${ports[$((n - 1))]}"
    if _sbx_cn_port_on "$tp"; then
        _sbx_cn_disable "$tp"; msg_success "端口 ${tp}: 已【关闭】CN封禁(国内现可直连)"
    else
        _sbx_cn_enable "$tp" || return 0; msg_success "端口 ${tp}: 已【开启】CN封禁(已屏蔽国内源IP)"
    fi
    _sbx_cn_save
}

_sbx_cn_update() {
    local set_name="ss_cn_block" temp_set="ss_cn_block_temp"
    local cn_list_url="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    if ! command -v ipset &>/dev/null; then msg_error "未安装 ipset 组件。"; return 1; fi
    msg_step "正在下载最新 CN IP 列表..."
    local temp_list; temp_list=$(mktemp)
    trap "rm -f '$temp_list'" RETURN
    if ! wget -qO "$temp_list" "$cn_list_url" || [[ ! -s "$temp_list" ]]; then
        msg_error "下载失败，现有规则保持不变。"; return 1
    fi
    msg_info "正在原子替换 ipset (不中断现有封禁)..."
    ipset create "$temp_set" hash:net 2>/dev/null || ipset flush "$temp_set"
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$temp_list" | sed -e "s/^/add $temp_set /" | ipset restore -!
    if ipset list "$set_name" &>/dev/null; then
        ipset swap "$temp_set" "$set_name"; ipset destroy "$temp_set"
    else
        ipset rename "$temp_set" "$set_name"
    fi
    msg_success "CN IP 列表已更新（原子替换，规则无中断）。"
}

_sbx_cn_timer() {
    cat > /etc/systemd/system/ss-cn-update.service <<-'EOF'
[Unit]
Description=Update CN IP Block List for sing-box SS
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    set -e; \
    ipset create ss_cn_block_temp hash:net 2>/dev/null || ipset flush ss_cn_block_temp; \
    tmp_list=$(mktemp); \
    trap "rm -f \"$tmp_list\"" EXIT; \
    if wget -qO "$tmp_list" https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt && [ -s "$tmp_list" ]; then \
        grep -E '"'"'^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'"'"' "$tmp_list" | sed "s/^/add ss_cn_block_temp /" | ipset restore -! && \
        ipset swap ss_cn_block_temp ss_cn_block && \
        ipset destroy ss_cn_block_temp; \
    else \
        ipset destroy ss_cn_block_temp 2>/dev/null; \
        echo "cn-ip-update: wget failed, keeping existing ruleset" >&2; \
    fi'
EOF
    cat > /etc/systemd/system/ss-cn-update.timer <<-'EOF'
[Unit]
Description=Weekly Update for CN IP Block List

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ss-cn-update.timer >/dev/null 2>&1 || true
    msg_info "已配置 CN IP 库自动更新任务 (每周一次)。"
}



# ==============================================================================
# SECTION 9: Cloudflare DDNS 模块（来自 DDNS.sh，已适配统一框架）
# ==============================================================================
# 说明：
#   - Cloudflare 专属配置存于 DDNS_CONFIG_FILE，安全 grep 解析（不 source）。
#   - Telegram 通知复用统一基础设施（send_telegram + TG_CONF，菜单选项 3 配置），
#     不再单独保存 Token；机器标识取自 get_node_id（SERVER_NAME / 缓存）。
#   - 全部函数按 set -euo pipefail 编写；systemd 通过子命令 `ddns-run` 调用。

readonly DDNS_STATE_DIR="/var/lib/cf-ddns"
readonly DDNS_CONFIG_FILE="/etc/cf-ddns.conf"
readonly DDNS_LOG_FILE="${DDNS_STATE_DIR}/cf-ddns.log"
readonly DDNS_SOURCE_FILE="${DDNS_STATE_DIR}/last_source.txt"
readonly DDNS_SERVICE_NAME="cf-ddns"
readonly DDNS_SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
readonly DDNS_TIMER_FILE="/etc/systemd/system/cf-ddns.timer"
readonly DDNS_LOG_MAX_LINES=1000
readonly DDNS_LOG_CHECK_INTERVAL=86400

# Cloudflare 配置（由 ddns_load_config 填充）
DDNS_AUTH_TOKEN=""
DDNS_ZONE_NAME=""
DDNS_RECORD_NAME=""
DDNS_INTERVAL_SEC="10"
DDNS_HEALTH_HOUR="20"

ddns_load_config() {
    DDNS_AUTH_TOKEN=""; DDNS_ZONE_NAME=""; DDNS_RECORD_NAME=""
    DDNS_INTERVAL_SEC="10"; DDNS_HEALTH_HOUR="20"
    [[ -f "$DDNS_CONFIG_FILE" ]] || return 0
    local _k _v
    while IFS='=' read -r _k _v; do
        _v="${_v%\"}"; _v="${_v#\"}"   # 去掉可能的成对引号
        case "$_k" in
            auth_token)         DDNS_AUTH_TOKEN="$_v" ;;
            zone_name)          DDNS_ZONE_NAME="$_v" ;;
            record_name)        DDNS_RECORD_NAME="$_v" ;;
            check_interval_sec) [[ "$_v" =~ ^[0-9]+$ ]] && DDNS_INTERVAL_SEC="$_v" ;;
            health_check_hour)  [[ "$_v" =~ ^[0-9]+$ ]] && DDNS_HEALTH_HOUR="$_v" ;;
        esac
    done < "$DDNS_CONFIG_FILE"
    return 0
}

ddns_save_config() {
    local _old_umask; _old_umask=$(umask); umask 177
    cat > "$DDNS_CONFIG_FILE" <<EOF
auth_token="$DDNS_AUTH_TOKEN"
zone_name="$DDNS_ZONE_NAME"
record_name="$DDNS_RECORD_NAME"
check_interval_sec="$DDNS_INTERVAL_SEC"
health_check_hour="$DDNS_HEALTH_HOUR"
EOF
    umask "$_old_umask"
}

ddns_config_complete() {
    [[ -n "$DDNS_AUTH_TOKEN" && -n "$DDNS_ZONE_NAME" && -n "$DDNS_RECORD_NAME" ]]
}

# 载入 DDNS 通知频道，供 send_telegram 使用（无配置则静默不推送）
ddns_load_tg() {
    _tg_resolve_channel ddns
    return 0
}

ddns_ensure_state_dir() {
    mkdir -p "$DDNS_STATE_DIR" 2>/dev/null || { msg_error "无法创建状态目录 $DDNS_STATE_DIR（需 root 权限）"; return 1; }
    chmod 700 "$DDNS_STATE_DIR" 2>/dev/null || true
    return 0
}

ddns_log() {
    local _m; _m="$(date '+%Y-%m-%d %H:%M:%S') $1"
    if [[ -t 1 ]]; then
        echo -e "$_m" | tee -a "$DDNS_LOG_FILE"
    else
        echo -e "$_m" >> "$DDNS_LOG_FILE"
    fi
}

# HTML 转义：CF 接口返回/日志可能含 < > &，HTML 模式下不转义会导致整条消息发不出
ddns_html_escape() {
    local s="$1"
    # 用 \& 转义：bash 5.2+ 默认开启 patsub_replacement，替换串中的 & 会被当作匹配文本
    s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
    printf '%s' "$s"
}

ddns_rotate_logs() {
    local _marker="$DDNS_STATE_DIR/last_rotate_time" _now _last=0 _val
    _now=$(date +%s)
    if [[ -f "$_marker" ]]; then
        _val=$(cat "$_marker" 2>/dev/null || true)
        [[ "$_val" =~ ^[0-9]+$ ]] && _last="$_val"
    fi
    if (( _now - _last > DDNS_LOG_CHECK_INTERVAL )); then
        if [[ -f "$DDNS_LOG_FILE" ]]; then
            local _lines; _lines=$(wc -l < "$DDNS_LOG_FILE" 2>/dev/null || echo 0)
            if (( _lines > DDNS_LOG_MAX_LINES )); then
                local _tmp; _tmp=$(mktemp) || return 0
                tail -n "$DDNS_LOG_MAX_LINES" "$DDNS_LOG_FILE" > "$_tmp"
                mv "$_tmp" "$DDNS_LOG_FILE"
                echo "$(date '+%Y-%m-%d %H:%M:%S') ✂️ [自动清理] 日志已修剪，保留最近 $DDNS_LOG_MAX_LINES 条。" >> "$DDNS_LOG_FILE"
            fi
        fi
        echo "$_now" > "$_marker"
    fi
    return 0
}

# 获取公网 IPv4（多源兜底，快的排前面）
ddns_get_ip() {
    local _ip="" _url
    local _sources=(
        "http://ipv4.icanhazip.com"
        "http://whatismyip.akamai.com"
        "http://checkip.amazonaws.com"
        "http://api.ipify.org"
        "http://ifconfig.me/ip"
    )
    for _url in "${_sources[@]}"; do
        _ip=$(curl -s --max-time 3 "$_url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$_url" > "$DDNS_SOURCE_FILE"
            printf '%s' "$_ip"
            return 0
        fi
    done
    return 1
}

ddns_notify_change() {
    local _old="$1" _new="$2"
    local _title="📢 <b>DDNS IP 变更通知</b>"
    if [[ "$_old" == "FirstRun" ]]; then
        _title="🎉 <b>DDNS 首次配置成功</b>"; _old="无 (首次安装)"
    fi
    local _src="未知"; [[ -f "$DDNS_SOURCE_FILE" ]] && _src=$(cat "$DDNS_SOURCE_FILE" 2>/dev/null || echo "未知")
    local _node; _node=$(get_node_id)
    local _msg
    _msg="${_title}
👤 主机: ${_node}
🌍 域名: <code>${DDNS_RECORD_NAME}</code>
📡 来源: <code>${_src}</code>
🔴 旧 IP: <code>${_old}</code>
🟢 新 IP: <code>${_new}</code>
🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    send_telegram "$_msg" || true
    ddns_log "📨 Telegram 变更通知已发送。"
}

ddns_notify_health() {
    local _ip="$1"
    local _src="未知"; [[ -f "$DDNS_SOURCE_FILE" ]] && _src=$(cat "$DDNS_SOURCE_FILE" 2>/dev/null || echo "未知")
    local _logs="暂无日志"
    [[ -f "$DDNS_LOG_FILE" ]] && _logs=$(ddns_html_escape "$(tail -n 5 "$DDNS_LOG_FILE" 2>/dev/null || true)")
    local _node; _node=$(get_node_id)
    local _msg
    _msg="🟢 <b>DDNS 每日健康检查</b>
👤 主机: ${_node}
✅ 状态: 运行正常
🌍 域名: <code>${DDNS_RECORD_NAME}</code>
📡 来源: <code>${_src}</code>
🔵 当前IP: <code>${_ip}</code>
🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')

📜 <b>近期日志:</b>
<pre>${_logs}</pre>"
    send_telegram "$_msg" || true
    ddns_log "📨 [健康检查] 通知已发送。"
}

# 异常告警（30 分钟冷却，避免单次抖动刷屏）
ddns_notify_error() {
    local _err="$1" _now _last=0 _val
    local _f="$DDNS_STATE_DIR/last_error_time"
    _now=$(date +%s)
    if [[ -f "$_f" ]]; then
        _val=$(cat "$_f" 2>/dev/null || true)
        [[ "$_val" =~ ^[0-9]+$ ]] && _last="$_val"
    fi
    if (( _now - _last > 1800 )); then
        local _node; _node=$(get_node_id)
        local _msg
        _msg="❌ <b>DDNS 运行异常告警</b>
👤 主机: ${_node}
🌍 域名: <code>${DDNS_RECORD_NAME}</code>
⚠️ 错误: $(ddns_html_escape "$_err")
🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')"
        send_telegram "$_msg" || true
        echo "$_now" > "$_f"
        ddns_log "📨 [异常告警] 通知已发送。"
    else
        ddns_log "⚠️ [异常告警] 错误已记录，跳过通知 (30分钟冷却中)。"
    fi
    return 0
}

# 核心检测：$1 = true(交互)/false(systemd)
ddns_run_check() {
    local _interactive="$1"
    ddns_rotate_logs

    local _ip=""
    _ip=$(ddns_get_ip || true)

    # 每日健康推送（仅 systemd 非交互调用）
    if [[ "$_interactive" == "false" ]]; then
        local _hour _tag
        _hour=$(TZ='Asia/Shanghai' date +%H)
        _tag="$DDNS_STATE_DIR/health_$(TZ='Asia/Shanghai' date +%Y%m%d).tag"
        # 算术比较避免 "08" != "8" 陷阱；noclobber 原子占位防并发重复推送
        if (( 10#$_hour == 10#$DDNS_HEALTH_HOUR )) && [[ ! -f "$_tag" ]]; then
            if ( set -o noclobber; : > "$_tag" ) 2>/dev/null; then
                sleep $((RANDOM % 60))
                if [[ -n "$_ip" ]]; then ddns_notify_health "$_ip"; else rm -f "$_tag"; fi
            fi
        fi
    fi

    # 连续失败计数：单次抖动不告警，连续达阈值才推送
    local _fail_file="$DDNS_STATE_DIR/fail_count" _threshold=3
    if [[ -z "$_ip" ]]; then
        local _fc=0
        [[ -f "$_fail_file" ]] && { read -r _fc < "$_fail_file" || true; }
        [[ "$_fc" =~ ^[0-9]+$ ]] || _fc=0
        _fc=$((_fc + 1))
        echo "$_fc" > "$_fail_file"
        local _err="无法获取本机公网 IP，请检查网络连接。"
        ddns_log "❌ 错误：$_err (连续失败 ${_fc}/${_threshold})"
        (( _fc >= _threshold )) && ddns_notify_error "$_err (已连续失败 ${_fc} 次)"
        [[ "$_interactive" == "true" ]] && pause
        return 1
    fi
    [[ -f "$_fail_file" ]] && rm -f "$_fail_file"

    local _cache
    _cache="$DDNS_STATE_DIR/$(printf '%s' "$DDNS_RECORD_NAME" | md5sum | awk '{print $1}').cache"
    local _c_zone="" _c_record="" _c_ip="" _last_check=0 _force_interval=86400
    # 安全解析缓存：逐行 key=value，不 source，避免任意代码以 root 执行
    if [[ -f "$_cache" ]]; then
        local _k _v
        while IFS='=' read -r _k _v; do
            case "$_k" in
                cached_zone_id)   _c_zone="$_v" ;;
                cached_record_id) _c_record="$_v" ;;
                cached_ip)        _c_ip="$_v" ;;
                last_check_time)  [[ "$_v" =~ ^[0-9]+$ ]] && _last_check="$_v" ;;
            esac
        done < "$_cache"
    fi

    local _now; _now=$(date +%s)
    if [[ "$_ip" == "$_c_ip" ]] && (( _now - _last_check < _force_interval )); then
        ddns_log "🔍 [巡检] IP 无变化: $_ip"
        [[ "$_interactive" == "true" ]] && pause
        return 0
    fi
    ddns_log "🔍 [状态变化] Old: ${_c_ip:-None} -> New: $_ip"

    local _zone_id="$_c_zone"
    if [[ -z "$_zone_id" || ${#_zone_id} -le 10 ]]; then
        _zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DDNS_ZONE_NAME}&status=active" \
            -H "Authorization: Bearer ${DDNS_AUTH_TOKEN}" -H "Content-Type: application/json" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null || true)
        if [[ -z "$_zone_id" || "$_zone_id" == "null" ]]; then
            local _err="无法获取 Zone ID。请检查域名配置或 Token 权限。"
            ddns_log "❌ 错误：$_err"; ddns_notify_error "$_err"
            [[ "$_interactive" == "true" ]] && pause
            return 1
        fi
    fi

    local _record_id="$_c_record"
    if [[ -z "$_record_id" || ${#_record_id} -le 10 ]]; then
        _record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${_zone_id}/dns_records?type=A&name=${DDNS_RECORD_NAME}" \
            -H "Authorization: Bearer ${DDNS_AUTH_TOKEN}" -H "Content-Type: application/json" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null || true)
        if [[ -z "$_record_id" || "$_record_id" == "null" ]]; then
            local _err="无法获取 Record ID。请确保 Cloudflare 上已存在该 DNS 记录。"
            ddns_log "❌ 错误：$_err"; ddns_notify_error "$_err"
            [[ "$_interactive" == "true" ]] && pause
            return 1
        fi
    fi

    local _resp
    _resp=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${_zone_id}/dns_records/${_record_id}" \
        -H "Authorization: Bearer ${DDNS_AUTH_TOKEN}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DDNS_RECORD_NAME}\",\"content\":\"${_ip}\",\"ttl\":60,\"proxied\":false}" 2>/dev/null || true)

    if printf '%s' "$_resp" | jq -e '.success' >/dev/null 2>&1; then
        ddns_log "🎉 DDNS 更新成功: $_ip"
        if [[ "$_ip" != "$_c_ip" ]]; then
            local _old_display="${_c_ip:-FirstRun}"
            ddns_notify_change "$_old_display" "$_ip"
            [[ "$_old_display" == "FirstRun" ]] && ddns_notify_health "$_ip"
        fi
        {
            echo "cached_zone_id=$_zone_id"
            echo "cached_record_id=$_record_id"
            echo "cached_ip=$_ip"
            echo "last_check_time=$(date +%s)"
        } > "$_cache"
    else
        ddns_log "❌ 更新失败！${_resp:0:200}"
        ddns_notify_error "更新请求失败，Cloudflare 返回: ${_resp:0:100}..."
        # 保留 cached_ip（避免下次成功误报"首次配置"），仅清空可能失效的 ID 以便重取
        {
            echo "cached_zone_id="
            echo "cached_record_id="
            echo "cached_ip=$_c_ip"
            echo "last_check_time=$_last_check"
        } > "$_cache"
    fi
    [[ "$_interactive" == "true" ]] && pause
    return 0
}

ddns_install_systemd() {
    local _self; _self=$(realpath "$0")
    cat > "$DDNS_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $_self ddns-run
StandardOutput=append:$DDNS_LOG_FILE
StandardError=append:$DDNS_LOG_FILE
EOF
    cat > "$DDNS_TIMER_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS Updater Timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=${DDNS_INTERVAL_SEC}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable "${DDNS_SERVICE_NAME}.timer" 2>/dev/null || true
    if systemctl restart "${DDNS_SERVICE_NAME}.timer"; then
        msg_success "systemd timer 已启动 (每 ${DDNS_INTERVAL_SEC} 秒检测一次)"
    else
        msg_error "启动 systemd timer 失败，请检查: journalctl -u ${DDNS_SERVICE_NAME}.timer"
        return 1
    fi
}

ddns_stop_service() {
    systemctl disable --now "${DDNS_SERVICE_NAME}.timer" 2>/dev/null || true
    msg_success "systemd timer 已停止并禁用。"
}

ddns_uninstall() {
    systemctl disable --now "${DDNS_SERVICE_NAME}.timer"   2>/dev/null || true
    systemctl disable --now "${DDNS_SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$DDNS_SERVICE_FILE" "$DDNS_TIMER_FILE"
    systemctl daemon-reload
    rm -f "$DDNS_CONFIG_FILE"
    rm -rf "$DDNS_STATE_DIR"
    msg_success "DDNS 服务、配置、日志与缓存已全部清除。"
}

ddns_service_status() {
    if systemctl is-active --quiet "${DDNS_SERVICE_NAME}.timer" 2>/dev/null; then
        printf "${C_GREEN}运行中${C_RESET} (每 %ss)" "$DDNS_INTERVAL_SEC"
    else
        printf "${C_RED}未运行${C_RESET}"
    fi
}

ddns_prompt() {
    local _var="$1" _text="$2" _cur="$3" _in
    if [[ -n "$_cur" ]]; then
        read -rp "   $_text [当前: $_cur]: " _in || true
        printf -v "$_var" '%s' "${_in:-$_cur}"
    else
        read -rp "   $_text: " _in || true
        printf -v "$_var" '%s' "$_in"
    fi
}

# 粘贴式快速配置：3 行(子域名 / 主域名 / CF Token，顺序随意)自动识别 + 确认。
# 间隔固定 10s、健康推送固定每日 20 点。成功写入返回 0；放弃返回 1（调用方可回落手动）。
ddns_paste_setup() {
    local _l _tok _zone _sub _rec _blank _cf _zid _d1 _d2
    local -a _lines
    while :; do
        _tok=""; _zone=""; _sub=""; _rec=""
        printf "  ${C_CYAN}📋 粘贴 3 行（顺序随意，自动识别）：${C_RESET}\n"
        printf "     • 子域名        （如 jp1）\n"
        printf "     • 主域名        （如 example.com）\n"
        printf "     • CF API Token  （权限：该 zone 的 DNS→Edit）\n"
        printf "  ${C_YELLOW}支持 # 注释与空行；贴完连按两次回车结束；输入 q 放弃${C_RESET}\n>>> "
        _lines=(); _blank=0
        while [[ ${#_lines[@]} -lt 3 ]]; do
            read -r _l < /dev/tty || break
            _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"
            if [[ -z "$_l" ]]; then
                [[ ${#_lines[@]} -ge 1 ]] && { _blank=$((_blank + 1)); [[ $_blank -ge 2 ]] && break; }
                continue
            fi
            _blank=0
            [[ "$_l" =~ ^# ]] && continue
            [[ "$_l" == "q" || "$_l" == "Q" ]] && { printf "  ${C_YELLOW}⚠ 已放弃${C_RESET}\n"; return 1; }
            _lines+=("$_l")
        done
        # 自动识别：无点长串=Token；带点=主域名或完整记录；无点短串=子域名
        for _l in "${_lines[@]:-}"; do
            [[ -z "$_l" ]] && continue
            if [[ "$_l" != *.* && "$_l" =~ ^[A-Za-z0-9_-]{30,}$ ]]; then
                _tok="$_l"
            elif [[ "$_l" == *.* ]]; then
                if [[ -z "$_zone" ]]; then
                    _zone="$_l"
                else
                    # 两个带点行：点更少的是主域名，另一个当完整记录
                    _d1="${_l//[^.]/}"; _d2="${_zone//[^.]/}"
                    if [[ ${#_d1} -lt ${#_d2} ]]; then _rec="$_zone"; _zone="$_l"; else _rec="$_l"; fi
                fi
            else
                _sub="$_l"
            fi
        done
        [[ -z "$_rec" && -n "$_sub" && -n "$_zone" ]] && _rec="${_sub}.${_zone}"
        [[ -n "$_rec" && -z "$_sub" ]] && _sub="${_rec%%.*}"
        if [[ -z "$_tok" || -z "$_zone" || -z "$_rec" ]]; then
            printf "  ${C_RED}✗ 识别失败：需 子域名 + 主域名 + Token 三项 (tok:%s zone:%s 记录:%s)。请重贴（q 放弃）${C_RESET}\n" \
                "${_tok:+有}" "${_zone:-无}" "${_rec:-无}"; continue
        fi
        # 用 Token 查 zone_id，一并验证 Token 有效 + 对该 zone 有权限
        printf "  正在用 Token 验证主域名 %s ..." "$_zone"
        _zid=$(curl -s --max-time 10 "https://api.cloudflare.com/client/v4/zones?name=${_zone}&status=active" \
            -H "Authorization: Bearer ${_tok}" -H "Content-Type: application/json" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null || true)
        if [[ -z "$_zid" ]]; then
            printf " ${C_RED}✗ 失败（Token 无效 / 无该 zone 权限 / 主域名拼写错误）。请重贴（q 放弃）${C_RESET}\n"; continue
        fi
        printf " ${C_GREEN}✓ zone 验证通过${C_RESET}\n"
        printf "  ${C_CYAN}── 待写入内容（请核对）──${C_RESET}\n"
        printf "  子域名   : ${C_GREEN}%s${C_RESET}\n" "$_sub"
        printf "  完整记录 : ${C_GREEN}%s${C_RESET}  (A/IPv4)\n" "$_rec"
        printf "  主域名   : %s  ${C_GREEN}✓CF验证通过${C_RESET}\n" "$_zone"
        printf "  Token    : %s…（末4 %s）\n" "${_tok:0:8}" "${_tok: -4}"
        printf "  间隔/健康: ${C_CYAN}10s${C_RESET} / 每日 ${C_CYAN}20${C_RESET} 点\n"
        printf "  记录不存在: ${C_CYAN}自动创建${C_RESET}（指向本机当前公网 IP）\n"
        printf "  ${C_YELLOW}确认写入？[y=写入 / q=放弃 / 回车=重新粘贴]: ${C_RESET}"
        read -r _cf < /dev/tty || _cf="q"
        case "$_cf" in
            [Yy]) break ;;
            [Qq]) printf "  ${C_YELLOW}⚠ 已放弃，未写入${C_RESET}\n"; return 1 ;;
            *)    printf "  ${C_CYAN}↻ 重新粘贴${C_RESET}\n"; continue ;;
        esac
    done
    DDNS_AUTH_TOKEN="$_tok"; DDNS_ZONE_NAME="$_zone"; DDNS_RECORD_NAME="$_rec"
    DDNS_INTERVAL_SEC="10"; DDNS_HEALTH_HOUR="20"
    ddns_save_config
    msg_success "配置已保存: $DDNS_CONFIG_FILE"

    # 记录不存在则用 API 自动创建（指向本机当前公网 IP），省去去 CF 手动建
    printf "  正在检查 Cloudflare 上是否已有该 A 记录..."
    local _rid _myip _crt _cferr
    _rid=$(curl -s --max-time 10 "https://api.cloudflare.com/client/v4/zones/${_zid}/dns_records?type=A&name=${_rec}" \
        -H "Authorization: Bearer ${_tok}" -H "Content-Type: application/json" 2>/dev/null \
        | jq -r '.result[0].id // empty' 2>/dev/null || true)
    if [[ -n "$_rid" ]]; then
        printf " ${C_GREEN}✓ 已存在，DDNS 将直接接管更新${C_RESET}\n"
    else
        printf " 不存在，正在创建...\n"
        _myip=$(ddns_get_ip || true)
        if [[ ! "$_myip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            msg_warn "无法获取本机公网 IP，跳过自动创建；首次检测会重试，或请手动在 CF 建记录。"
        else
            _crt=$(curl -s --max-time 10 -X POST "https://api.cloudflare.com/client/v4/zones/${_zid}/dns_records" \
                -H "Authorization: Bearer ${_tok}" -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${_rec}\",\"content\":\"${_myip}\",\"ttl\":60,\"proxied\":false}" 2>/dev/null || true)
            if printf '%s' "$_crt" | jq -e '.success == true' >/dev/null 2>&1; then
                msg_success "已在 Cloudflare 创建 A 记录: ${_rec} → ${_myip}"
            else
                _cferr=$(printf '%s' "$_crt" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null || echo "未知错误")
                msg_warn "自动创建失败（${_cferr}）；DDNS 首次检测会再次尝试，或请手动在 CF 建记录。"
            fi
        fi
    fi
    return 0
}

ddns_setup_wizard() {
    clear
    printf "${C_PURPLE}==============================================${C_RESET}\n"
    printf "${C_CYAN}        Cloudflare DDNS 配置向导${C_RESET}\n"
    printf "${C_PURPLE}==============================================${C_RESET}\n"
    printf "  直接回车 = 保留当前值 / 跳过可选项\n\n"

    printf "${C_BLUE}配置方式：${C_RESET}\n"
    printf "  ${C_GREEN}1.${C_RESET} 📋 粘贴快速配置（子域名/主域名/Token 三行，自动识别）${C_GREEN}[默认]${C_RESET}\n"
    printf "  ${C_GREEN}2.${C_RESET} ⌨️  逐项手动输入\n"
    local _setup_mode; read -rp "  请选择 [1]: " _setup_mode < /dev/tty || true
    if [[ "${_setup_mode:-1}" != "2" ]]; then
        ddns_paste_setup && return
        printf "  ${C_CYAN}↩ 转为逐项手动输入${C_RESET}\n\n"
    fi

    printf "${C_BLUE}【Cloudflare 设置】${C_RESET}\n"
    printf "   API Token: 控制台 -> My Profile -> API Tokens\n"
    ddns_prompt DDNS_AUTH_TOKEN "API Token (必填)" "$DDNS_AUTH_TOKEN"
    printf "\n   主域名 (Zone)，例如: example.com\n"
    ddns_prompt DDNS_ZONE_NAME "主域名 (必填)" "$DDNS_ZONE_NAME"
    printf "\n   DNS 记录全名，例如: ddns.example.com\n"
    ddns_prompt DDNS_RECORD_NAME "DNS 记录名 (必填)" "$DDNS_RECORD_NAME"

    printf "\n${C_BLUE}【检测间隔】${C_RESET} 单位秒，IP 变化时约等于最大断网时长，推荐 10，最小 5\n"
    local _sec="$DDNS_INTERVAL_SEC"
    ddns_prompt _sec "检测间隔 (秒)" "$DDNS_INTERVAL_SEC"
    if [[ "$_sec" =~ ^[0-9]+$ ]] && (( _sec >= 5 )); then
        DDNS_INTERVAL_SEC="$_sec"
    else
        printf "   ${C_YELLOW}⚠️  输入无效（需 ≥ 5），保留原值: ${DDNS_INTERVAL_SEC}s${C_RESET}\n"
    fi

    printf "\n${C_DIM}提示: Telegram 通知复用统一配置（主菜单选项 3），机器名取自 SERVER_NAME。${C_RESET}\n"

    printf "\n${C_PURPLE}==============================================${C_RESET}\n"
    printf "配置摘要:\n"
    printf "  CF Token : %s...\n" "${DDNS_AUTH_TOKEN:0:12}"
    printf "  主域名   : %s\n" "$DDNS_ZONE_NAME"
    printf "  DNS 记录 : %s (A/IPv4)\n" "$DDNS_RECORD_NAME"
    printf "  检测间隔 : %s 秒\n" "$DDNS_INTERVAL_SEC"
    printf "${C_PURPLE}==============================================${C_RESET}\n\n"
    local _c
    read -rp "✅ 确认保存配置? [Y/n]: " _c || true
    if [[ "${_c,,}" != "n" ]]; then
        ddns_save_config
        msg_success "配置已保存: $DDNS_CONFIG_FILE"
    else
        msg_warn "已取消，配置未保存。"
    fi
}

ddns_show_menu() {
    clear
    local _logn=0
    [[ -f "$DDNS_LOG_FILE" ]] && _logn=$(wc -l < "$DDNS_LOG_FILE" 2>/dev/null || echo 0)
    printf "${C_PURPLE}==============================================${C_RESET}\n"
    printf "${C_CYAN}         Cloudflare DDNS 管理面板${C_RESET}\n"
    printf "${C_PURPLE}==============================================${C_RESET}\n"
    printf "  机器名称 : %s\n" "$(get_node_id plain)"
    printf "  DNS 记录 : %s (A/IPv4)\n" "${DDNS_RECORD_NAME:-未配置}"
    printf "  服务状态 : %b\n" "$(ddns_service_status)"
    printf "  日志行数 : %s / %s\n" "$_logn" "$DDNS_LOG_MAX_LINES"
    printf "${C_PURPLE}==============================================${C_RESET}\n\n"
    printf " ${C_GREEN}1.${C_RESET} 🚀 启动/重启服务\n"
    printf " ${C_GREEN}2.${C_RESET} 🔄 立即运行检测\n"
    printf " ${C_GREEN}3.${C_RESET} 📜 查看实时日志\n"
    printf " ${C_GREEN}4.${C_RESET} ⚙️  重新配置\n"
    printf " ${C_GREEN}5.${C_RESET} ⏸️  停止服务\n"
    printf " ${C_GREEN}6.${C_RESET} 🗑️  卸载/清除配置\n"
    printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n\n"
    printf "${C_CYAN}请选择 [0-6]: ${C_RESET}"
}

# DDNS 交互入口（由主菜单调用，0 返回主菜单）
ddns_menu() {
    ddns_load_config
    ddns_ensure_state_dir || { pause; return; }
    ddns_load_tg

    # 未配置 → 引导：向导 → 首次检测 → 启动服务（顺序不可颠倒，避免与 timer 并发重复推送）
    if ! ddns_config_complete; then
        printf "\n${C_YELLOW}未检测到有效 DDNS 配置，进入配置向导...${C_RESET}\n"
        sleep 1
        ddns_setup_wizard
        ddns_load_config
        if ! ddns_config_complete; then
            msg_warn "配置未完成。"; pause; return
        fi
        printf "\n🚀 正在运行首次检测...\n"
        ddns_run_check "true"
        printf "🚀 正在启动 DDNS 服务...\n"
        ddns_install_systemd || pause
    fi

    while true; do
        ddns_show_menu
        local _choice
        read -r _choice || true
        printf "\n"
        case "$_choice" in
            "") continue ;;
            1) if ddns_install_systemd; then ddns_run_check "true"; else pause; fi ;;
            2) printf "🚀 正在强制运行检测...\n"; ddns_run_check "true" ;;
            3)
                [[ -f "$DDNS_LOG_FILE" ]] || touch "$DDNS_LOG_FILE"
                printf "--- 实时日志 (%s) ---\n" "$DDNS_LOG_FILE"
                printf "${C_YELLOW}按任意键停止监视并返回...${C_RESET}\n"
                tail -f -n 20 "$DDNS_LOG_FILE" &
                local _tp=$!
                read -rsn1
                kill "$_tp" 2>/dev/null || true
                wait "$_tp" 2>/dev/null || true
                ;;
            4)
                ddns_setup_wizard
                ddns_load_config
                if systemctl is-active --quiet "${DDNS_SERVICE_NAME}.timer" 2>/dev/null; then
                    ddns_install_systemd && msg_success "服务已按新配置重启。"
                fi
                pause
                ;;
            5) ddns_stop_service; pause ;;
            6)
                local _cc
                read -rp "⚠️  确认卸载并清除所有 DDNS 配置? [y/N]: " _cc || true
                if [[ "${_cc,,}" == "y" ]]; then
                    ddns_uninstall; pause; return
                else
                    printf "已取消。\n"; sleep 1
                fi
                ;;
            0) return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ==============================================================================
# SECTION 8: 统一主菜单 + 主循环
# ==============================================================================

show_menu() {
    local flag
    flag=$(get_flag_emoji "$SERVER_COUNTRY_CODE")
    local _CFG_SEP="${C_PURPLE}----------------------------------------------------------------${C_RESET}"

    clear
    printf '%b\n' "${C_PURPLE}================================================================${C_RESET}"
    printf '%b\n' "${C_CYAN}    System Guardian  ${C_BLUE}&${C_CYAN} VPS Manager  ${C_YELLOW}v${SCRIPT_VERSION}${C_RESET}"
    printf '%b\n' "${C_PURPLE}================================================================${C_RESET}"

    local _srv_name=""
    [[ -f "${TG_CONF:-}" ]] && _srv_name=$(grep -E '^SERVER_NAME=' "$TG_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    printf "${C_BLUE}:: 服务器信息 ::${C_RESET}\n"
    if [[ -n "$_srv_name" ]]; then
        printf "   服务器: %s\n" "$(_srv_render "$_srv_name")"
    else
        printf "   服务器: %s %s, %s\n" "$flag" "$SERVER_COUNTRY_NAME" "$SERVER_CITY"
    fi
    printf "   IP    : %s\n" "$SERVER_IP"
    printf "${C_BLUE}:: 服务状态 ::${C_RESET}\n"
    # ---------- 版本信息与升级提示 ----------
    local snell_status snell_ver snell_new ss_status ss_ver ss_new realm_status realm_ver realm_new
    snell_status=$(check_service_status snell "$SNELL_BIN")
    ss_status=$(check_service_status sing-box "$SBX_BIN")
    realm_status=$(check_service_status realm "$REALM_BIN")

    # 版本号 (仅已安装时读取)
    if [[ -f "$SNELL_BIN" ]]; then
        snell_ver=$(get_installed_version snell "$SNELL_BIN")
        snell_new=$(get_cached_latest_version snell)
    else
        snell_ver="-"; snell_new=""
    fi
    if [[ -x "$SBX_BIN" ]]; then
        ss_ver=$("$SBX_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1 || true)
        [[ -z "$ss_ver" ]] && ss_ver="-"
        ss_new=""
    else
        ss_ver="-"; ss_new=""
    fi
    if [[ -f "$REALM_BIN" ]]; then
        realm_ver=$(get_installed_version realm "$REALM_BIN")
        realm_new=$(get_cached_latest_version realm)
    else
        realm_ver="-"; realm_new=""
    fi

    # 输出行 (含版本号与可选升级提示)
    local snell_ver_str ss_ver_str realm_ver_str
    if [[ -n "$snell_new" && "$snell_new" != "$snell_ver" ]]; then
        snell_ver_str="${C_YELLOW}${snell_ver}${C_RESET} ${C_RED}→ 可升级 ${snell_new}${C_RESET}"
    else
        snell_ver_str="${C_CYAN}${snell_ver}${C_RESET}"
    fi
    if [[ -n "$ss_new" && "$ss_new" != "$ss_ver" ]]; then
        ss_ver_str="${C_YELLOW}${ss_ver}${C_RESET} ${C_RED}→ 可升级 ${ss_new}${C_RESET}"
    else
        ss_ver_str="${C_CYAN}${ss_ver}${C_RESET}"
    fi
    if [[ -n "$realm_new" && "$realm_new" != "$realm_ver" ]]; then
        realm_ver_str="${C_YELLOW}${realm_ver}${C_RESET} ${C_RED}→ 可升级 ${realm_new}${C_RESET}"
    else
        realm_ver_str="${C_CYAN}${realm_ver}${C_RESET}"
    fi


    # Fail2Ban
    if systemctl is-active --quiet fail2ban 2>/dev/null && [[ -f /etc/fail2ban/jail.d/sshd.conf ]]; then
        local _fb_banned; _fb_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "?")
        printf "   Fail2Ban         : %b  [%b]\n" "${C_GREEN}运行中${C_RESET}" "${C_CYAN}封禁 ${_fb_banned}${C_RESET}"
    else
        printf "   Fail2Ban         : [-]\n"
    fi
    # TG 推送
    if [[ -f "$TG_CONF" ]] && grep -q "^TG_BOT_TOKEN=" "$TG_CONF" 2>/dev/null; then
        local _tg_srv; _tg_srv=$(grep "^SERVER_NAME=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
        printf "   TG 推送          : %b  [%b]\n" "${C_GREEN}已配置${C_RESET}" "${C_CYAN}${_tg_srv:-主频道}${C_RESET}"
    else
        printf "   TG 推送          : [-]\n"
    fi
    # TCPing Monitor
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _tp_port; _tp_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        printf "   TCPing Monitor   : %b  [%b]\n" "${C_GREEN}运行中${C_RESET}" "${C_CYAN}${SERVER_IP}:${_tp_port}${C_RESET}"
    else
        printf "   TCPing Monitor   : [-]\n"
    fi
    # Cloudflare DDNS
    if systemctl is-active --quiet "${DDNS_SERVICE_NAME}.timer" 2>/dev/null; then
        local _ddns_rec; _ddns_rec=$(grep -E '^record_name=' "$DDNS_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || echo "")
        printf "   Cloudflare DDNS  : %b  [%b]\n" "${C_GREEN}运行中${C_RESET}" "${C_CYAN}${_ddns_rec:-?}${C_RESET}"
    else
        printf "   Cloudflare DDNS  : [-]\n"
    fi
    # 代理服务
    if [[ -f "$SNELL_BIN" ]]; then
        printf "   Snell            : %b  [%b]\n" "$snell_status" "$snell_ver_str"
    else
        printf "   Snell            : [-]\n"
    fi
    if [[ -x "$SBX_BIN" ]]; then
        printf "   sing-box 代理     : %b  [%b]\n" "$ss_status" "$ss_ver_str"
        printf "        节点         : ${C_CYAN}SS:%s SOCKS5:%s Hy2:%s${C_RESET}\n" "$(_sbx_count ss)" "$(_sbx_count socks)" "$(_sbx_count hy2)"
    else
        printf "   sing-box 代理     : [-]\n"
    fi
    if [[ -f "$REALM_BIN" ]]; then
        printf "   Realm Forwarding : %b  [%b]" "$realm_status" "$realm_ver_str"
        _realm_config_stale && printf "  ${C_RED}⚠ 配置已改，未重启生效${C_RESET}"
        printf "\n"
    else
        printf "   Realm Forwarding : [-]\n"
    fi

    # ---------- 防火墙状态 ----------
    printf "${C_BLUE}:: 防火墙 & 内核 ::${C_RESET}\n"
    if ! command -v iptables &>/dev/null; then
        printf "   ${C_RED}iptables 未安装${C_RESET}\n"
    else
        local _fw_policy _fw_rules _fw_svc _fw_cn_block _fw_acl ir policy
        local _ipt_l_out
        _ipt_l_out=$(iptables -L INPUT -n 2>/dev/null || echo "")
        ir=$(iptables -S INPUT 2>/dev/null || echo "")
        _fw_policy=$(echo "$_ipt_l_out" | head -1 | awk '{print $4}' | tr -d '()' || echo "N/A")
        policy="$_fw_policy"
        [[ -n "$_fw_policy" ]] || { _fw_policy="N/A"; policy="N/A"; }
        _fw_rules=$(echo "$ir" | grep -c '^-A' || true)
        # 服务状态：有规则或模块已加载即视为运行
        if lsmod 2>/dev/null | grep -q ip_tables || [[ "$_fw_rules" -gt 0 ]]; then
            _fw_svc="${C_GREEN}RUNNING${C_RESET}"
        else
            _fw_svc="${C_RED}STOPPED${C_RESET}"
        fi
        # 策略颜色：DROP=绿（安全），ACCEPT=红（全开放）
        local _policy_color="${C_GREEN}"
        [[ "$_fw_policy" != "DROP" ]] && _policy_color="${C_RED}"
        # CN 封禁状态
        if iptables-save 2>/dev/null | grep -q "match-set ss_cn_block src"; then
            _fw_cn_block="${C_GREEN}CN封禁:开${C_RESET}"
        else
            _fw_cn_block="${C_YELLOW}CN封禁:关${C_RESET}"
        fi
        # ACL 状态（sing-box route reject 域名封禁）
        if [[ -f "$SBX_ST/acl.enabled" ]]; then
            _fw_acl="${C_GREEN}域名封禁:开${C_RESET}"
        else
            _fw_acl="${C_YELLOW}域名封禁:关${C_RESET}"
        fi
        printf "   %b防火墙%b %b   %b策略%b %b%s%b   %b规则%b %b%s条%b   %b  %b\n" \
            "${C_BLUE}" "${C_RESET}" "$_fw_svc" \
            "${C_BLUE}" "${C_RESET}" "$_policy_color" "$_fw_policy" "${C_RESET}" \
            "${C_BLUE}" "${C_RESET}" "${C_GREEN}" "$_fw_rules" "${C_RESET}" \
            "$_fw_cn_block" "$_fw_acl"
        # BBR / 内核
        local _kver _bv _bbr_label _kcolor
        _kver=$(uname -r)
        _bv=$(_get_bbr_version)
        if [[ "$_bv" == "v3" ]]; then
            uname -r | grep -qi "xanmod" && _kcolor="${C_GREEN}" || _kcolor="${C_WHITE}"
            _bbr_label="${_kcolor}BBR v3${C_RESET}"
        elif [[ "$_bv" == "v1" ]]; then
            _kcolor="${C_YELLOW}"
            _bbr_label="${C_YELLOW}BBR v1${C_RESET}"
        else
            _kcolor="${C_RED}"
            _bbr_label="${C_RED}无BBR${C_RESET}"
        fi
        printf "   %b内  核%b  %b%s%b   %b\n" "${C_BLUE}" "${C_RESET}" "$_kcolor" "$_kver" "${C_RESET}" "$_bbr_label"
        # 端口状态 (SSH/HTTP/HTTPS + 其他开放端口)
        local _ssh_port
        _ssh_port=$(get_current_ssh_port 2>/dev/null || echo "22")
        printf "   %b端  口%b" "${C_BLUE}" "${C_RESET}"
        _port_dot "$_ssh_port" "SSH"
        printf "\n"
        if [[ "$policy" != "ACCEPT" ]]; then
            local _raw_ports _display_ports=()
            _raw_ports=$(echo "$ir" | grep -E '^-A INPUT.*-j ACCEPT' | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -nu || true)
            for _p in $_raw_ports; do
                [[ "$_p" == "$_ssh_port" ]] && continue
                _display_ports+=("$_p")
            done
            if [[ ${#_display_ports[@]} -gt 0 ]]; then
                printf "          "
                local _col=0
                for _p in "${_display_ports[@]}"; do
                    local _ht=0 _hu=0 _pa=""
                    echo "$ir" | grep -q -- "-p tcp.*--dport $_p.*-j ACCEPT" && _ht=1
                    echo "$ir" | grep -q -- "-p udp.*--dport $_p.*-j ACCEPT" && _hu=1
                    [[ $_ht -eq 1 && $_hu -eq 1 ]] && _pa="${C_CYAN}t${C_RESET}${C_WHITE}/${C_RESET}${C_PURPLE}u${C_RESET}"
                    [[ $_ht -eq 1 && $_hu -eq 0 ]] && _pa="${C_CYAN}t${C_RESET}"
                    [[ $_ht -eq 0 && $_hu -eq 1 ]] && _pa="${C_PURPLE}u${C_RESET}"
                    [[ -n "$_pa" ]] && printf "${C_GREEN}%s${C_WHITE}(${C_RESET}%b${C_WHITE})${C_RESET}  " "$_p" "$_pa"
                    _col=$(( _col + 1 ))
                    if [[ $(( _col % 4 )) -eq 0 && $_col -lt ${#_display_ports[@]} ]]; then
                        printf "\n          "
                    fi
                done
                printf "\n"
            fi
        else
            printf "          %b全端口开放 (ACCEPT策略)%b\n" "${C_GREEN}" "${C_RESET}"
        fi
    fi
    
    local connection_stats
    connection_stats=$(get_connection_stats)
    local total_conns=${connection_stats%%:*}
    local conn_details=${connection_stats#*:}
    
    if [[ $total_conns -gt 0 ]]; then
        printf "   ${C_GREEN}活跃连接: %d${C_RESET}\n" "$total_conns"
        if [[ -n "$conn_details" ]]; then
            printf "   ${C_YELLOW}详情: %s${C_RESET}\n" "$conn_details"
        fi
    else
        printf "   ${C_RED}活跃连接: 0${C_RESET}\n"
    fi
    # 测试模式 iperf3 命令提示
    if echo "${_ipt_l_out:-}" | grep -q "test-mode-iperf" 2>/dev/null; then
        local _my_ip_m _close_hint=""
        _my_ip_m=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
        local _jf="/var/run/iptables-iperf-mode.job"
        if [[ -f "$_jf" ]]; then
            local _jid _jtime
            _jid=$(cat "$_jf" 2>/dev/null || true)
            _jtime=$(atq 2>/dev/null | grep "^${_jid}[[:space:]]" | awk '{print $3,$4,$5}' || true)
            [[ -n "$_jtime" ]] && _close_hint="  ${C_YELLOW}(自动关闭: ${_jtime})${C_RESET}"
        fi
        printf "   ${C_CYAN}本机:${C_RESET} iperf3 -s%b\n" "$_close_hint"
        [[ -n "$_my_ip_m" ]] && printf "   ${C_CYAN}对端:${C_RESET} iperf3 -c %s -P 1 -t 20 -R\n" "$_my_ip_m"
    fi

    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f -print -quit 2>/dev/null | grep -q .; then
        local short_suffix
        short_suffix="_$(echo "$SERVER_IP" | cut -d. -f4)"
        local _node_idx=0
        while IFS=' ' read -r s_port s_psk; do
            [[ -z "$s_port" || -z "$s_psk" ]] && continue
            if [[ $_node_idx -eq 0 ]]; then
                printf "${C_PURPLE}================================================================${C_RESET}\n"
                printf "${C_BLUE}:: Snell 配置 ::${C_RESET}\n"
            fi
            _node_idx=$((_node_idx + 1))
            local _sfx="${short_suffix}"
            [[ $_node_idx -gt 1 ]] && _sfx="${short_suffix}-${_node_idx}"
            printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" \
                "$flag" "$_sfx" "$SERVER_IP" "$s_port" "$s_psk"
        done < <(parse_snell_nodes)
    fi

    if _sbx_any ss || _sbx_any socks || _sbx_any hy2; then
        printf "%b\n" "$_CFG_SEP"
        printf "${C_BLUE}:: sing-box 节点配置 ::${C_RESET}\n"
        local _sbf
        for _sbf in "$SBX_ST"/ss-*.env "$SBX_ST"/socks-*.env "$SBX_ST"/hy2-*.env; do
            [[ -e "$_sbf" ]] || continue
            _sbx_show_one "$_sbf"
        done
    fi

    if [[ -f "$REALM_CONFIG_FILE" ]] && validate_realm_config "$REALM_CONFIG_FILE"; then
         if jq -e '.endpoints | length > 0' "$REALM_CONFIG_FILE" >/dev/null; then
            printf "%b\n" "$_CFG_SEP"
            printf "${C_BLUE}:: Realm 转发配置 (Smart) ::${C_RESET}\n"
            # 读取所有 listen 端口
            jq -r '.endpoints[] | "\(.listen) \(.remote)"' "$REALM_CONFIG_FILE" | while read -r listen remote; do
                local l_port
                l_port=$(echo "$listen" | cut -d: -f2)
                local r_addr="$remote"
                local psk=""
                local alias=""
                local country_code=""
                
                # 尝试从 metadata 读取 PSK
                if [[ -f "$REALM_META_FILE" ]]; then
                    psk=$(jq -r --arg p "$l_port" '.[$p].psk // empty' "$REALM_META_FILE")
                    alias=$(jq -r --arg p "$l_port" '.[$p].alias // empty' "$REALM_META_FILE")
                    country_code=$(jq -r --arg p "$l_port" '.[$p].country_code // empty' "$REALM_META_FILE")
                fi
                
                # 确定显示的国旗 (优先使用目标落地机的国旗)
                local display_flag=""
                if [[ -n "$country_code" ]]; then
                    display_flag=$(get_flag_emoji "$country_code")
                else
                    # 如果元数据里没有目标国别，尝试用别名里的信息猜一下? 
                    # 算了，猜不准，回退到地球仪或者不显示，别显示本地旗帜误导
                    display_flag="🌐"
                fi

                if [[ -n "$psk" ]]; then
                    # 显示为 Snell 配置格式
                    local final_name
                    local r_ip
                    r_ip=$(echo "$r_addr" | cut -d: -f1)

                    # 对于Realm链式转发，直接显示存储的完整递归别名，不再做任何画蛇添足的处理
                    final_name="${alias}"
                    
                    # 如果别名为空 (极少数情况)，兜底显示
                    if [[ -z "$final_name" ]]; then
                         final_name="Relay-${SERVER_COUNTRY_CODE}->[${r_ip}]"
                    fi
                    
                    
                    
                    # 在菜单显示时，不再强制加国旗前缀(应包含在 final_name 里了)，但为了对齐好看，如果是新格式则不加
                    # 如果 name 已经包含 emoji (判断 ->), 则 display_flag 置空，否则保留
                    if [[ "$final_name" == *"->"* ]] || [[ "$final_name" == *" → "* ]]; then
                         display_flag="" 
                    fi

                    printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" \
                        "$display_flag" "$final_name" "$SERVER_IP" "$l_port" "$psk"
                else
                    # 无元数据，显示普通转发信息
                    printf "${C_YELLOW}Port %s -> %s${C_RESET}\n" "$l_port" "$r_addr"
                fi
            done
         fi
    fi



    # ── 系统管理区 ────────────────────────────────────────────────
    # 动态状态
    local _tm_label="切换测试模式"
    { [ -f "/var/run/iptables-test-mode.job" ] || [ -f "/var/run/iptables-iperf-mode.job" ]; } && \
        _tm_label="${C_GREEN}● 测试模式 ON${C_RESET}  (再按4关闭)"





    local _snell_label _realm_label _ss_label
    [[ -f "$SNELL_BIN" ]]        && _snell_label="管理 Snell"      || _snell_label="安装 Snell"
    [[ -f "$REALM_BIN" ]]        && _realm_label="管理 Realm"      || _realm_label="安装 Realm"
    [[ -x "$SBX_BIN"   ]]        && _ss_label="管理 sing-box"     || _ss_label="安装 sing-box"

    # 更新提示（Snell/Realm 走缓存版本比对；sing-box 通过更新菜单手动检查）
    local _any_upd_hint="" snell_ver realm_ver
    snell_ver=$(get_installed_version snell "$SNELL_BIN" 2>/dev/null || true)
    realm_ver=$(get_installed_version realm "$REALM_BIN" 2>/dev/null || true)
    local _upd_snell _upd_realm
    _upd_snell=$(get_cached_latest_version snell 2>/dev/null || true)
    _upd_realm=$(get_cached_latest_version realm 2>/dev/null || true)
    { [[ -n "$_upd_snell" && "$_upd_snell" != "$snell_ver" ]] || \
      [[ -n "$_upd_realm" && "$_upd_realm" != "$realm_ver" ]]; } && \
        _any_upd_hint=" ${C_RED}[有更新可用]${C_RESET}"

    printf "${C_PURPLE}================================================================${C_RESET}\n"
    printf " ${C_BLUE}[ 系统管理 ]${C_RESET}\n"
    printf " ${C_YELLOW}★${C_RESET} ${C_GREEN}1.${C_RESET} 一键初始化"; printf "\033[43G"; printf "${C_GREEN}4.${C_RESET} %b\n" "$_tm_label"
    printf "    ${C_GREEN}2.${C_RESET} Fail2Ban                           ${C_GREEN}5.${C_RESET} 防火墙规则\n"
    printf "    ${C_GREEN}3.${C_RESET} TG 推送配置                        ${C_GREEN}6.${C_RESET} 系统维护\n"
    printf "${C_PURPLE}----------------------------------------------------------------${C_RESET}\n"
    printf " ${C_BLUE}[ 代理服务 ]${C_RESET}                         ${C_BLUE}[ 规则与转发 ]${C_RESET}\n"
    printf "  ${C_GREEN}7.${C_RESET} %-38s ${C_GREEN}11.${C_RESET} 重启 Realm\n" "$_snell_label"
    printf "  ${C_GREEN}8.${C_RESET} %-38s ${C_GREEN}12.${C_RESET} 检测并删除失效规则\n" "$_realm_label"
    printf "  ${C_GREEN}9.${C_RESET} %-38s ${C_GREEN}13.${C_RESET} 流量配额与到期管理\n" "$_ss_label"
    printf " ${C_GREEN}10.${C_RESET} %-38s ${C_GREEN}14.${C_RESET} 查看运行状态日志\n" "添加转发规则"
    printf "${C_PURPLE}----------------------------------------------------------------${C_RESET}\n"
    printf " ${C_BLUE}[ 进阶控制 ]${C_RESET}\n"
    printf " ${C_GREEN}15.${C_RESET} 启停服务\n"
    printf " ${C_GREEN}16.${C_RESET} 更新服务 (Snell/sing-box/Realm)%b\n" "$_any_upd_hint"
    printf " ${C_GREEN}17.${C_RESET} 卸载服务 (Snell/sing-box/Realm)\n"
    printf " ${C_GREEN}18.${C_RESET} Cloudflare DDNS\n"
    printf "${C_PURPLE}================================================================${C_RESET}\n"
    printf " ${C_GREEN}0.${C_RESET} 退出脚本\n"
    if [[ ! -f "$UPDATE_CHECK_CACHE" ]]; then
        printf "${C_YELLOW}  ⏳ 版本检测首次运行中（后台进行），直接回车可刷新菜单查看升级提示${C_RESET}\n"
    fi
    printf "\n${C_PURPLE}请输入选项 [0-19]: ${C_RESET}"
}


main_loop() {
    while true; do
        _G_BBR_VER=""
        show_menu
        read -r choice
        printf "\n"
        case $choice in
            # ── 系统管理 ──────────────────────────────────────────
            1) do_quick_init; pause ;;
            2) do_ssh_security ;;
            3) _do_tg_config ;;
            4)
                local mk_ping="/var/run/iptables-test-mode.job"
                local mk_iperf="/var/run/iptables-iperf-mode.job"
                if [ -f "$mk_ping" ] || [ -f "$mk_iperf" ]; then
                    [ -f "$mk_ping"  ] && { atrm "$(cat "$mk_ping")"  2>/dev/null || true; rm -f "$mk_ping"; }
                    [ -f "$mk_iperf" ] && { atrm "$(cat "$mk_iperf")" 2>/dev/null || true; rm -f "$mk_iperf"; }
                    iptables -D INPUT -p icmp -m comment --comment "test-mode-icmp"  -j ACCEPT 2>/dev/null || true
                    iptables -D INPUT -p tcp  --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || true
                    iptables -D INPUT -p udp  --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || true
                    conntrack -D -p icmp >/dev/null 2>&1 || true
                    _persist_iptables
                    echo -e "${GREEN}测试模式已关闭${NC}"
                else
                    iptables -I INPUT 1 -p icmp -m comment --comment "test-mode-icmp" -j ACCEPT
                    iptables -C INPUT -p tcp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || \
                        iptables -I INPUT 1 -p tcp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT
                    iptables -C INPUT -p udp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || \
                        iptables -I INPUT 1 -p udp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT
                    local sc
                    sc=$(mktemp /root/.iptfw-testmode-XXXXXX)
                    printf '%s\n' \
                        "iptables -D INPUT -p icmp -m comment --comment 'test-mode-icmp' -j ACCEPT 2>/dev/null || true" \
                        "iptables -D INPUT -p tcp --dport 5201 -m comment --comment 'test-mode-iperf' -j ACCEPT 2>/dev/null || true" \
                        "iptables -D INPUT -p udp --dport 5201 -m comment --comment 'test-mode-iperf' -j ACCEPT 2>/dev/null || true" \
                        "conntrack -D -p icmp >/dev/null 2>&1 || true" \
                        "_f=/etc/iptables/rules.v4; [ -f /etc/redhat-release ] && _f=/etc/sysconfig/iptables; mkdir -p \$(dirname \$_f); iptables-save > \$_f" \
                        "command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1; command -v service >/dev/null && [ -f /etc/sysconfig/iptables ] && service iptables save >/dev/null 2>&1; true" \
                        "rm -f \"${mk_ping}\" \"${mk_iperf}\" \"${sc}\"" > "$sc"
                    local jid _at_out2 _at_ok=1
                    _at_out2=$(echo "bash $sc" | at now + 2 hours 2>&1) || _at_ok=0
                    jid=$(echo "$_at_out2" | grep -oP 'job \K[0-9]+' || echo "")
                    if [ -z "$jid" ] || [ "$_at_ok" -eq 0 ]; then
                        echo -e "${YELLOW}警告: atd 调度失败，测试模式已开启但不会自动关闭${NC}"
                        rm -f "$sc"; echo "" > "$mk_ping"; echo "" > "$mk_iperf"
                    else
                        echo "$jid" > "$mk_ping"; cp "$mk_ping" "$mk_iperf"
                        local my_ip; my_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
                        echo -e "${GREEN}测试模式已开启 (2h 后自动关闭)${NC}"
                        echo -e "  Ping  : 已放行 ICMP"
                        echo -e "  iperf3: ${CYAN}iperf3 -s${NC}  ← 手动在本机运行，Ctrl+C 即停"
                        echo -e "  对端  : ${CYAN}iperf3 -c ${my_ip} -P 1 -t 20 -R${NC}"
                    fi
                fi
                ;;
            5) sys_firewall_menu ;;
            6) sys_maintenance_menu ;;
            # ── 代理服务 ──────────────────────────────────────────
            7)
                if [[ -f "$SNELL_BIN" ]]; then _snell_manage_menu
                else install_snell || true; fi
                ;;
            8)
                if [[ -f "$REALM_BIN" ]]; then manage_realm_menu
                else install_realm || true; fi
                ;;
            9) sbx_proxy_menu ;;
            10) add_realm_forward_advanced || true ;;
            11) manage_services "restart" "realm" ;;
            12) check_realm_dead_forwards || true ;;
            13) manage_quota_menu ;;
            14)
                while true; do
                    clear
                    printf "${C_CYAN}=== 查看运行状态日志 ===${C_RESET}\n\n"
                    printf " ${C_GREEN}1.${C_RESET} 静态日志 (最后50行)\n"
                    printf " ${C_GREEN}2.${C_RESET} 实时日志 (任意键退出)\n"
                    printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
                    printf "\n${C_CYAN}请选择 [0-2]: ${C_RESET}"
                    read -r log_opt
                    printf "\n"
                    case $log_opt in
                        2)
                            journalctl -u 'snell@*.service' -u sing-box.service -u realm.service -f &
                            PID=$!
                            read -n 1 -s -r -p "按任意键退出实时日志..."
                            kill "$PID" 2>/dev/null || true
                            wait "$PID" 2>/dev/null || true ;;
                        1)
                            journalctl -u 'snell@*.service' -u sing-box.service -u realm.service -n 50 --no-pager
                            printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                    esac
                done
                ;;
            15)
                while true; do
                    clear
                    printf "${C_CYAN}=== 启停服务 ===${C_RESET}\n\n"
                    printf " ${C_GREEN}1.${C_RESET} 启动所有服务\n"
                    printf " ${C_GREEN}2.${C_RESET} 停止所有服务\n"
                    printf " ${C_GREEN}3.${C_RESET} 重启所有服务\n"
                    printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
                    printf "\n${C_CYAN}请选择 [0-3]: ${C_RESET}"
                    read -r svc_sub
                    printf "\n"
                    case $svc_sub in
                        1) manage_services "start"   "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        2) manage_services "stop"    "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        3) manage_services "restart" "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                    esac
                done
                ;;
            16) _do_update_menu ;;
            17) _do_uninstall_menu ;;
            18) ddns_menu ;;
            0)  cleanup; exit 0 ;;
            "") continue ;;
            *) msg_error "无效选项，请重试。" ;;
        esac
        printf "\n${C_GREEN}按任意键返回主菜单...${C_RESET}"; read -rsn1
    done
}

main() {
    # daemon/daily/quota-* 子命令通常由 systemd 以 root 自动触发；手动以非 root 运行会在
    # iptables / 写系统文件处报错，这里提前给出友好提示而非让其半路失败。
    case "${1:-}" in
        daemon|daily|quota-check|quota-daily|ddns-run)
            if [[ $EUID -ne 0 ]]; then
                echo "错误: '$1' 子命令需要 root 权限（一般由 systemd 自动调用）。请用 sudo 运行。" >&2
                exit 1
            fi ;;
    esac

    case "${1:-}" in
        auto-update)
            command -v curl >/dev/null 2>&1 \
                || { echo "auto-update 缺少 curl" >&2; exit 1; }
            self_update auto; return ;;
        quota-check)
            command -v iptables >/dev/null 2>&1 \
                || { echo "quota-check 模式缺少 iptables" >&2; exit 1; }
            quota_check_all; return ;;
        quota-daily)
            command -v curl >/dev/null 2>&1 \
                || { echo "quota-daily 模式缺少 curl" >&2; exit 1; }
            quota_daily_report; return ;;
        ddns-run)
            command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
                || { echo "ddns-run 模式缺少依赖 (curl/jq)" >&2; exit 1; }
            ddns_ensure_state_dir || exit 1
            ddns_load_config
            if ! ddns_config_complete; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ DDNS 配置不完整，请先在菜单选项 18 完成配置。" >> "$DDNS_LOG_FILE" 2>/dev/null || true
                exit 1
            fi
            ddns_load_tg
            ddns_run_check "false"
            return ;;
    esac

    check_root
    acquire_lock
    check_system
    get_server_info
    check_updates_background
    main_loop
    msg_info "脚本已退出。"
}

main "$@"
