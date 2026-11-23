#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-snell-versions.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-snell-versions.* ]] && rm -rf "$test_dir"' EXIT

# Redirect every writable production path before sourcing; all service/network calls below are mocks.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/usr/local/|$test_dir/usr/local/|g" \
    -e "s|/opt/proxy-manager|$test_dir/state|g" -e "s|/run/|$test_dir/run/|g" \
    "$repo_dir/vps-mgr.sh")
mkdir -p "$SNELL_CONFIG_DIR" "$(dirname "$SNELL_BIN")" "$WORK_DIR" "$test_dir/run"
: > "$test_dir/calls"
: > "$test_dir/forbidden"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected [$1], got [$2]"; }
assert() { "$@" || fail "$*"; }
reject() { if "$@"; then fail "accepted: $*"; fi; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
reset_calls() { : > "$test_dir/calls"; }
forbid() { printf '%s\n' "$*" >> "$test_dir/forbidden"; return 99; }

fixture_curl_failure=0
fixture_kb=''
curl() {
    local arg url=''
    for arg in "$@"; do [[ $arg == -* ]] || url=$arg; done
    record "curl:$url"
    [[ $url == "$SNELL_KB_URL" ]] || forbid "network:$url"
    (( fixture_curl_failure == 0 )) || return 22
    printf '%s\n' "$fixture_kb"
}
systemctl() { record "mock-systemctl:$*"; return 0; }
install_service() { record "install:$1:${5:-}:${7:-}"; return 0; }
create_snell_template_service() { record template; }
manage_services() { record "manage:$*"; }
_fw_ensure() { return 0; }
get_port_interactive() { printf '24080\n'; }
_state_locked() { record "locked:$*"; }
clear() { :; }
pause() { :; }
sleep() { :; }
disown() { :; }
reboot() { forbid reboot; }
shutdown() { forbid shutdown; }
apt-get() { forbid apt-get; }
useradd() { forbid useradd; }

write_snell_output() {
    local output=$1
    # shellcheck disable=SC2016 # $1/$0 belong to the generated fixture script.
    printf '%s\n' '#!/bin/sh' \
        '[ "$1" = "--version" ] || exit 64' \
        'cat "${0}.output" >&2' > "$SNELL_BIN"
    printf '%s\n' "$output" > "$SNELL_BIN.output"
    chmod 755 "$SNELL_BIN"
}
write_snell() {
    write_snell_output "2026-08-07 09:21:00.000000 [server_main] <NOTIFY> snell-server $1 (Aug  7 2026)"
}
remove_snell() { rm -f "$SNELL_BIN" "$SNELL_BIN.output" "$SNELL_VERSION_FILE"; }

# Binary output is authoritative, including beta versions; unrelated version text is rejected.
write_snell v6.0.0
assert_eq v6.0.0 "$(_snell_binary_version "$SNELL_BIN")"
printf 'v5.0.1\n' > "$SNELL_VERSION_FILE"
chmod 600 "$SNELL_VERSION_FILE"
assert_eq v6.0.0 "$(get_installed_version snell "$SNELL_BIN")"
write_snell v6.0.0b4
assert_eq v6.0.0b4 "$(get_installed_version snell "$SNELL_BIN")"
write_snell_output 'another-program v99.0.0'
reject _snell_binary_version "$SNELL_BIN"

# Old secure markers remain a fallback, but bad/stale metadata never invents a version.
if (( EUID == 0 )); then
    printf 'v5.0.1\n' > "$SNELL_VERSION_FILE"; chmod 600 "$SNELL_VERSION_FILE"
    assert_eq v5.0.1 "$(get_installed_version snell "$SNELL_BIN")"
    printf 'v5.0.1-junk\n' > "$SNELL_VERSION_FILE"
    assert_eq 未知 "$(get_installed_version snell "$SNELL_BIN")"
    printf 'v5.0.1\n' > "$test_dir/marker-target"
    rm -f "$SNELL_VERSION_FILE"; ln -s "$test_dir/marker-target" "$SNELL_VERSION_FILE"
    assert_eq 未知 "$(get_installed_version snell "$SNELL_BIN")"
    rm -f "$SNELL_VERSION_FILE"; printf 'v5.0.1\n' > "$SNELL_VERSION_FILE"; chmod 666 "$SNELL_VERSION_FILE"
    assert_eq 未知 "$(get_installed_version snell "$SNELL_BIN")"
fi
rm -f "$SNELL_BIN" "$SNELL_BIN.output"
printf 'v5.0.1\n' > "$SNELL_VERSION_FILE"; chmod 600 "$SNELL_VERSION_FILE"
assert_eq 未知 "$(get_installed_version snell "$SNELL_BIN")"

# The caller may supply a trusted official binary for integration testing.
if [[ -n ${VPS_MGR_REAL_SNELL_V6:-} ]]; then
    assert_eq v6.0.0 "$(_snell_binary_version "$VPS_MGR_REAL_SNELL_V6")"
fi

# Mirror the official page: V6 has a normal filename but its release note explicitly says beta;
# V5.0.1 has only a heading, while an older V4 download remains later on the page.
fixture_kb=$'# Snell\nhttps://dl.nssurge.com/snell/snell-server-v6.0.0-linux-amd64.zip\n## Release Notes\n### v6.0.0\nSnell v6 is currently available for beta testing.\n### v5.0.1\nFixed a low-probability crash.\n### v4.1.1\nhttps://dl.nssurge.com/snell/snell-server-v4.1.1-linux-amd64.zip'
assert_eq v5.0.1 "$(_snell_latest_stable)"
fixture_kb=$'# Snell\nhttps://dl.nssurge.com/snell/snell-server-v6.0.0-linux-amd64.zip\n### v6.0.0\ncurrently available for beta testing\nhttps://dl.nssurge.com/snell/snell-server-v5.0.2-linux-amd64.zip\n### v5.0.2\nStable maintenance release.'
assert_eq v5.0.2 "$(_snell_latest_stable)"
fixture_curl_failure=1
assert_eq "$SNELL_VERSION_OVERRIDE" "$(_snell_latest_stable)"
fixture_curl_failure=0

# Fresh menu-7 installs default to V6 and still offer stable V5.
remove_snell; reset_calls
install_snell <<< '' > "$test_dir/install-v6.out"
assert grep -Fq "install:snell:https://dl.nssurge.com/snell/snell-server-${SNELL_BETA_VERSION}-linux-${SNELL_ARCH}.zip" "$test_dir/calls"
reset_calls
install_snell <<< 2 > "$test_dir/install-v5.out"
assert grep -Fq "install:snell:https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION_OVERRIDE}-linux-${SNELL_ARCH}.zip" "$test_dir/calls"

# Reinstall keeps the actual installed version, not a stale marker or a new default.
assert grep -Fq '_snell_reinstall' < <(declare -f _snell_manage_menu)
for installed in v5.0.0 v6.0.0; do
    write_snell "$installed"
    printf 'v4.1.1\n' > "$SNELL_VERSION_FILE"; chmod 600 "$SNELL_VERSION_FILE"
    reset_calls
    _snell_reinstall > "$test_dir/reinstall.out"
    assert grep -Fq "install:snell:https://dl.nssurge.com/snell/snell-server-${installed}-linux-${SNELL_ARCH}.zip" "$test_dir/calls"
done
write_snell_output 'unrecognised Snell build'
rm -f "$SNELL_VERSION_FILE"; reset_calls
_snell_reinstall > "$test_dir/reinstall-unknown.out" 2>&1 || true
reject grep -q '^install:' "$test_dir/calls"

# Menu 16: blank stays on the installed major and never downgrades; explicit 1 opts into V6 beta.
fixture_kb=$'https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip\nhttps://dl.nssurge.com/snell/snell-server-v6.0.0-linux-amd64.zip\n### v6.0.0\ncurrently available for beta testing'
write_snell v5.0.0; reset_calls
update_service snell <<< $'\n' > "$test_dir/update-v5.out"
assert grep -Fq "install:snell:https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-${SNELL_ARCH}.zip" "$test_dir/calls"
write_snell v5.0.0; reset_calls
update_service snell <<< $'1\n' > "$test_dir/update-v6.out"
assert grep -Fq "install:snell:https://dl.nssurge.com/snell/snell-server-${SNELL_BETA_VERSION}-linux-${SNELL_ARCH}.zip" "$test_dir/calls"
for installed in v5.0.2 v6.0.0; do
    write_snell "$installed"; reset_calls
    update_service snell <<< $'\n' > "$test_dir/no-downgrade.out" || true
    reject grep -q '^install:' "$test_dir/calls"
done

# Cached/background notices only expose a genuine higher stable release.
write_snell v5.0.0
printf 'snell:v5.0.1\n' > "$UPDATE_CHECK_CACHE"
assert_eq v5.0.1 "$(get_cached_latest_version snell)"
for pair in 'v5.0.2:snell:v5.0.1' 'v6.0.0:snell:v5.0.1' 'v5.0.0:snell:v6.0.0'; do
    installed=${pair%%:*}; cache=${pair#*:}
    write_snell "$installed"; printf '%s\n' "$cache" > "$UPDATE_CHECK_CACHE"
    assert_eq '' "$(get_cached_latest_version snell)"
done

run_background_check() {
    local installed=$1
    write_snell "$installed"; rm -f "$SNELL_VERSION_FILE" "$UPDATE_CHECK_CACHE"
    check_updates_background
    wait
    [[ -f $UPDATE_CHECK_CACHE ]] || fail 'background check did not write its cache'
}
fixture_kb='https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip'
run_background_check v5.0.0
assert_eq snell:v5.0.1 "$(cat "$UPDATE_CHECK_CACHE")"
for installed in v5.0.1 v5.0.2 v6.0.0; do
    run_background_check "$installed"
    assert_eq '' "$(cat "$UPDATE_CHECK_CACHE")"
done

assert test ! -s "$test_dir/forbidden"
printf 'PASS: Snell V5/V6 detection, safe markers, beta filtering, install/reinstall choices and no downgrade\n'
