#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-snell-realm.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-snell-realm.* ]] && rm -rf "$test_dir"' EXIT
# All configs and writes are private; network and service operations are stubbed.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e "s|/usr/local/|$test_dir/usr/local/|g" "$repo_dir/vps-mgr.sh")
mkdir -p "$REALM_CONFIG_DIR" "$SNELL_CONFIG_DIR" "$SBX_ST" "$WORK_DIR"
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
log_message() { :; }
_state_locked() { "$@"; }
chown() { :; }
ss() { :; }
_fw_has_element() { return 1; }
_fw_element() { record "$*"; }
open_firewall_port() { record "open $*"; }
get_country_code_for_ip() { echo JP; }
get_available_port() { echo 24073; }
_realm_safe_restart() { record restart; }
_realm_restart_hint() { record restart-hint; }
curl() { echo 'FAIL: unexpected network request' >&2; return 99; }
systemctl() { return 1; }
clear() { :; }
check_service_status() { echo '[-]'; }
get_installed_version() { echo '-'; }
get_cached_latest_version() { :; }
_get_bbr_version() { echo v1; }
uname() { echo test-kernel; }
sysctl() { echo 1; }
_fw_show_status() { :; }
_fw_test_deadline() { return 1; }
get_connection_stats() { echo '0:'; }
SERVER_IP=192.0.2.10
SERVER_COUNTRY_CODE=US
plain() { sed -E 's/\x1B\[[0-9;]*m//g'; }
reset_realm() {
    printf '{"endpoints":[]}\n' > "$REALM_CONFIG_FILE"
    printf '{}\n' > "$REALM_META_FILE"
    : > "$test_dir/calls"
}

# Imported protocol and mode survive metadata and produce the same immediate/dashboard line.
for policy in 1:default 2:default 3:default 4:default 5:default 6:default 6:unshaped 6:unsafe-raw; do
    reset_realm
    version=${policy%:*}; mode=${policy#*:}
    options="version=$version"
    [[ $mode == default ]] || options+=", mode=$mode"
    output=$(_process_realm_rule "Node = snell, 203.0.113.20, 443, psk=\"offline_key\", $options, listening=24073" | plain)
    assert jq -e --argjson v "$version" --arg m "$mode" \
        '.["24073"].snell_version == $v and .["24073"].snell_mode == $m' "$REALM_META_FILE"
    immediate=$(grep ' = snell,' <<< "$output")
    dashboard=$(show_menu | plain)
    assert grep -Fxq "$immediate" <<< "$dashboard"
    assert grep -Fq "version=$version" <<< "$immediate"
    if [[ $mode == default ]]; then
        [[ $immediate != *'mode='* ]] || { echo 'FAIL: default mode unexpectedly exported'; exit 1; }
    else assert grep -Fq "mode=$mode" <<< "$immediate"; fi
    assert test "$(stat -c %a "$REALM_META_FILE")" = 600
done
reset_realm
_process_realm_rule 'Explicit = snell, 203.0.113.21, 443, psk="offline_key", version = 6, mode = default, listening=24073' >/dev/null
assert jq -e '.["24073"].snell_version == 6 and .["24073"].snell_mode == "default"' "$REALM_META_FILE"

# Surge input without version means v1; historical saved metadata remains v5.
reset_realm
output=$(_process_realm_rule 'Default = snell, 203.0.113.21, 443, psk=offline_key, listening=24073' | plain)
assert grep -Fq 'version=1' <<< "$output"
assert jq -e '.["24073"].snell_version == 1' "$REALM_META_FILE"
jq '.["24073"] |= del(.snell_version, .snell_mode)' "$REALM_META_FILE" > "$test_dir/legacy.json"
mv "$test_dir/legacy.json" "$REALM_META_FILE"
output=$(show_menu | plain)
assert grep -Fq 'version=5, reuse=true, tfo=true' <<< "$output"

# Invalid options must fail before opening ports or changing either file.
for options in 'version=0' 'version=7' 'version=abc' 'version=' 'version 6' \
    'version=6, mode=' 'version=6, mode=bogus' 'version=5, mode=default' \
    'mode=unshaped' 'version=6, version=5' 'version=6, mode=unshaped, mode=unsafe-raw' \
    'version=6, listening=bad' 'version=6, listening=' 'version=6, psk=other'; do
    reset_realm
    before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
    if output=$(_process_realm_rule "Invalid = snell, 203.0.113.22, 443, psk=offline_key, $options" 2>&1); then
        echo "FAIL: accepted invalid options: $options"; exit 1
    fi
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
    assert test ! -s "$test_dir/calls"
done
for psk_option in 'psk="not_for_logs,tail"' 'psk=not_for_logs,tail' 'psk="not_for_logs\tail"' \
    'psk="not_for_logs"junk' "psk='not_for_logs\"tail'" 'psk="not_for_logs'; do
    reset_realm
    before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
    if output=$(_process_realm_rule "Invalid = snell, 203.0.113.22, 443, $psk_option, version=6" 2>&1); then
        echo 'FAIL: accepted ambiguous PSK'; exit 1
    fi
    [[ $output != *not_for_logs* ]] || { echo 'FAIL: rejected PSK exposed in error'; exit 1; }
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
    assert test ! -s "$test_dir/calls"
done

# Batch imports share the same parser and persisted export behavior.
reset_realm
output=$(add_realm_forward_advanced auto <<'NODES'
V6 = snell, 203.0.113.23, 443, psk=key6, version=6, mode=unshaped, listening=24073
V5 = snell, 203.0.113.24, 443, psk=key5, version=5, listening=24074
Bad = snell, 203.0.113.25, 443, psk=bad, version=7, listening=24075

NODES
)
assert grep -q '成功 2.*失败 1' <<< "$(plain <<< "$output")"
assert grep -qx restart "$test_dir/calls"
output=$(show_menu | plain)
assert grep -Eq 'V6 = snell, .*24073, .*version=6, mode=unshaped' <<< "$output"
assert grep -Eq 'V5 = snell, .*24074, .*version=5, reuse=true' <<< "$output"

# Existing port/remote reservations survive failed imports.
before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
for line in \
    'Occupied = snell, 203.0.113.26, 443, psk=key, version=6, listening=24073' \
    'Duplicate = snell, 203.0.113.23, 443, psk=key, version=6, listening=24076'; do
    if _process_realm_rule "$line" >/dev/null 2>&1; then echo 'FAIL: occupied endpoint replaced'; exit 1; fi
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
done
for failure in firewall metadata; do
(
    : > "$test_dir/calls"
    open_firewall_port() { record "open $*"; [[ $failure != firewall ]]; }
    mv() { [[ $failure != metadata || ${*: -1} != "$REALM_META_FILE" ]] && command mv "$@"; }
    if _process_realm_rule 'Rollback = snell, 203.0.113.26, 443, psk=key, version=6, mode=unsafe-raw, listening=24076' >/dev/null 2>&1; then
        echo 'FAIL: failed commit accepted'; exit 1
    fi
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
    assert grep -qx 'delete tcp_ports 24076' "$test_dir/calls"
    assert grep -qx 'delete udp_ports 24076' "$test_dir/calls"
)
done
backup_count=0
for backup in "$REALM_CONFIG_DIR"/.change.*; do
    [[ -d $backup ]] || continue
    assert cmp "$REALM_CONFIG_FILE" "$backup/old_config"
    assert cmp "$REALM_META_FILE" "$backup/old_meta"
    backup_count=$((backup_count + 1))
done
assert test "$backup_count" = 2

# Re-pasting an upgraded landing node changes only its existing Snell metadata.
reset_realm
_process_realm_rule 'Legacy = snell, 203.0.113.28, 443, psk=stable_key, version=5, listening=24073' >/dev/null
jq '.["24073"] |= (del(.snell_version, .snell_mode) + {custom:"preserve"})' "$REALM_META_FILE" > "$test_dir/legacy.json"
mv "$test_dir/legacy.json" "$REALM_META_FILE"
cp "$REALM_META_FILE" "$test_dir/metadata-before.json"
config_before=$(sha256sum "$REALM_CONFIG_FILE")
: > "$test_dir/calls"
output=$(add_realm_forward_advanced auto <<'NODES'
NewName = snell, 203.0.113.28, 443, psk=stable_key, version=6, mode=unsafe-raw

NODES
)
assert test "$config_before" = "$(sha256sum "$REALM_CONFIG_FILE")"
assert test ! -s "$test_dir/calls"
assert grep -q '无需重启 Realm' <<< "$output"
assert jq -e --slurpfile before "$test_dir/metadata-before.json" \
    '. == ($before[0] | .["24073"].snell_version = 6 | .["24073"].snell_mode = "unsafe-raw")' "$REALM_META_FILE"
assert test "$(stat -c %a "$REALM_META_FILE")" = 600
output=$(show_menu | plain)
assert grep -Eq 'Legacy = snell, .*24073, .*version=6, mode=unsafe-raw' <<< "$output"
before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
for options in 'psk=stable_key, version=6, mode=unsafe-raw' \
    'psk=changed_key, version=5' 'psk=stable_key, version=5, listening=24074' \
    'psk=stable_key'; do
    if _process_realm_rule "Conflict = snell, 203.0.113.28, 443, $options" >/dev/null 2>&1; then
        echo 'FAIL: duplicate without a permitted metadata change accepted'; exit 1
    fi
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
done
(
    mv() { return 1; }
    if _process_realm_rule 'Failed = snell, 203.0.113.28, 443, psk=stable_key, version=6, mode=unshaped' >/dev/null 2>&1; then
        echo 'FAIL: failed metadata-only update accepted'; exit 1
    fi
    assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
)
assert test ! -s "$test_dir/calls"
add_realm_forward_advanced auto >/dev/null <<'NODES'
Changed = snell, 203.0.113.28, 443, psk=stable_key, version=6, mode=unshaped, listening=24073
New = snell, 203.0.113.29, 443, psk=new_key, version=6, listening=24074

NODES
assert grep -qx restart "$test_dir/calls"
assert grep -qx 'open 24074' "$test_dir/calls"
[[ $(grep -c '^open ' "$test_dir/calls") == 1 ]] || { echo 'FAIL: metadata update reopened a port'; exit 1; }
assert jq -e '.["24073"].alias == "Legacy" and .["24073"].snell_mode == "unshaped"' "$REALM_META_FILE"

# Generic forwarding never gains Snell protocol metadata or a Snell client line.
reset_realm
_process_realm_rule 'ss://offline@203.0.113.27:8443#Generic' >/dev/null
assert jq -e '.["24073"].psk == "" and (.["24073"] | has("snell_version") | not)' "$REALM_META_FILE"
output=$(show_menu | plain)
assert grep -Fq 'Port 24073 -> 203.0.113.27:8443' <<< "$output"
[[ $output != *' = snell,'* ]] || { echo 'FAIL: generic forward exported as Snell'; exit 1; }
before=$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")
if _process_realm_rule 'NotSnell = snell, 203.0.113.27, 8443, psk=new_key, version=6' >/dev/null 2>&1; then
    echo 'FAIL: generic forwarding converted into Snell metadata'; exit 1
fi
assert test "$before" = "$(sha256sum "$REALM_CONFIG_FILE" "$REALM_META_FILE")"
printf 'PASS: Realm Snell versions/modes, single/batch exports, legacy metadata, rejection and rollback\n'
