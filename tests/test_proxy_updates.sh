#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-proxy-updates.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-proxy-updates.* ]] && rm -rf "$test_dir"' EXIT
# All state/configs/binaries are fixtures; no real downloads, TG messages or service operations.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' -e "s|/etc/|$test_dir/etc/|g" \
    -e "s|/usr/local/|$test_dir/usr/local/|g" -e "s|/opt/proxy-manager|$test_dir/state|g" \
    "$repo_dir/vps-mgr.sh")
mkdir -p "$WORK_DIR" "$REALM_CONFIG_DIR" "$SBX_ETC" "$(dirname "$SBX_BIN")"
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
log_message() { printf '%s\n' "$*" >> "$test_dir/log"; }
get_node_id() { printf '🇺🇸 #Update_Test'; }
systemctl() { record "FORBIDDEN systemctl $*"; return 99; }
install_service() { record 'FORBIDDEN install'; return 99; }
update_service() { record 'FORBIDDEN update'; return 99; }
sbx_install_core() { record 'FORBIDDEN sing-box install'; return 99; }
reboot() { record 'FORBIDDEN reboot'; return 99; }
curl() {
    case "${*: -1}" in
        https://api.github.com/repos/zhboner/realm/releases/latest)
            record query-realm
            [[ $fixture_realm_failure == 0 ]] || return 22
            printf '%s\n' "$fixture_realm_release" ;;
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)
            record query-sing-box
            printf '%s\n' "$fixture_sbx_release" ;;
        *) record "FORBIDDEN curl $*"; return 99 ;;
    esac
}
send_telegram() {
    record send
    [[ $TG_BOT_TOKEN == 123:offline && $TG_CHAT_ID == -100123 && $TG_THREAD_ID == "$fixture_update_topic" && $3 == plain ]] || return 99
    [[ $fixture_send_failure == 0 ]] || return 1
    printf '%s\n' "$1" >> "$test_dir/messages"
}
printf '%s\n' '#!/bin/sh' \
    '[ "$1" = --version ] || [ "$1" = -V ] || exit 99' \
    'case "$FIXTURE_REALM_MODE" in' \
    '  fail) echo "error 9.9.9"; exit 1 ;;' \
    '  fallback) [ "$1" = -V ] || exit 1 ;;' \
    '  stderr) exec 1>&2 ;;' \
    'esac' 'printf "realm %s\n" "$FIXTURE_REALM_VERSION"' > "$REALM_BIN"
printf '%s\n' '#!/bin/sh' '[ "$1" = version ] || exit 99' \
    'printf "sing-box version %s\nEnvironment: test\n" "$FIXTURE_SBX_VERSION"' > "$SBX_BIN"
chmod 755 "$REALM_BIN" "$SBX_BIN"
printf '{"endpoints":[]}\n' > "$REALM_CONFIG_FILE"
printf '{"inbounds":[]}\n' > "$SBX_CONF"
before=$(sha256sum "$REALM_BIN" "$SBX_BIN" "$REALM_CONFIG_FILE" "$SBX_CONF")
export FIXTURE_REALM_VERSION FIXTURE_REALM_MODE FIXTURE_SBX_VERSION
write_tg() {
    printf 'TG_BOT_TOKEN=123:offline\nTG_CHAT_ID=-100123\nTG_CHAT_HUB=-100123\nTG_THREAD_SSH=4\nTG_THREAD_UPDATE=%s\n' "$fixture_update_topic" > "$TG_CONF"
}
reset_case() {
    reject grep -q FORBIDDEN "$test_dir/calls" 2>/dev/null
    rm -f "$WORK_DIR/proxy-update-realm.notice" "$WORK_DIR/proxy-update-sing-box.notice" "$test_dir/messages"
    : > "$test_dir/calls"
    : > "$test_dir/log"
    FIXTURE_REALM_VERSION=2.7.0; FIXTURE_REALM_MODE=normal; FIXTURE_SBX_VERSION=1.11.0
    fixture_realm_release='{"tag_name":"v2.8.0","draft":false,"prerelease":false}'
    fixture_sbx_release='{"tag_name":"v1.12.0","draft":false,"prerelease":false}'
    fixture_realm_failure=0; fixture_send_failure=0; fixture_update_topic=7
    write_tg
}

reset_case
for FIXTURE_REALM_MODE in normal fallback stderr; do
    assert test "$(get_installed_version realm "$REALM_BIN")" = v2.7.0
done
FIXTURE_REALM_MODE=fail
assert test "$(get_installed_version realm "$REALM_BIN")" = 未知
FIXTURE_SBX_VERSION=1.12.0-beta.3+build.5
assert test "$(get_installed_version sing-box "$SBX_BIN")" = v1.12.0-beta.3+build.5

# Both new releases are combined in the dedicated update topic, never the SSH topic.
reset_case
_proxy_updates_notify
assert test "$(grep -c '^send$' "$test_dir/calls")" = 1
for expected in '🇺🇸 #Update_Test' 'Realm: v2.7.0 → v2.8.0' 'sing-box: v1.11.0 → v1.12.0' \
    '菜单 16 → 3' '菜单 16 → 2' '仅提醒，未下载、安装或重启代理' \
    'https://github.com/zhboner/realm/releases/tag/v2.8.0'; do
    assert grep -Fq "$expected" "$test_dir/messages"
done
for service in realm sing-box; do
    assert test "$(stat -c %a "$WORK_DIR/proxy-update-$service.notice")" = 600
done
assert test "$(cat "$WORK_DIR/proxy-update-realm.notice")" = -100123:7:2.8.0
assert test "$(cat "$WORK_DIR/proxy-update-sing-box.notice")" = -100123:7:1.12.0
_proxy_updates_notify
assert test "$(grep -c '^send$' "$test_dir/calls")" = 1
fixture_realm_release='{"tag_name":"v2.8.1","draft":false,"prerelease":false}'
_proxy_updates_notify
assert test "$(grep -c '^send$' "$test_dir/calls")" = 2
assert test "$(grep -c 'sing-box:' "$test_dir/messages")" = 1
fixture_update_topic=8
write_tg
_proxy_updates_notify
assert test "$(grep -c '^send$' "$test_dir/calls")" = 3
assert test "$(cat "$WORK_DIR/proxy-update-sing-box.notice")" = -100123:8:1.12.0

# Version ordering is numeric, never a downgrade; local prerelease/build metadata is preserved.
for version_case in equal newer numeric prerelease build; do
    reset_case
    FIXTURE_REALM_VERSION=2.8.0
    case $version_case in
        equal) FIXTURE_SBX_VERSION=1.12.0 ;;
        newer) FIXTURE_SBX_VERSION=1.13.0 ;;
        numeric) FIXTURE_SBX_VERSION=1.9.0; fixture_sbx_release='{"tag_name":"1.10.0","draft":false,"prerelease":false}' ;;
        prerelease) FIXTURE_SBX_VERSION=1.12.0-beta.3 ;;
        build) FIXTURE_SBX_VERSION=1.12.0+build.9 ;;
    esac
    _proxy_updates_notify
    case $version_case in
        numeric|prerelease) assert test -s "$test_dir/messages" ;;
        *) assert test ! -e "$test_dir/messages" ;;
    esac
done

# Incomplete/invalid releases, API failures and unknown local versions must not manufacture alerts.
for release_case in beta draft malformed missing failure local_unknown; do
    reset_case
    FIXTURE_SBX_VERSION=1.12.0
    case $release_case in
        beta) fixture_realm_release='{"tag_name":"v2.8.0","draft":false,"prerelease":true}' ;;
        draft) fixture_realm_release='{"tag_name":"v2.8.0","draft":true,"prerelease":false}' ;;
        malformed) fixture_realm_release='{"tag_name":"v2.8.0-rc.1","draft":false,"prerelease":false}' ;;
        missing) fixture_realm_release='{"message":"rate limited"}' ;;
        failure) fixture_realm_failure=1 ;;
        local_unknown) FIXTURE_REALM_VERSION=unknown ;;
    esac
    reject _proxy_updates_notify
    assert test ! -e "$test_dir/messages"
    assert test ! -e "$WORK_DIR/proxy-update-realm.notice"
done
reset_case
fixture_realm_failure=1
reject _proxy_updates_notify
assert grep -q 'sing-box:' "$test_dir/messages"
assert test ! -e "$WORK_DIR/proxy-update-realm.notice"
assert test -e "$WORK_DIR/proxy-update-sing-box.notice"

# Missing/invalid TG and failed deliveries never poison dedup state; a later successful run retries.
for tg_case in missing invalid no_topic invalid_topic failed; do
    reset_case
    case $tg_case in
        missing) rm "$TG_CONF" ;;
        invalid) printf 'TG_BOT_TOKEN=123:offline\nTG_CHAT_HUB=-100123\nTG_THREAD_SSH=invalid\n' > "$TG_CONF" ;;
        no_topic) fixture_update_topic=''; write_tg ;;
        invalid_topic) fixture_update_topic=wrong; write_tg ;;
        failed) fixture_send_failure=1 ;;
    esac
    if [[ $tg_case == failed ]]; then reject _proxy_updates_notify; else _proxy_updates_notify; fi
    assert test ! -e "$test_dir/messages"
    assert test ! -e "$WORK_DIR/proxy-update-realm.notice"
    assert test ! -e "$WORK_DIR/proxy-update-sing-box.notice"
    assert grep -q 'Realm:' "$test_dir/log"
    fixture_update_topic=7; write_tg; fixture_send_failure=0
    _proxy_updates_notify
    assert test -s "$test_dir/messages"
done

# No installed programs: no GitHub or TG requests. Lock contention must not duplicate a send.
reset_case
mv "$REALM_BIN" "$REALM_BIN.saved"
mv "$SBX_BIN" "$SBX_BIN.saved"
_proxy_updates_notify
assert test ! -s "$test_dir/calls"
mv "$REALM_BIN.saved" "$REALM_BIN"
mv "$SBX_BIN.saved" "$SBX_BIN"
(
    exec 8>"$WORK_DIR/proxy-updates.lock"
    flock -n 8
    _proxy_updates_notify
)
assert test ! -s "$test_dir/calls"
_proxy_updates_notify &
first_pid=$!
_proxy_updates_notify &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
assert test "$(grep -c '^send$' "$test_dir/calls")" = 1

# A failed atomic state write reports failure and leaves the next run able to retry.
reset_case
(
    mv() { return 1; }
    reject _proxy_updates_notify
)
assert test ! -e "$WORK_DIR/proxy-update-realm.notice"
assert test ! -e "$WORK_DIR/proxy-update-sing-box.notice"
reject compgen -G "$WORK_DIR/.proxy-update.*"
_proxy_updates_notify
assert test -e "$WORK_DIR/proxy-update-realm.notice"
assert test "$before" = "$(sha256sum "$REALM_BIN" "$SBX_BIN" "$REALM_CONFIG_FILE" "$SBX_CONF")"
reject grep -q FORBIDDEN "$test_dir/calls"

# Exercise the actual daily entry point in a separate shell, keeping production errexit semantics.
if (( EUID == 0 )); then
    for check_result in 0 1; do
        for self_result in 0 1; do
            rc=0
            bash -c '
                source <(sed '\''/^main "\$@"$/d'\'' "$1")
                test_check_result=$2; test_self_result=$3; test_calls=$4
                _proxy_updates_notify() { printf "proxy-check\n" >> "$test_calls"; return "$test_check_result"; }
                self_update() { printf "self-update %s\n" "$1" >> "$test_calls"; return "$test_self_result"; }
                main auto-update
            ' _ "$repo_dir/vps-mgr.sh" "$check_result" "$self_result" "$test_dir/daily" || rc=$?
            assert test "$rc" = "$((check_result || self_result))"
            assert test "$(tail -2 "$test_dir/daily")" = $'proxy-check\nself-update auto'
        done
    done
else
    printf 'SKIP: daily root entry test requires root\n'
fi
printf 'PASS: stable proxy checks, version ordering, dedup/retry, locking, daily integration and no proxy mutations\n'
