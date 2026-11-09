#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-hardening.XXXXXXXX)
trap 'rm -rf "$test_dir"' EXIT
# All writes go into the disposable tree. No host users/services/network changes.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/var/lib/|$test_dir/var/lib/|g" \
    -e "s|/usr/local/|$test_dir/usr/local/|g" -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e "s|/run/|$test_dir/run/|g" "${VPS_MGR_TEST_SCRIPT:-$repo_dir/vps-mgr.sh}")
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }
log_message() { :; }
curl() { echo 'Unexpected network call' >&2; return 99; }
useradd() { echo 'Unexpected host user creation' >&2; return 99; }
systemctl() { echo 'Unexpected host service change' >&2; return 99; }
pause() { :; }
clear() { :; }
sleep() { :; }
mkdir -p "$test_dir/etc/systemd/system" "$DDNS_STATE_DIR" "$SBX_ST" "$SBX_ETC" "$test_dir/usr/local/bin" "$test_dir/run"

# Secure default is written by the production generator, not just a docs assertion.
mkdir -p "$test_dir/etc/sysctl.d"
_calc_sysctl_params 1024 100 transit
_write_sysctl_conf 100 1024 bbr
assert grep -qx 'net.ipv4.conf.all.route_localnet = 0' "$test_dir/etc/sysctl.d/99-custom-tuning.conf"

# Existing permissive files become private; every failed write keeps bytes intact.
DDNS_AUTH_TOKEN=offline_token DDNS_ZONE_NAME=example.invalid DDNS_RECORD_NAME=host.example.invalid
printf 'old-config\n' > "$DDNS_CONFIG_FILE"
chmod 644 "$DDNS_CONFIG_FILE"
old_umask=$(umask)
ddns_save_config
assert test "$(umask)" = "$old_umask"
assert test "$(stat -c %a "$DDNS_CONFIG_FILE")" = 600
before=$(sha256sum "$DDNS_CONFIG_FILE")
for operation in mktemp cat chmod mv; do
(
    eval "$operation() { return 1; }"
    reject ddns_save_config
)
    assert test "$(sha256sum "$DDNS_CONFIG_FILE")" = "$before"
    reject compgen -G "$test_dir/etc/.cf-ddns.*"
done
(
    DDNS_RECORD_NAME=$'bad\nrecord_name=overwritten'
    reject ddns_save_config
)
assert test "$(sha256sum "$DDNS_CONFIG_FILE")" = "$before"
rm "$DDNS_CONFIG_FILE"
mkdir "$DDNS_CONFIG_FILE"
reject ddns_save_config 2>/dev/null
assert test -z "$(ls -A "$DDNS_CONFIG_FILE")"
rmdir "$DDNS_CONFIG_FILE"
ddns_save_config

# Display/edit must treat imported metacharacters as data across all protocols.
_sbx_ip() { printf '192.0.2.1\n'; }
_sbx_name_for() { printf 'test-node\n'; }
secret='$(touch '"$test_dir"'/executed)'
printf 'S_PORT=55001\nS_METHOD=aes-128-gcm\nS_PW=%s\n' "$secret" > "$SBX_ST/ss-55001.env"
printf 'SK_PORT=55002\nSK_USER=test\nSK_PW=%s\nSK_WL=%s\n' "$secret" "$secret" > "$SBX_ST/socks-55002.env"
printf 'H_PORT=55003\nH_PW=%s\nH_OBFS=%s\nH_SNI=example.invalid\n' "$secret" "$secret" > "$SBX_ST/hy2-55003.env"
for proto in ss:55001 socks:55002 hy2:55003; do
    _sbx_show_one "$SBX_ST/${proto%:*}-${proto#*:}.env" > "$test_dir/show"
    assert test ! -e "$test_dir/executed"
    if [[ $proto == ss:* ]]; then
        encoded=$(printf 'aes-128-gcm:%s' "$secret" | base64 -w0)
        assert grep -Fq "$encoded" "$test_dir/show"
    else assert grep -Fq "$secret" "$test_dir/show"; fi
done
_sbx_socks_edit_wl_impl <<< 0 > "$test_dir/show"
assert test ! -e "$test_dir/executed"
assert grep -Fq "$secret" "$test_dir/show"

# Fail closed for root/unreadable identities; create a private system account only when absent.
(
    account_exists=0
    account_uid=12345
    id() {
        if [[ ${1:-} == -u ]]; then printf '%s\n' "$account_uid"; return; fi
        [[ $account_exists == 1 ]]
    }
    useradd() {
        [[ $* == '--system --user-group --no-create-home --shell /usr/sbin/nologin singboxproxy' ]] || return 99
        account_exists=1
    }
    _sbx_ensure_user
    assert test "$account_exists" = 1
    account_uid=0
    reject _sbx_ensure_user
    id() { return 1; }
    useradd() { return 1; }
    reject _sbx_ensure_user
)

# Native Unix access checks, mapping only the test service identity to nobody.
test_gid=$(command id -g nobody)
_sbx_ensure_user() { :; }
chown() {
    if [[ $1 == root:singboxproxy ]]; then shift; command chown "root:$test_gid" "$@"
    else command chown "$@"; fi
}
runuser() {
    [[ $1 == -u && $2 == singboxproxy && $3 == -- ]] || return 99
    shift 3
    command runuser -u nobody -- "$@"
}
chmod 711 "$test_dir" "$test_dir/etc" "$test_dir/usr" "$test_dir/usr/local"
printf 'private certificate\n' > "$SBX_ST/hy2-55003.key"
printf 'public certificate\n' > "$SBX_ST/hy2-55003.crt"
jq -cn --arg key "$SBX_ST/hy2-55003.key" '{inbounds:[{tls:{key_path:$key}}]}' > "$SBX_CONF"
# Permission-aware check executed as the actual unprivileged identity.
cat > "$SBX_BIN" <<'BIN'
#!/bin/bash
set -euo pipefail
[[ $1 == check && $2 == -c && -r $3 && ! -w $3 ]]
while IFS= read -r file; do [[ -r $file && ! -w $file ]]; done < <(jq -r '.inbounds[]?.tls.key_path // empty' "$3")
BIN
chmod 755 "$SBX_BIN"
unit="$test_dir/etc/systemd/system/sing-box.service"
printf '[Service]\nUser=root\n' > "$unit"
systemctl() {
    printf '%s\n' "$*" >> "$test_dir/service-calls"
    case $1 in
        daemon-reload)
            if [[ -f $test_dir/fail-reload ]]; then rm "$test_dir/fail-reload"; return 1; fi ;;
        restart)
            if [[ -f $test_dir/fail-start ]] && grep -q '^User=singboxproxy$' "$unit"; then return 1; fi ;;
        is-active) return 0 ;;
        *) return 99 ;;
    esac
}
# A manually supplied external private certificate blocks migration before restart.
printf 'external private key\n' > "$test_dir/locked.key"
chmod 600 "$test_dir/locked.key"
cp "$SBX_CONF" "$test_dir/valid-config"
jq --arg key "$test_dir/locked.key" '.inbounds[0].tls.key_path=$key' "$SBX_CONF" > "$test_dir/config-next"
mv "$test_dir/config-next" "$SBX_CONF"
previous=$(sha256sum "$unit")
reject _sbx_configure_service
assert test "$(sha256sum "$unit")" = "$previous"
assert test "$(stat -c %a "$test_dir/locked.key")" = 600
cp "$test_dir/valid-config" "$SBX_CONF"
for fault in fail-start fail-reload; do
    previous=$(sha256sum "$unit")
    touch "$test_dir/$fault"
    reject _sbx_configure_service
    assert test "$(sha256sum "$unit")" = "$previous"
    rm -f "$test_dir/$fault"
done
_sbx_configure_service
assert grep -qx 'User=singboxproxy' "$unit"
assert grep -qx 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$unit"
assert grep -qx 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit"
assert test "$(stat -c %a "$SBX_CONF")" = 640
assert test "$(stat -c %a "$SBX_ST/hy2-55003.key")" = 640
command runuser -u nobody -- bash -c '[[ -r $1 && ! -w $1 && -r $2 && ! -w $2 && ! -r $3 && ! -w $4 ]]' \
    _ "$SBX_CONF" "$SBX_ST/hy2-55003.key" "$SBX_ST/ss-55001.env" "$SBX_ETC"
before=$(wc -l < "$test_dir/service-calls")
_sbx_configure_service
assert test "$(wc -l < "$test_dir/service-calls")" = "$before"
_sbx_configure_service restart
assert test "$(tail -n 2 "$test_dir/service-calls" | grep -c '^restart ')" = 1
# Never grant permissions through a symlink.
ln -s "$DDNS_CONFIG_FILE" "$SBX_ST/hy2-9999.key"
reject _sbx_permissions
assert test "$(stat -c %a "$DDNS_CONFIG_FILE")" = 600
rm "$SBX_ST/hy2-9999.key"

# Notifications: no false success/cooldown, bounded retry, durable IP change delivery.
TG_BOT_TOKEN=123:offline TG_CHAT_ID=-100123
send_ok=0
send_telegram() {
    printf 'attempt\n' >> "$test_dir/attempts"
    [[ $send_ok == 1 ]]
}
ddns_notify_error 'test failure'
_ddns_flush_notifications
assert test "$(wc -l < "$test_dir/attempts")" = 1
assert test ! -e "$DDNS_STATE_DIR/last_error_time"
reject grep -q '通知已发送' "$DDNS_LOG_FILE"
ddns_notify_error 'updated failure'
_ddns_flush_notifications
assert test "$(wc -l < "$test_dir/attempts")" = 1
assert jq -e '.message | contains("updated failure")' "$DDNS_STATE_DIR/notify-error.json" >/dev/null
jq '.next_attempt=0' "$DDNS_STATE_DIR/notify-error.json" > "$test_dir/queue"
mv "$test_dir/queue" "$DDNS_STATE_DIR/notify-error.json"
send_ok=1
_ddns_flush_notifications
assert test -f "$DDNS_STATE_DIR/last_error_time"
assert test ! -f "$DDNS_STATE_DIR/notify-error.json"
ddns_notify_error 'cooldown'
assert test ! -f "$DDNS_STATE_DIR/notify-error.json"

send_ok=0
ddns_notify_health 192.0.2.1
_ddns_flush_notifications
day=$(TZ="$TZ_DEFAULT" date +%Y%m%d)
assert test ! -f "$DDNS_STATE_DIR/health_$day.tag"
# Simulate a new shell/process using only the persistent pending record.
jq '.next_attempt=0' "$DDNS_STATE_DIR/notify-health.json" > "$test_dir/queue"
mv "$test_dir/queue" "$DDNS_STATE_DIR/notify-health.json"
( send_ok=1; _ddns_flush_notifications )
assert test -f "$DDNS_STATE_DIR/health_$day.tag"
assert test ! -f "$DDNS_STATE_DIR/notify-health.json"

# Actual DDNS check must complete/cache DNS before attempting delivery, and retry
# later even when the IP no longer changes. External calls are deterministic stubs.
_cf_curl() {
    if [[ $* == *'/zones?'* ]]; then printf '{"result":[{"id":"zone123456789012"}]}'
    elif [[ $* == *'dns_records?type'* ]]; then printf '{"result":[{"id":"record123456789012"}]}'
    else printf 'update\n' >> "$test_dir/dns-updates"; printf '{"success":true}'; fi
}
ddns_get_ip() { printf '192.0.2.2\n'; }
get_node_id() { printf 'test-node\n'; }
send_ok=0
ddns_run_check true
assert test "$(wc -l < "$test_dir/dns-updates")" = 1
assert test -s "$DDNS_STATE_DIR/notify-change.json"
jq '.next_attempt=0' "$DDNS_STATE_DIR/notify-change.json" > "$test_dir/queue"
mv "$test_dir/queue" "$DDNS_STATE_DIR/notify-change.json"
send_ok=1
ddns_run_check true
assert test "$(wc -l < "$test_dir/dns-updates")" = 1
assert test ! -f "$DDNS_STATE_DIR/notify-change.json"
# An already-running check prevents duplicates from the menu and timer.
(
    flock -n 7
    ddns_run_check true
) 7>"$DDNS_STATE_DIR/check.lock"
assert test "$(wc -l < "$test_dir/dns-updates")" = 1
ddns_notify_health 192.0.2.2
jq '.day="20000101"' "$DDNS_STATE_DIR/notify-health.json" > "$test_dir/queue"
mv "$test_dir/queue" "$DDNS_STATE_DIR/notify-health.json"
ddns_notify_change 192.0.2.1 192.0.2.2
before=$(wc -l < "$test_dir/attempts")
DDNS_RECORD_NAME=other.example.invalid
_ddns_flush_notifications
assert test "$(wc -l < "$test_dir/attempts")" = "$before"
assert test ! -f "$DDNS_STATE_DIR/notify-health.json"
assert test ! -f "$DDNS_STATE_DIR/notify-change.json"
# No Telegram configuration is a skip, not a claimed successful send.
TG_BOT_TOKEN=
ddns_notify_change 192.0.2.2 192.0.2.3
assert test ! -f "$DDNS_STATE_DIR/notify-change.json"
echo 'PASS: loopback default, atomic DDNS failures, inert node data, service identity/rollback, notification retry and serialization'
