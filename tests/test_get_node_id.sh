#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Load the real function definitions without entering the interactive main loop.
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$repo_dir/vps-mgr.sh")

test_name=""
test_cc=""
test_ip=""
test_public_ip=""

_tg_cfg_get() {
    [[ "$2" == "SERVER_NAME" ]] && printf '%s' "$test_name"
}

_read_cache_value() {
    case "$1" in
        SERVER_COUNTRY_CODE) printf '%s' "$test_cc" ;;
        SERVER_IP)           printf '%s' "$test_ip" ;;
    esac
}

get_public_ip() {
    printf '%s' "$test_public_ip"
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

test_name="Node-LA" test_cc="US" test_ip="203.0.113.42"
assert_eq "🇺🇸 #Node_LA" "$(get_node_id)" "ASCII name as Telegram tag"
assert_eq "🇺🇸 Node_LA" "$(get_node_id plain)" "ASCII name in terminal"

test_name="香港节点"
assert_eq "香港节点" "$(get_node_id)" "display name containing non-ASCII characters"

test_name="" test_cc="HK" test_ip="198.51.100.79"
assert_eq "#HK_79" "$(get_node_id)" "cache fallback as Telegram tag"
assert_eq "HK_79" "$(get_node_id plain)" "cache fallback in terminal"

test_cc="" test_ip="" test_public_ip="192.0.2.9"
assert_eq "#UN_9" "$(get_node_id)" "public IP fallback"

test_public_ip="unavailable"
assert_eq "UN" "$(get_node_id plain)" "offline fallback"

# Exercise the original failure site without touching systemd or DDNS state.
clear() { :; }
systemctl() { return 1; }
test_name="Node-LA" test_cc="US" test_ip="203.0.113.42"
DDNS_RECORD_NAME="ddns.example.com"
DDNS_INTERVAL_SEC="10"
menu_output=$(ddns_show_menu)
[[ "$menu_output" == *"机器名称 : 🇺🇸 Node_LA"* ]] || {
    printf 'FAIL: DDNS menu did not render the machine name\n%s\n' "$menu_output" >&2
    exit 1
}

sent_message=""
send_telegram() { sent_message="$1"; }
ddns_log() { :; }
ddns_notify_change "FirstRun" "203.0.113.42"
[[ "$sent_message" == *"👤 主机: 🇺🇸 #Node_LA"* ]] || {
    printf 'FAIL: DDNS notification did not render the Telegram node tag\n%s\n' "$sent_message" >&2
    exit 1
}

printf 'PASS: get_node_id regression tests\n'
