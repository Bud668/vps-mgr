#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-safety.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-safety.* ]] && rm -rf "$test_dir"' EXIT
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|^readonly WORK_DIR=.*|readonly WORK_DIR=\"$test_dir/state\"|" \
    -e "s|^readonly TG_CONF=.*|readonly TG_CONF=\"$test_dir/telegram.conf\"|" \
    -e "s|^readonly FW_LOCK=.*|readonly FW_LOCK=\"$test_dir/lock\"|" \
    -e "s|^readonly SBX_ETC=.*|readonly SBX_ETC=\"$test_dir/sing-box\"|" \
    -e "s|^readonly SBX_ST=.*|readonly SBX_ST=\"$test_dir/nodes\"|" \
    -e 's|^readonly SBX_BIN=.*|readonly SBX_BIN="fake_sbx"|' \
    "$repo_dir/vps-mgr.sh")
log_message() { :; }
sleep() { :; }
_fw_restore() { :; }
_fw_persist() { :; }
nft() {
    case "$*" in
        'list table inet vps_mgr') echo 'table inet vps_mgr {}' ;;
        '-f '*) return 0 ;;
        *) echo "Unexpected nft invocation: $*" >&2; return 99 ;;
    esac
}
reject_config=0
fake_sbx() {
    [[ $reject_config == 0 ]] || return 1
    [[ -z ${VPS_MGR_REAL_SBX:-} ]] || "$VPS_MGR_REAL_SBX" "$@"
}
systemctl() {
    case "$1" in
        restart)
            [[ $(jq '.inbounds|length' "$SBX_CONF" 2>/dev/null || echo 0) -le 1 ]] ;;
        enable|stop|is-active) return 0 ;;
        *) echo "Unexpected systemctl: $*" >&2; return 99 ;;
    esac
}
assert() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
mkdir -p "$SBX_ETC" "$SBX_ST" "$WORK_DIR"
umask 022
printf 'S_PORT=24073\nS_METHOD=aes-128-gcm\nS_PW=a"quoted-password\n' > "$SBX_ST/ss-24073.env"
sbx_render
assert test "$(stat -c %a "$SBX_CONF")" = 600
assert test "$(jq -r '.inbounds[0].password' "$SBX_CONF")" = 'a"quoted-password'
printf 'S_PORT=24073\nS_METHOD=2022-blake3-aes-256-gcm\nS_PW=%s\n' "$(openssl rand -base64 32)" > "$SBX_ST/ss-24073.env"
sbx_render
before=$(sha256sum "$SBX_CONF")
reject_config=1
if sbx_render; then echo 'Rejected config reported success' >&2; exit 1; fi
assert test "$before" = "$(sha256sum "$SBX_CONF")"
reject_config=0
mkdir -p "$QUOTA_DIR"
printf '24073|test|104857600|-|0\n' > "$QUOTA_CONFIG"
printf '24073|2026-10|10|20|100|200|0|-\n' > "$QUOTA_DATA"
quota_before=$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA")
failed_node() {
    printf 'S_PORT=24074\nS_METHOD=aes-128-gcm\nS_PW=second\n' > "$SBX_ST/ss-24074.env"
    rm -f "$QUOTA_CONFIG"
    printf 'changed\n' > "$QUOTA_DATA"
    sbx_render
}
if _sbx_mutate failed_node; then echo 'Failed node reported success' >&2; exit 1; fi
assert test ! -e "$SBX_ST/ss-24074.env"
assert test "$before" = "$(sha256sum "$SBX_CONF")"
assert test "$quota_before" = "$(sha256sum "$QUOTA_CONFIG" "$QUOTA_DATA")"

# A failed download must never stop the running old program or remove it.
printf 'old binary\n' > "$test_dir/realm"
curl() { return 22; }
if install_service realm root "$test_dir/realm" "$test_dir/config" https://invalid.test/realm.tar.gz tar true; then
    echo 'Failed download reported success' >&2; exit 1
fi
assert test "$(cat "$test_dir/realm")" = 'old binary'

# Rollback the executable when its previously active service will not start.
printf 'new binary\n' > "$test_dir/candidate"
systemctl() {
    case "$1" in
        is-active|restart) [[ $(cat "$test_dir/realm") == 'old binary' ]] ;;
        *) return 99 ;;
    esac
}
if _replace_binary "$test_dir/candidate" "$test_dir/realm" realm; then
    echo 'Failed new executable reported success' >&2; exit 1
fi
assert test "$(cat "$test_dir/realm")" = 'old binary'
systemctl() { return 1; }
if manage_services restart realm; then echo 'Service failure hidden' >&2; exit 1; fi

curl() { echo '{"message":"rate limited"}'; }
assert test "$(get_latest_github_release example/example v2.7.0)" = v2.7.0
# A beta stays off the old stable release, but can later accept its matching stable.
(
    get_latest_github_release() { printf 'v1.4.1\n'; }
    output=$(self_update auto)
    [[ $output == *跳过降级* ]] || { echo 'Old stable was not skipped' >&2; exit 1; }
    if [[ $SCRIPT_VERSION == *-* ]]; then
        get_latest_github_release() { printf 'v%s\n' "${SCRIPT_VERSION%%-*}"; }
        output=$(self_update <<< n)
        [[ $output == *发现新版本* ]] || { echo 'Matching stable was treated as a downgrade' >&2; exit 1; }
    fi
)
_check_port_available() { [[ $1 == 24074 ]]; }
assert test "$(printf '24073\n24074\n' | get_port_interactive)" = 24074
for ram in 64 128 256 1024; do
    for role in transit edge; do
        _calc_sysctl_params "$ram" 1000 "$role"
        assert test "$_P_RMEM_MAX" -le "$((ram * 1048576 / 10))"
        assert test "$_P_TCP_RMEM_MID" -le "$_P_RMEM_MAX"
        assert test "$_P_UDP_MEM_LOW" -le "$_P_UDP_MEM_PRESSURE"
        assert test "$_P_UDP_MEM_PRESSURE" -le "$_P_UDP_MEM_MAX"
        assert test "$((_P_UDP_MEM_MAX * $(getconf PAGESIZE)))" -le "$((ram * 1048576 / 10))"
    done
done
for address in 192.0.2.1 2001:db8::1 2001:db8::/32 192.0.2.0/24; do assert validate_ip_cidr "$address"; done
for address in '999.1.1.1' '192.0.2.1;id' '::/129'; do
    if validate_ip_cidr "$address"; then echo "Invalid CIDR accepted: $address"; exit 1; fi
done
for marker in MONITOR_EOF NOTIFY_EOF F2B_EOF; do
    sed -n "/<<'$marker'/,/^$marker/p" "$repo_dir/vps-mgr.sh" | sed '1d;$d' | bash -n
done
systemctl() { return 0; }
printf 'SK_PORT=24074\nSK_USER=test\nSK_PW=password\n' > "$SBX_ST/socks-24074.env"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$SBX_ST/hy2-24075.key" -out "$SBX_ST/hy2-24075.crt" -days 1 -subj /CN=test.invalid 2>/dev/null
printf 'H_PORT=24075\nH_PW=test-password\nH_OBFS=test-obfs\nH_UP=50\nH_DOWN=100\nH_CRT=%s\nH_KEY=%s\n' \
    "$SBX_ST/hy2-24075.crt" "$SBX_ST/hy2-24075.key" > "$SBX_ST/hy2-24075.env"
printf 'example.com\n' > "$SBX_ACL"
: > "$SBX_ST/acl.enabled"
sbx_render
assert test "$(jq '.inbounds|length' "$SBX_CONF")" = 3

# Exercise real Unix permissions without adding host users or touching /etc.
if (( EUID == 0 )) && command -v setpriv >/dev/null && id nobody >/dev/null 2>&1; then
    test_uid=$(id -u nobody); test_gid=$(id -g nobody)
    id() { [[ ${1:-} == ssh-tg-monitor ]] || command id "$@"; }
    chown() {
        if [[ $1 == root:ssh-tg-monitor ]]; then shift; command chown "root:$test_gid" "$@"
        else command chown "$@"; fi
    }
    F2B_WHITELIST="$test_dir/whitelist"
    chmod 711 "$test_dir"
    chmod 700 "$QUOTA_DIR"
    printf 'SERVER_COUNTRY_CODE="US"\n' > "$CACHE_FILE"
    printf '192.0.2.1\n' > "$F2B_WHITELIST"
    _write_tg_conf '123:test_token' '-100123' Chi_ATT 1 2 3
    export -f get_flag_emoji _srv_render _tg_cfg_get
    rendered=$(setpriv --reuid "$test_uid" --regid "$test_gid" --clear-groups bash -c '
        [[ -r $1 && -r $2 && -r $3 && ! -r $4 && ! -r $5 ]] || exit 1
        _srv_render "$(_tg_cfg_get "$1" SERVER_NAME)" tag "$(_tg_cfg_get "$2" SERVER_COUNTRY_CODE)"
    ' _ "$TG_CONF" "$CACHE_FILE" "$F2B_WHITELIST" "$SBX_CONF" "$QUOTA_DATA")
    assert test "$rendered" = '🇺🇸 #Chi_ATT'
    unset -f id chown
    printf 'PASS: unprivileged notification flag and secret isolation\n'
else
    printf 'SKIP: unprivileged notification check requires root, setpriv and nobody\n'
fi
printf 'PASS: config permissions/validation/rollback, installer and service failures, bounded memory, dual-stack input, generated scripts\n'
