#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-parity.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-parity.* ]] && rm -rf "$test_dir"' EXIT
# All generated configs, services and state stay in this disposable directory.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" \
    -e "s|/usr/local/|$test_dir/usr/local/|g" \
    -e "s|/usr/share/keyrings/|$test_dir/keyrings/|g" \
    -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e 's|/dev/tty|/dev/null|g' "$repo_dir/vps-mgr.sh")
mkdir -p "$SBX_ST" "$REALM_CONFIG_DIR" "$QUOTA_DIR" "$test_dir/etc/systemd/system" \
    "$test_dir/usr/local/bin" "$test_dir/usr/local/lib" "$test_dir/etc/exim4/conf.d/main" \
    "$test_dir/etc/network/if-up.d" "$test_dir/etc/networkd-dispatcher/routable.d" \
    "$test_dir/etc/NetworkManager/dispatcher.d" "$test_dir/keyrings" \
    "$test_dir/etc/apt/sources.list.d" "$test_dir/etc/default"
touch "$test_dir/keyrings/xanmod-archive-keyring.gpg" "$test_dir/etc/default/grub"
log_message() { :; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
_state_locked() { "$@"; }
realpath() { printf '%s/vps-mgr.sh\n' "$repo_dir"; }
_fw_ensure() { :; }
_fw_apply() { tee "$test_dir/batch" >/dev/null; }
quota_remove_counting_rules() { :; }
_fw_element() { :; }
close_firewall_port() { :; }
_realm_safe_restart() { :; }
_quota_tg_notify() { :; }
chown() { :; }

# Client names keep country flags and distinct protocol/port suffixes.
printf 'S_METHOD=2022-blake3-aes-256-gcm\n' > "$SBX_ST/ss-24073.env"
printf 'SERVER_NAME=Chi_ATT\n' > "$TG_CONF"
SERVER_COUNTRY_CODE=US
assert test "$(_sbx_name_for "$SBX_ST/ss-24073.env" 192.0.2.1)" = '🇺🇸_Chi_ATT-ss2022-24073'
printf 'SERVER_NAME=🇯🇵_MyNode\n' > "$TG_CONF"
assert test "$(_sbx_name_for "$SBX_ST/ss-24073.env" 192.0.2.1)" = '🇯🇵_MyNode-ss2022-24073'

# Expiry cleanup removes only the selected Realm metadata and warning markers.
printf '{"endpoints":[{"listen":"0.0.0.0:24080","remote":"192.0.2.1:80"},{"listen":"0.0.0.0:24081","remote":"192.0.2.1:81"}]}' > "$REALM_CONFIG_FILE"
printf '{"24080":{"alias":"old"},"24081":{"alias":"keep"}}' > "$REALM_META_FILE"
printf '24080|old|100|-|0\n24081|keep|100|-|0\n' > "$QUOTA_CONFIG"
printf '24080|2026-10|0|0|0|0|1|expired\n' > "$QUOTA_DATA"
touch "$QUOTA_DIR/.warned_24080_2026-10" "$QUOTA_DIR/.expwarn_24080_2026-10-01" "$QUOTA_DIR/.warned_24081_2026-10"
_quota_auto_delete 24080 old
assert test "$(jq '.endpoints|length' "$REALM_CONFIG_FILE")" = 1
assert test "$(jq 'has("24080")' "$REALM_META_FILE")" = false
assert test "$(jq -r '.["24081"].alias' "$REALM_META_FILE")" = keep
assert test ! -e "$QUOTA_DIR/.warned_24080_2026-10"
assert test ! -e "$QUOTA_DIR/.expwarn_24080_2026-10-01"
assert test -e "$QUOTA_DIR/.warned_24081_2026-10"

systemctl() {
    record "systemctl $*"
    case "$1" in
        is-active)
            case "${*: -1}" in
                tcping-monitor) [[ -f "$test_dir/tcping-active" ]] ;;
                exim4) [[ -f "$test_dir/exim-active" ]] ;;
                *) return 0 ;;
            esac ;;
        is-failed) return 1 ;;
        is-enabled) [[ ${*: -1} != tcping-monitor || -f "$test_dir/tcping-enabled" ]] ;;
        enable)
            [[ " $* " == *' --quiet '* ]] || printf 'Created symlink (test service)\n' >&2
            [[ $2 != tcping-monitor ]] || touch "$test_dir/tcping-enabled" ;;
        disable) [[ $2 != tcping-monitor ]] || rm -f "$test_dir/tcping-enabled" ;;
        restart)
            if [[ $2 == tcping-monitor ]]; then
                if [[ ${fail_tcping:-0} == 1 ]] && grep -q 'LISTEN:10001,' "$test_dir/etc/systemd/system/tcping-monitor.service"; then return 1; fi
                touch "$test_dir/tcping-active"
            fi ;;
        stop) [[ $2 != tcping-monitor ]] || rm -f "$test_dir/tcping-active" ;;
    esac
}
id() { return 0; }
socat() { :; }
ss() {
    # -H -ltun uses the fifth field for the local endpoint.
    if [[ $* != *sport* || $* == *:9999* ]] && [[ ${busy9999:-0} == 1 ]]; then
        printf 'tcp LISTEN 0 128 0.0.0.0:9999 0.0.0.0:*\n'
    fi
    return 0
}
SERVER_IP=192.0.2.1
_tcping_setup_silent
assert test "$(_tg_cfg_get "$TCPING_CONFIG_FILE" PORT)" = 9999
assert grep -q 'tcping_ports { 9999 }' "$test_dir/batch"
rm -f "$test_dir/tcping-active" "$TCPING_CONFIG_FILE"
busy9999=1
_tcping_setup_silent
assert test "$(_tg_cfg_get "$TCPING_CONFIG_FILE" PORT)" = 10000
before=$(sha256sum "$test_dir/etc/systemd/system/tcping-monitor.service")
_tcping_setup_silent # active: no replacement/restart, including custom ports
assert test "$before" = "$(sha256sum "$test_dir/etc/systemd/system/tcping-monitor.service")"
if _tcping_setup_silent 9999; then echo 'Busy manual port accepted'; exit 1; fi
assert test "$(_tg_cfg_get "$TCPING_CONFIG_FILE" PORT)" = 10000
fail_tcping=1
if _tcping_setup_silent 10001; then echo 'Failed TCPing startup reported success'; exit 1; fi
assert test "$before" = "$(sha256sum "$test_dir/etc/systemd/system/tcping-monitor.service")"
assert test "$(_tg_cfg_get "$TCPING_CONFIG_FILE" PORT)" = 10000
assert test -f "$test_dir/tcping-active"
fail_tcping=0

# Native fq boot/network hooks and the stable-only daily updater.
_persist_fq 80
for hook in "$test_dir/etc/network/if-up.d/vps-mgr-fq" "$test_dir/etc/networkd-dispatcher/routable.d/vps-mgr-fq" "$test_dir/etc/NetworkManager/dispatcher.d/90-vps-mgr-fq"; do
    assert test -x "$hook"
    assert grep -q 'systemctl start --no-block vps-mgr-fq.service' "$hook"
    sh -n "$hook"
done
install_autoupdate
assert grep -q '05:00:00 Asia/Shanghai' "$test_dir/etc/systemd/system/vps-mgr-autoupdate.timer"
declare -f get_latest_github_release | grep -q '/releases/latest'
declare -f sbx_install_core | grep -q 'LimitNOFILE=1000000'
(
    systemctl() {
        if [[ $1 == enable ]]; then echo 'simulated service enable error' >&2; return 1; fi
    }
    if output=$(install_autoupdate 2>&1); then echo 'Failed timer enable hidden'; exit 1; fi
    [[ $output == *'simulated service enable error'* ]] || { echo 'Service error output hidden'; exit 1; }
)

# Exim changes are reversible, idempotent, preserve custom macros and roll back.
update-exim4.conf() {
    [[ -n ${VPS_MGR_REAL_EXIM:-} ]] || return 0
    {
        printf 'primary_hostname = test.invalid\nexim_user = 65534\nexim_group = 65534\n'
        if [[ $(_tg_cfg_get "$test_dir/etc/exim4/update-exim4.conf.conf" dc_use_split_config) == true ]]; then
            [[ ! -f "$test_dir/etc/exim4/conf.d/main/00_vps_mgr_ipv4" ]] || cat "$test_dir/etc/exim4/conf.d/main/00_vps_mgr_ipv4"
        else
            [[ ! -f "$test_dir/etc/exim4/exim4.conf.localmacros" ]] || cat "$test_dir/etc/exim4/exim4.conf.localmacros"
        fi
    } > "$test_dir/exim.check.conf"
}
exim4() {
    [[ ${fail_exim:-0} == 0 ]] || return 1
    [[ -z ${VPS_MGR_REAL_EXIM:-} ]] || "$VPS_MGR_REAL_EXIM" -C "$test_dir/exim.check.conf" "$@"
}
printf "dc_use_split_config='false'\n" > "$test_dir/etc/exim4/update-exim4.conf.conf"
printf 'MY_CUSTOM_MACRO = keep\n' > "$test_dir/etc/exim4/exim4.conf.localmacros"
_exim_ipv6_compat
_exim_ipv6_compat
if [[ -n ${VPS_MGR_REAL_EXIM:-} ]]; then assert test "$(exim4 -bP disable_ipv6)" = disable_ipv6; fi
assert test "$(grep -c '^disable_ipv6 = true' "$test_dir/etc/exim4/exim4.conf.localmacros")" = 1
_exim_ipv6_compat enable
if [[ -n ${VPS_MGR_REAL_EXIM:-} ]]; then assert test "$(exim4 -bP disable_ipv6)" = no_disable_ipv6; fi
assert grep -qx 'MY_CUSTOM_MACRO = keep' "$test_dir/etc/exim4/exim4.conf.localmacros"
before=$(sha256sum "$test_dir/etc/exim4/exim4.conf.localmacros")
fail_exim=1
if _exim_ipv6_compat; then echo 'Invalid Exim config accepted'; exit 1; fi
assert test "$before" = "$(sha256sum "$test_dir/etc/exim4/exim4.conf.localmacros")"
fail_exim=0
printf "dc_use_split_config='true'\n" > "$test_dir/etc/exim4/update-exim4.conf.conf"
_exim_ipv6_compat
assert grep -q '^disable_ipv6 = true' "$test_dir/etc/exim4/conf.d/main/00_vps_mgr_ipv4"
if [[ -n ${VPS_MGR_REAL_EXIM:-} ]]; then assert test "$(exim4 -bP disable_ipv6)" = disable_ipv6; fi
_exim_ipv6_compat enable
assert test ! -s "$test_dir/etc/exim4/conf.d/main/00_vps_mgr_ipv4"

# Execute the real generated monitor with fake journal/TG endpoints: startup,
# IPv6 login, HTML escaping and management-IP tags must all survive generation.
_tg_permissions() { :; }
printf 'TG_BOT_TOKEN=123:test-token\nTG_CHAT_ID=-100123\nTG_THREAD_SSH=8\nSERVER_NAME=Chi_ATT\n' > "$TG_CONF"
printf 'SERVER_COUNTRY_CODE=US\n' > "$CACHE_FILE"
mkdir -p "$(dirname "$F2B_WHITELIST")"
printf '192.0.2.2\n' > "$F2B_WHITELIST"
curl() {
    [[ $* != *test-token* ]] || { echo 'Token leaked into curl argv' >&2; return 1; }
    record "curl $*"
    [[ $* != *'--config -'* ]] || cat >> "$test_dir/calls"
    printf '{"ok":true}\n'
}
journalctl() {
    printf '%s\n' 'Accepted publickey for admin<& from 2001:db8::2 port 1234 ssh2' \
        'Failed password for invalid user test from 192.0.2.2 port 1234 ssh2'
}
export test_dir
export -f curl journalctl record
_setup_ssh_tg_monitor
bash "$SSH_TG_SCRIPT"
assert grep -q '#SSH监控已启动' "$test_dir/calls"
assert grep -q '🇺🇸 #Chi_ATT' "$test_dir/calls"
assert grep -q '用户: admin&lt;&amp;' "$test_dir/calls"
assert grep -q '来源: <code>2001:db8::2</code>' "$test_dir/calls"
assert grep -q '来源: <code>192.0.2.2</code> → #管理IP' "$test_dir/calls"
assert grep -q 'message_thread_id=8' "$test_dir/calls"
assert test "$(printf 'SSH-BRUTE: IN=eth0\nVPS-DROP: IN=eth0\nnot-a-firewall-log\n' | _filter_fw_logs | wc -l)" = 2

# Exercise both real initialization paths with only OS operations stubbed.
# The container must reach TG/Fail2Ban/TCPing/updater even if sysctl is denied.
assert test "$(declare -f _do_full_init | grep -c '立即重启？')" = 1
assert test "$(declare -f _do_full_init | grep -c 'echo.*重启.*BBR')" = 1
for environment in vps cf google blank invalid timeout unlocked dns_fail container partial kernel_v2 kernel_v3 kernel_v1 kernel_fail kernel_grub_fail; do
(
    : > "$test_dir/calls"
    rm -f "$TG_CONF"
    printf 'nameserver 192.0.2.53\n' > "$test_dir/etc/resolv.conf"
    _is_container() { [[ $environment == container ]]; }
    check_system() { :; }
    clear() { :; }
    check_package_manager_lock() { :; }
    show_spinner() { :; }
    apt-get() { record "apt-get $*"; [[ $environment != kernel_fail || $* != *linux-xanmod* ]]; }
    apt-cache() { :; }
    dpkg-query() { printf 'install ok installed'; }
    _write_disable_ipv6_conf() { record ipv6; [[ $environment != container ]]; }
    _exim_ipv6_compat() { :; }
    get_public_ip() { echo 192.0.2.1; }
    get_geo_info() { :; }
    setup_log_rotation() { record logs; }
    curl() { echo Asia/Shanghai; }
    timedatectl() { echo NTPSynchronized=yes; }
    crontab() { return 1; }
    chattr() { [[ $environment != unlocked || $1 != +i ]]; }
    mountpoint() { [[ $environment == container ]]; }
    read() {
        if [[ ${*: -1} == _dns_choice ]]; then
            assert test "$*" = '-r -t 3 _dns_choice'
            record dns
            case $environment in
                cf) _dns_choice=1 ;;
                google) _dns_choice=2 ;;
                blank) _dns_choice="" ;;
                invalid) _dns_choice=wrong ;;
                timeout) _dns_choice=2; return 142 ;;
                *) builtin read "$@"; return ;;
            esac
            return 0
        fi
        builtin read "$@"
    }
    uname() { case "$1" in -m) echo x86_64 ;; -r) if [[ $environment == kernel_* ]]; then echo 6.12.0; else echo 7.2-xanmod; fi ;; esac; }
    _xanmod_cpu_level() { case $environment in kernel_v1) echo 1 ;; kernel_v2) echo 2 ;; *) echo 3 ;; esac; }
    lsb_release() { echo bookworm; }
    update-grub() { [[ $environment != kernel_grub_fail ]]; }
    reboot() { record reboot; }
    _ensure_swap() { record swap; }
    _effective_mem_mb() { echo 1024; }
    _measure_bandwidth() { _BW_MBPS=1000; }
    modprobe() { :; }
    sysctl() { :; }
    _write_sysctl_conf() { record sysctl; }
    _apply_tuning_sysctl() { :; }
    _install_security_updates() { record security-updates; }
    _apply_nofile_limits() { record nofile; }
    _apply_journald_limits() { record journald; }
    ip() { echo 'default via 192.0.2.254 dev test0'; }
    _apply_fq() { record fq; [[ $environment != partial ]]; }
    _get_bbr_version() { echo v3; }
    do_init_firewall() { record firewall; }
    _tg_input_tokens() { record telegram; [[ $environment != partial ]]; }
    _install_fail2ban() { record fail2ban; [[ $environment != partial ]]; }
    _tcping_setup_silent() { record tcping; [[ $environment != partial ]]; }
    if [[ $environment == partial ]]; then
        install_autoupdate() { echo 'simulated updater error' >&2; return 1; }
    fi
    if [[ $environment == dns_fail ]]; then
        printf() {
            [[ $1 != 'nameserver %s\nnameserver %s\noptions timeout:2 attempts:2\n' ]] || return 1
            builtin printf "$@"
        }
        if do_quick_init </dev/null > "$test_dir/init-$environment.log" 2>&1; then
            echo 'Failed DNS write reported success'; exit 1
        fi
        assert grep -q 'DNS 写入失败' "$test_dir/init-$environment.log"
        if grep -qx firewall "$test_dir/calls"; then echo 'Initialization continued after DNS failure'; exit 1; fi
        exit 0
    fi
    do_quick_init </dev/null > "$test_dir/init-$environment.log" 2>&1
    if [[ $environment == container ]]; then
        assert test "$(cat "$test_dir/etc/resolv.conf")" = 'nameserver 192.0.2.53'
        if grep -qx dns "$test_dir/calls"; then echo 'Managed container DNS prompted'; exit 1; fi
    else
        assert grep -qx dns "$test_dir/calls"
        assert grep -Fq '[1] Cloudflare  1.1.1.1 / 1.0.0.1（默认）' "$test_dir/init-$environment.log"
        assert grep -Fq '[2] Google      8.8.8.8 / 8.8.4.4' "$test_dir/init-$environment.log"
        dns_provider=Cloudflare
        dns_expected=$'nameserver 1.1.1.1\nnameserver 1.0.0.1\noptions timeout:2 attempts:2'
        if [[ $environment == google ]]; then
            dns_provider=Google
            dns_expected=$'nameserver 8.8.8.8\nnameserver 8.8.4.4\noptions timeout:2 attempts:2'
        fi
        assert test "$(cat "$test_dir/etc/resolv.conf")" = "$dns_expected"
        if [[ $environment == invalid ]]; then
            assert grep -q '无效选择，使用默认 Cloudflare DNS' "$test_dir/init-$environment.log"
        fi
        if [[ $environment == unlocked ]]; then
            assert grep -q 'DNS 已设置为 Cloudflare.*文件未锁定' "$test_dir/init-$environment.log"
            if grep -q 'DNS:.*已锁定' "$test_dir/init-$environment.log"; then echo 'DNS lock failure hidden'; exit 1; fi
        else
            assert grep -q "DNS: $dns_provider.*已锁定" "$test_dir/init-$environment.log"
        fi
        do_check_all > "$test_dir/dns-check.log" 2>&1 || true
        assert grep -Fq "DNS 已配置（$dns_provider:" "$test_dir/dns-check.log"
        if [[ $environment == cf ]]; then
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 94.140.14.14\n' > "$test_dir/etc/resolv.conf"
            do_check_all > "$test_dir/dns-check.log" 2>&1 || true
            assert grep -q 'DNS 已配置（旧版混合 DNS）' "$test_dir/dns-check.log"
            printf '# nameserver 8.8.8.8\n# nameserver 8.8.4.4\nnameserver 192.0.2.53\n' > "$test_dir/etc/resolv.conf"
            do_check_all > "$test_dir/dns-check.log" 2>&1 || true
            assert grep -q 'DNS 配置未匹配 Google / Cloudflare' "$test_dir/dns-check.log"
        fi
    fi
    for feature in ipv6 logs nofile journald firewall telegram fail2ban tcping security-updates; do
        assert grep -qx "$feature" "$test_dir/calls"
    done
    for step in {1..8}; do
        assert test "$(grep -Fc "[$step/8]" "$test_dir/init-$environment.log")" = 1
    done
    assert test "$(grep -c '初始化结束' "$test_dir/init-$environment.log")" = 1
    assert test "$(grep -c '代理任选' "$test_dir/init-$environment.log")" = 1
    if grep -Eq '初始化汇总|Created symlink|── \[\+\]|✓ 端口速度:|✓ 角色:' "$test_dir/init-$environment.log"; then
        echo 'Repeated initialization output'; exit 1
    fi
    if [[ $environment == partial ]]; then
        assert grep -q '未完成 / 已跳过：.*网络调优.*TG 推送.*Fail2Ban.*TCPing.*每日更新' "$test_dir/init-$environment.log"
        assert grep -q 'simulated updater error' "$test_dir/init-$environment.log"
        assert grep -q 'fq 调优或持久化未完成' "$test_dir/init-$environment.log"
        if grep -q 'fq 已保存\|每日更新已启用' "$test_dir/init-$environment.log"; then
            echo 'Failed initialization reported success'; exit 1
        fi
    else
        assert grep -q 'enable --now vps-mgr-autoupdate.timer --quiet' "$test_dir/calls"
        assert test "$(grep -c '每日更新已启用' "$test_dir/init-$environment.log")" = 1
    fi
    if [[ $environment == container ]]; then
        if grep -qxE 'sysctl|fq' "$test_dir/calls"; then echo 'Container changed host tuning'; exit 1; fi
        assert grep -q 'IPv6.*未禁用' "$test_dir/init-$environment.log"
    elif [[ $environment == vps ]]; then
        assert grep -qx fq "$test_dir/calls"
        assert test "$(grep -c 'fq 已保存' "$test_dir/init-$environment.log")" = 1
        if grep -q '未完成 / 已跳过' "$test_dir/init-$environment.log"; then echo 'Successful initialization marked incomplete'; exit 1; fi
    fi
    case $environment in
        kernel_v2|kernel_v3)
            assert grep -qx "apt-get install -y -qq linux-xanmod-x64${environment#kernel_}" "$test_dir/calls"
            assert grep -qx reboot "$test_dir/calls" ;;
        kernel_v1|kernel_fail|kernel_grub_fail)
            if grep -qx reboot "$test_dir/calls"; then echo 'Skipped/failed kernel triggered reboot'; exit 1; fi
            if [[ $environment != kernel_v1 ]]; then assert grep -q '未完成 / 已跳过：.*XanMod' "$test_dir/init-$environment.log"; fi ;;
    esac
)
done
# Keep the SSH policy and ban count, not the verbose Fail2Ban status tree.
(
    mkdir -p "$test_dir/etc/fail2ban/jail.d"
    touch "$test_dir/etc/fail2ban/action.d/nftables-multiport.conf"
    get_current_ssh_port() { echo 26680; }
    _f2b_apply_all_nft() { :; }
    _harden_sshd() { :; }
    sleep() { :; }
    fail2ban-client() {
        if [[ $1 == -t ]]; then echo 'OK: configuration test is successful'
        else printf 'Status for the jail: sshd\nCurrently banned: 2\n'; fi
    }
    output=$(_install_fail2ban 2>&1)
    [[ $output == *'已封禁 2 IP'* && $output == *'永久封禁  端口: 26680'* ]] || exit 1
    [[ $output != *'Status for the jail:'* && $output != *'配置 Fail2Ban...'* ]] || exit 1
    fail2ban-client() { echo 'simulated Fail2Ban configuration error' >&2; return 1; }
    if output=$(_install_fail2ban 2>&1); then echo 'Invalid Fail2Ban config accepted'; exit 1; fi
    [[ $output == *'simulated Fail2Ban configuration error'* ]] || exit 1
)
(
    journalctl() { sleep 20; }
    export -f journalctl _fw_logs_menu _run_live_log _filter_fw_logs
    for mode in 2 3; do
        timeout 3 bash -c '_fw_logs_menu' <<< "$mode"$'\nx' >/dev/null
    done
)
printf 'PASS: old-feature parity (names, cleanup, TCPing, init paths, updater, fq hooks, Exim and generated notifications)\n'
