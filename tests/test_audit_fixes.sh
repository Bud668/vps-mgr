#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-audit-tests.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-audit-tests.* ]] && rm -rf "$test_dir"' EXIT
# All writable paths are redirected. OS/service/network operations are stubs.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/usr/local/|$test_dir/usr/local/|g" \
    -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e "s|/var/run/|$test_dir/var-run/|g" -e "s|/run/|$test_dir/run/|g" \
    -e "s|/proc/meminfo|$test_dir/meminfo|g" -e "s|/proc/cpuinfo|$test_dir/cpuinfo|g" \
    -e "s|/swapfile|$test_dir/swapfile|g" -e 's|/dev/tty|/dev/stdin|g' "$repo_dir/vps-mgr.sh")
mkdir -p "$SNELL_CONFIG_DIR" "$REALM_CONFIG_DIR" "$SBX_ST" "$SBX_ETC" "$QUOTA_DIR" \
    "$test_dir/etc/fail2ban" "$test_dir/etc/systemd/system" "$test_dir/usr/local/bin" \
    "$test_dir/etc/sysctl.d" "$test_dir/etc/modules-load.d" "$test_dir/var-run" "$test_dir/run"
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
log_message() { :; }
clear() { :; }
pause() { :; }
sleep() { :; }
chown() { :; }
systemctl() { record "systemctl $*"; }
_state_locked() { "$@"; }
_fw_ensure() { :; }
_fw_has_element() { return 1; }
_fw_element() { record "element $*"; }
_fw_persist() { :; }
open_firewall_port() { record "open $*"; }
close_firewall_port() { record "close $*"; }
quota_remove_counting_rules() { record "uncount $*"; }
_quota_tg_notify() { :; }
get_node_id() { echo 'test-node'; }
ss() { :; }
apt-get() { echo 'FAIL: unexpected apt operation' >&2; return 99; }
curl() { echo 'FAIL: unexpected network operation' >&2; return 99; }

# 1/6: invalid input must not become a real expiry/zero-byte quota; mawk is used
# by Debian's matrix job (optional old binary for local reproduction).
(
    if [[ -n ${VPS_MGR_TEST_AWK:-} ]]; then awk() { "$VPS_MGR_TEST_AWK" "$@"; }; fi
    for pair in 100G:107374182400 1T:1099511627776 1.5GB:1610612736 500MiB:524288000 0:0 1024:1024; do
        assert test "$(_qhuman_to_bytes "${pair%:*}")" = "${pair#*:}"
    done
    for bad in '' garbage -1 1GBjunk 1.2.3G 999999999999999T 0.1B; do reject _qhuman_to_bytes "$bad"; done
)
assert test "$(_quota_expiry_date 2028-2-29)" = 2028-02-29
assert test "$(_quota_expiry_date -)" = -
for bad in '' tomorrow 2026-02-30 2027-2-29 2026-13-1 2026-0-1 2026-1-32; do reject _quota_expiry_date "$bad"; done
printf '24080|invalid|100|2000-02-30|0\n' > "$QUOTA_CONFIG"
printf '24080|2026-01|0|0|0|0|1|expiry\n' > "$QUOTA_DATA"
before=$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA")
(
    quota_init() { :; }
    _quota_commit_port() { echo 'FAIL: invalid date reached quota accounting' >&2; return 99; }
    quota_pause_port() { return 99; }
    _quota_auto_delete() { return 99; }
    quota_check_all
    quota_check_all
)
reject _quota_write_config 24080 test 0 2026-02-30 0
assert test "$before" = "$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA")"
(
    quota_init() { :; }
    reject quota_set_port <<< $'24080\ntest\n100G\n2026-02-30'
)

# 2: each manual delete/uninstall entry point clears only its own quota state.
seed_quota() {
    printf '24080|remove|100|-|0\n24081|keep|200|-|0\n' > "$QUOTA_CONFIG"
    printf '24080|2026-10|0|0|1|2|1|quota\n24081|2026-10|0|0|3|4|0|-\n' > "$QUOTA_DATA"
    touch "$QUOTA_DIR/.warned_24080_2026-10" "$QUOTA_DIR/.expwarn_24080_2026-10-01" "$QUOTA_DIR/.warned_24081_2026-10"
    : > "$test_dir/calls"
}
assert_forgotten() {
    assert test "$(wc -l < "$QUOTA_CONFIG")" = 1
    assert grep -q '^24081|keep|' "$QUOTA_CONFIG"
    assert grep -q '^24081|' "$QUOTA_DATA"
    reject grep -q '^24080|' "$QUOTA_DATA"
    assert test ! -e "$QUOTA_DIR/.warned_24080_2026-10"
    assert test ! -e "$QUOTA_DIR/.expwarn_24080_2026-10-01"
    assert test -e "$QUOTA_DIR/.warned_24081_2026-10"
    assert grep -qx 'element delete paused_ports 24080' "$test_dir/calls"
    assert grep -qx 'uncount 24080' "$test_dir/calls"
}
for operation in snell_delete snell_uninstall realm_delete realm_uninstall sbx_remove sbx_uninstall; do
(
    seed_quota
    case $operation in
        snell_*)
            printf '[snell-server]\nlisten = 0.0.0.0:24080\n' > "$SNELL_CONFIG_DIR/snell-24080.conf"
            if [[ $operation == snell_delete ]]; then
                printf '[snell-server]\nlisten = 0.0.0.0:24081\n' > "$SNELL_CONFIG_DIR/snell-24081.conf"
                delete_snell_node <<< 1
                assert test -f "$SNELL_CONFIG_DIR/snell-24081.conf"
                rm "$SNELL_CONFIG_DIR/snell-24081.conf"
            else
                id() { return 1; }
                uninstall_service snell "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$SNELL_SERVICE_FILE" '' <<< y
            fi ;;
        realm_*)
            printf '{"endpoints":[{"listen":"0.0.0.0:24080","remote":"192.0.2.1:443"}]}' > "$REALM_CONFIG_FILE"
            printf '{"24080":{"alias":"remove"},"24081":{"alias":"keep"}}' > "$REALM_META_FILE"
            if [[ $operation == realm_delete ]]; then
                delete_realm_forward <<< 24080
                assert test "$(jq 'has("24080")' "$REALM_META_FILE")" = false
            else
                id() { return 1; }
                uninstall_service realm "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$REALM_SERVICE_FILE" "$REALM_CONFIG_FILE" <<< y
            fi ;;
        sbx_*)
            touch "$SBX_ST/ss-24080.env"
            sbx_render() { :; }
            _sbx_cn_any() { return 1; }
            if [[ $operation == sbx_remove ]]; then _sbx_remove_port ss 24080
            else sbx_uninstall; fi ;;
    esac
    assert_forgotten
)
mkdir -p "$SNELL_CONFIG_DIR" "$REALM_CONFIG_DIR" "$SBX_ST" "$SBX_ETC"
done
# A failed automatic Realm restart must not unpause/forget an expired port.
(
    seed_quota
    printf '{"endpoints":[{"listen":"0.0.0.0:24080","remote":"192.0.2.1:443"}]}' > "$REALM_CONFIG_FILE"
    printf '{"24080":{}}' > "$REALM_META_FILE"
    before=$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA" "$REALM_CONFIG_FILE" "$REALM_META_FILE")
    _realm_safe_restart() { return 1; }
    manage_services() { :; }
    reject _quota_auto_delete 24080 test
    assert test "$before" = "$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA" "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
    reject grep -q 'element delete paused_ports' "$test_dir/calls"
)

# 3/11: complete CPU feature sets, including asymmetric virtual CPUs.
v1='lm cmov cx8 fpu fxsr mmx syscall sse2'
v2="$v1 cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2"
v3="$v2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
for level in 1 2 3; do
    flags_var=v$level
    printf 'flags : %s\n' "${!flags_var}" > "$test_dir/cpuinfo"
    assert test "$(_xanmod_cpu_level)" = "$level"
done
for missing in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
    printf 'flags : %s\n' "${v3/ $missing/}" > "$test_dir/cpuinfo"
    assert test "$(_xanmod_cpu_level)" = 2
done
printf 'flags : %s\nflags : %s\n' "$v3" "$v2" > "$test_dir/cpuinfo"
assert test "$(_xanmod_cpu_level)" = 2
printf 'flags : avx2\n' > "$test_dir/cpuinfo"
assert test "$(_xanmod_cpu_level)" = 0
declare -f _do_full_init | grep -Fq 'apt-get install -y -qq "$_xanmod_pkg"'
reject grep -q 'apt-cache depends' < <(declare -f _do_full_init)

# 4: real temporary files, mocked allocation/swapon, exact free-space boundaries.
for scenario in 100 2559 2560 3071 3072 99999 existing inactive container allocation format enable fstab; do
(
    _is_container() { [[ $scenario == container ]]; }
    fixture_free_mb=5000
    [[ ! $scenario =~ ^[0-9]+$ ]] || fixture_free_mb=$scenario
    printf 'MemTotal: 1048576 kB\nSwapTotal: 0 kB\n' > "$test_dir/meminfo"
    [[ $scenario != existing ]] || printf 'SwapTotal: 2097152 kB\n' > "$test_dir/meminfo"
    rm -f "$test_dir/swapfile" "$test_dir/etc/fstab"
    : > "$test_dir/etc/fstab"
    [[ $scenario != inactive ]] || printf 'untouched\n' > "$test_dir/swapfile"
    [[ $scenario != fstab ]] || { rm "$test_dir/etc/fstab"; mkdir "$test_dir/etc/fstab"; }
    : > "$test_dir/calls"
    df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\n/dev/test 99999 0 %s 0%% /\n' "$fixture_free_mb"; }
    fallocate() { record "allocate $2"; [[ $scenario != allocation ]]; }
    dd() { return 1; }
    mkswap() { [[ $scenario != format ]]; }
    swapon() { record swapon; [[ $scenario != enable ]]; }
    case $scenario in
        inactive|allocation|format|enable|fstab) reject _ensure_swap ;;
        *) _ensure_swap ;;
    esac
    case $scenario in
        100|2559|existing|container) assert test ! -e "$test_dir/swapfile"; assert test ! -s "$test_dir/calls" ;;
        inactive) assert test "$(cat "$test_dir/swapfile")" = untouched; assert test ! -s "$test_dir/calls" ;;
        allocation|format|enable) assert test ! -e "$test_dir/swapfile"; assert test ! -s "$test_dir/etc/fstab" ;;
        fstab) assert test -f "$test_dir/swapfile"; rmdir "$test_dir/etc/fstab" ;;
        *)
            expected=1024; (( fixture_free_mb >= 3072 )) || expected=512
            assert grep -qx "allocate ${expected}M" "$test_dir/calls"
            assert test "$(stat -c %a "$test_dir/swapfile")" = 600
            assert grep -q 'swap sw 0 0' "$test_dir/etc/fstab" ;;
    esac
)
done

# 7: stopped/pending Realm and other proxies still reserve their configured port.
printf '{"endpoints":[{"listen":"0.0.0.0:24090","remote":"192.0.2.1:443"}]}' > "$REALM_CONFIG_FILE"
printf '{}' > "$REALM_META_FILE"
before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
reject _realm_add_endpoint 24090 192.0.2.2:443 '' duplicate UN
assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
assert test "$(get_port_interactive <<< $'24090\n24091')" = 24091
(
    open_firewall_port() { return 1; }
    reject _realm_add_endpoint 24091 192.0.2.2:443 '' rejected UN
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
)
_realm_add_endpoint 24091 192.0.2.2:443 '' accepted UN
assert test "$(jq '.endpoints|length' "$REALM_CONFIG_FILE")" = 2
jq '.endpoints += [.endpoints[0]]' "$REALM_CONFIG_FILE" > "$test_dir/duplicate.json"
reject validate_realm_config "$test_dir/duplicate.json"

# 8: deleting the last whitelist entry must commit an empty file.
(
    _f2b_reload_whitelist() { :; }
    _f2b_nft_accept() { record "whitelist $*"; }
    fail2ban-client() { printf 'Currently banned: 0\n'; }
    printf '192.0.2.1\n' > "$F2B_WHITELIST"
    do_ssh_security <<< $'1\n\n192.0.2.1\n0'
    assert test ! -s "$F2B_WHITELIST"
    assert grep -qx 'whitelist del 192.0.2.1' "$test_dir/calls"
)

# 9: sysctl errors/readback mismatch fail; only pending BBR may be deferred.
for scenario in success apply_error mismatch pending unavailable; do
(
    printf 'net.core.rmem_max = 8388608\nnet.ipv4.tcp_congestion_control = bbr\n' > "$test_dir/etc/sysctl.d/99-custom-tuning.conf"
    modprobe() { :; }
    sysctl() {
        case "$*" in
            '-p '*) [[ $scenario != apply_error && $scenario != unavailable ]] ;;
            '-n net.core.rmem_max') if [[ $scenario == mismatch ]]; then echo 42; else echo 8388608; fi ;;
            '-n net.ipv4.tcp_congestion_control') echo bbr ;;
            '-n net.ipv4.tcp_available_congestion_control') echo cubic ;;
            *) return 99 ;;
        esac
    }
    case $scenario in
        pending) _apply_tuning_sysctl 1; assert test "$_TUNING_PENDING_BBR" = 1 ;;
        success) _apply_tuning_sysctl; assert test "$_TUNING_PENDING_BBR" = 0 ;;
        *) reject _apply_tuning_sysctl ;;
    esac
)
done
for scenario in enable inactive firewall success; do
(
    systemctl() {
        [[ $scenario != enable || $1 != enable ]] && [[ $scenario != inactive || $1 != is-active ]]
    }
    open_firewall_port() { [[ $scenario != firewall ]]; }
    touch "$SNELL_BIN"
    get_port_interactive() { echo 24100; }
    if [[ $scenario == success ]]; then
        add_snell_node
        assert test "$(stat -c %a "$SNELL_CONFIG_DIR/snell-24100.conf")" = 600
    else
        reject add_snell_node
        assert test ! -e "$SNELL_CONFIG_DIR/snell-24100.conf"
    fi
)
done

# 10: no-op package upgrade must preserve an existing userspace reboot marker.
(
    apt-get() { record "apt-get $*"; }
    check_package_manager_lock() { :; }
    uname() { echo 6.12.0; }
    dpkg() { echo 'ii linux-image-6.12.0 1 amd64 Linux'; }
    reboot() { echo 'FAIL: unexpected reboot' >&2; return 99; }
    touch "$test_dir/var-run/reboot-required"
    printf 'libc6\n' > "$test_dir/var-run/reboot-required.pkgs"
    do_system_update <<< n || true # declining reboot is allowed to return 1
    assert test -f "$test_dir/var-run/reboot-required"
    assert test "$(cat "$test_dir/var-run/reboot-required.pkgs")" = libc6
    assert grep -qx 'apt-get upgrade --with-new-pkgs -y' "$test_dir/calls"
)

# 5: both token types are delivered only in curl's private config/stdin.
(
    curl() {
        assert test "${*#*dummy_secret}" = "$*"
        assert test "${*#*test-token}" = "$*"
        assert test "$1 $2" = '--config -'
        cat > "$test_dir/curl-config"
        echo '{"ok":true}'
    }
    _tg_api 123:test-token getMe -s >/dev/null
    assert grep -q 'bot123:test-token/getMe' "$test_dir/curl-config"
    _cf_curl dummy_secret https://api.cloudflare.com/client/v4/zones >/dev/null
    assert grep -qx 'header = "Authorization: Bearer dummy_secret"' "$test_dir/curl-config"
    reject _tg_api $'123:token\nurl=bad' getMe
    reject _cf_curl $'token\nheader=bad'
)

# 12: long reports, long single lines, emoji and HTML retain the full body.
(
    TG_BOT_TOKEN=123:offline; TG_CHAT_ID=-100123
    _tg_send_chunk() {
        assert test "${#1}" -lt 2005
        printf '%s' "$1" > "$test_dir/page-$page_count"
        assert test "${2:-HTML}" = plain
        _TG_LAST_MSG_ID=$((page_count + 100)); page_count=$((page_count + 1))
    }
    _tg_edit_keyboard() { printf '%s' "$2" | jq -e 'type == "array"' >/dev/null; }
    for scenario in report line html; do
        rm -f "$test_dir"/page-*
        page_count=0; text='配额报告'
        case $scenario in
            report)
                for ((i=0; i<90; i++)); do text+=$'\n━━━━━━━━━━━━\n'"unique-row-$i · 🇯🇵 abc<&> · 100GB/1TB"; done ;;
            line) printf -v text '%06000d' 0; text="START${text}END" ;;
            html) text='<b>quota &amp; usage</b>'; for ((i=0; i<90; i++)); do text+=$'\n╌╌╌\n'"<u>unique-row-$i</u> &lt;keep&gt;"; done ;;
        esac
        if [[ $scenario == html ]]; then send_telegram "$text" test
        else send_telegram "$text" test plain; fi
        assert test "$page_count" -gt 1
        if [[ $scenario == line ]]; then
            assert grep -q 'START' "$test_dir/page-0"
            assert grep -q 'END' "$test_dir/page-$((page_count - 1))"
            # First page body includes the complete 1800 characters, no lost first line.
            assert test "$(tail -n +2 "$test_dir/page-0" | wc -c)" = 1800
        else
            for ((i=0; i<90; i++)); do assert grep -Fq "unique-row-$i" "$test_dir"/page-*; done
            if [[ $scenario == html ]]; then assert grep -q '<keep>' "$test_dir/page-0"; fi
        fi
    done
)
printf 'PASS: audit regressions (quota, cleanup, CPU, swap, secrets, ports, whitelist, failure handling, reboot and reports)\n'
