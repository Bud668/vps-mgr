#!/usr/bin/env bash
set -euo pipefail
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
    echo 'Run: unshare --net bash tests/test_nftables.sh' >&2; exit 1;
}
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-nft-test.XXXXXXXX)
peer_pid="" server_pid=""
cleanup_test() {
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z "$peer_pid" ]] || kill "$peer_pid" 2>/dev/null || true
    [[ $test_dir == /tmp/vps-mgr-nft-test.* ]] && rm -rf "$test_dir"
}
trap cleanup_test EXIT
# Redirect every persistent path touched by the real firewall/quota functions.
# shellcheck source=/dev/null
source <(sed \
    -e '/^main "\$@"$/d' \
    -e "s|^readonly WORK_DIR=.*|readonly WORK_DIR=\"$test_dir/state\"|" \
    -e "s|^readonly FW_CONF=.*|readonly FW_CONF=\"$test_dir/rules.nft\"|" \
    -e "s|^readonly FW_PENDING=.*|readonly FW_PENDING=\"$test_dir/pending\"|" \
    -e "s|^readonly FW_LOCK=.*|readonly FW_LOCK=\"$test_dir/lock\"|" \
    "$repo_dir/vps-mgr.sh")
log_message() { :; }
_fw_install_unit() { :; }
install_quota_services() { :; }
systemd-run() { :; }
systemctl() {
    case "$1" in
        is-active) [[ $* == *vps-mgr-firewall-revert.timer* || $* == *quota-check.timer* ]] ;;
        enable|disable|stop) return 0 ;;
        *) printf 'Unexpected service write: %s\n' "$*" >&2; return 99 ;;
    esac
}
get_current_ssh_port() { echo 22; }
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
SSH_CONNECTION='192.0.2.2 10000 192.0.2.1 22'
export SSH_CONNECTION
do_init_firewall
token=$(head -1 "$FW_PENDING")
if _fw_confirm "$token" >/dev/null 2>&1; then echo 'Same-session confirmation accepted' >&2; exit 1; fi
SSH_CONNECTION='192.0.2.2 10001 192.0.2.1 22'
_fw_confirm "$token"
assert test ! -e "$FW_PENDING"
assert test "$(stat -c %a "$FW_CONF")" = 600
nft add table inet unrelated_test
open_firewall_port 24073
open_firewall_port 24073
assert _fw_has_element tcp_ports 24073
assert _fw_has_element udp_ports 24073

mkdir -p "$QUOTA_DIR"
printf '24073|test|104857600|-|0\n24074|socks|104857600|-|0\n' > "$QUOTA_CONFIG"
: > "$QUOTA_DATA"
quota_init
assert test "$(quota_get_port_bytes 24073)" = '0 0'
_sbx_socks_fw_apply 24074 192.0.2.2 2001:db8::2
before=$(nft -j list set inet "$FW_TABLE" tcp_ports)
if printf 'flush set inet %s tcp_ports\nadd element inet %s nonexistent { 9999 }\n' "$FW_TABLE" "$FW_TABLE" |
    _fw_apply >/dev/null 2>&1; then echo 'Invalid batch accepted' >&2; exit 1; fi
assert test "$before" = "$(nft -j list set inet "$FW_TABLE" tcp_ports)"

# Real IPv4/IPv6 packets from another disposable network namespace.
unshare --net sleep 55 &
peer_pid=$!
for _ in {1..50}; do
    [[ $(readlink "/proc/$peer_pid/ns/net") != "$(readlink /proc/self/ns/net)" ]] && break
    sleep 0.02
done
ip link set lo up
ip link add nft-test0 type veth peer name nft-test1
ip link set nft-test1 netns "$peer_pid"
ip addr add 192.0.2.1/24 dev nft-test0
ip -6 addr add 2001:db8::1/64 dev nft-test0 nodad
ip link set nft-test0 up
nsenter -t "$peer_pid" -n ip addr add 192.0.2.2/24 dev nft-test1
nsenter -t "$peer_pid" -n ip -6 addr add 2001:db8::2/64 dev nft-test1 nodad
nsenter -t "$peer_pid" -n ip link set nft-test1 up
python3 -c 'import socket,time
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
s.bind(("::",24073))
t=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
t.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
t.bind(("::",24074)); t.listen(32)
m=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
m.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
m.bind(("::",24076)); m.listen(32)
time.sleep(50)' &
server_pid=$!
send_packet() {
    nsenter -t "$peer_pid" -n python3 -c 'import socket,sys
v6=sys.argv[1]=="6"
s=socket.socket(socket.AF_INET6 if v6 else socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("2001:db8::2" if v6 else "192.0.2.2",30001))
s.sendto(b"quota-test",("2001:db8::1" if v6 else "192.0.2.1",int(sys.argv[2])))' "$1" "${2:-24073}"
    sleep 0.1
}
send_packet 4
read -r bytes4 _ < <(quota_get_port_bytes 24073)
assert test "$bytes4" -gt 0
send_packet 6
read -r bytes6 _ < <(quota_get_port_bytes 24073)
assert test "$bytes6" -gt "$bytes4"
quota_pause_port 24073 manual
open_firewall_port 24073
send_packet 4
send_packet 6
read -r paused_bytes _ < <(quota_get_port_bytes 24073)
assert test "$paused_bytes" = "$bytes6"
quota_resume_port 24073
send_packet 4
read -r resumed_bytes _ < <(quota_get_port_bytes 24073)
assert test "$resumed_bytes" -gt "$paused_bytes"

connect_socks() {
    nsenter -t "$peer_pid" -n python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET6 if sys.argv[1]=="6" else socket.AF_INET)
s.settimeout(0.3)
try: s.connect(("2001:db8::1" if sys.argv[1]=="6" else "192.0.2.1",24074))
except OSError: sys.exit(1)' "$1"
}
assert connect_socks 4
assert connect_socks 6
# Manually opening UDP must not bypass the SOCKS source restrictions.
open_firewall_port 24074
read -r socks_before _ < <(quota_get_port_bytes 24074)
send_packet 4 24074
read -r socks4 _ < <(quota_get_port_bytes 24074)
assert test "$socks4" -gt "$socks_before"
send_packet 6 24074
read -r socks6 _ < <(quota_get_port_bytes 24074)
assert test "$socks6" -gt "$socks4"
_fw_element add tcping_ports 24076
nsenter -t "$peer_pid" -n python3 -c 'import socket
for port in (22,24076):
    s=socket.socket(); s.settimeout(0.3)
    try: s.connect(("192.0.2.1",port))
    except OSError: pass
    s.close()'
# Sourced above; the later definition only injects a persistence failure.
# shellcheck disable=SC2218
_fw_persist
_sbx_socks_fw_apply 24074 192.0.2.2
open_firewall_port 24074
if connect_socks 6; then echo 'IPv6 bypassed SOCKS ACL' >&2; exit 1; fi
read -r socks_before _ < <(quota_get_port_bytes 24074)
send_packet 6 24074
read -r socks_after _ < <(quota_get_port_bytes 24074)
assert test "$socks_after" = "$socks_before"
_sbx_socks_fw_apply 24074
if connect_socks 4; then echo 'Empty SOCKS ACL allowed access' >&2; exit 1; fi
read -r socks_before _ < <(quota_get_port_bytes 24074)
send_packet 4 24074
read -r socks_after _ < <(quota_get_port_bytes 24074)
assert test "$socks_after" = "$socks_before"

# Native sets supersede existing conntrack ACCEPT, including global allowlists.
_fw_element add allow4 192.0.2.2
_fw_element add block4 192.0.2.2
send_packet 4
assert test "$(quota_get_port_bytes 24073)" = "$resumed_bytes 0"
_fw_element delete block4 192.0.2.2
printf 'add element inet %s cn4 { 192.0.2.0/24 }\nadd element inet %s cn6 { 2001:db8::/32 }\n' "$FW_TABLE" "$FW_TABLE" | _fw_apply
_fw_element add cn_ports 24073
send_packet 4
send_packet 6
assert test "$(quota_get_port_bytes 24073)" = "$resumed_bytes 0"
_fw_element delete cn_ports 24073

# A separate Fail2Ban-like native table can still reject an open service.
nft add chain inet unrelated_test ban '{ type filter hook input priority -1; policy accept; }'
nft add rule inet unrelated_test ban ip saddr 192.0.2.2 udp dport 24073 drop
send_packet 4
assert test "$(quota_get_port_bytes 24073)" = "$resumed_bytes 0"
persist_function=$(declare -f _fw_persist)
_fw_persist() { return 1; }
if _fw_element add tcp_ports 9999; then echo 'Persistence failure hidden'; exit 1; fi
if _fw_has_element tcp_ports 9999; then echo 'Failed change not rolled back'; exit 1; fi
assert test "$(quota_get_port_bytes 24073)" = "$resumed_bytes 0"
eval "$persist_function"

_quota_commit_port 24073 "$(date +%Y-%m)"
quota_pause_port 24073 manual
_fw_test_mode
assert _fw_has_element test_tcp 5201
assert test "$(quota_get_port_bytes 24073)" = "$resumed_bytes 0"
# Simulate lost kernel rules/reboot; persisted ACL and paused state survive,
# temporary ports stay closed, baseline resets without losing accrued traffic.
nft delete table inet "$FW_TABLE"
_fw_ensure
quota_init
assert _fw_has_element paused_ports 24073
if _fw_has_element test_tcp 5201; then echo 'Temporary opening persisted' >&2; exit 1; fi
assert test "$(quota_get_port_bytes 24073)" = '0 0'
_quota_commit_port 24073 "$(date +%Y-%m)"
read -r _ _ _ total_in _ paused _ < <(_quota_read_data 24073)
assert test "$total_in" = "$resumed_bytes"
assert test "$paused" = 1
assert nft list table inet unrelated_test
_state_locked _quota_forget 24073
if _fw_has_element paused_ports 24073 || nft list counter inet "$FW_TABLE" q24073_in >/dev/null 2>&1 ||
    grep -q '^24073|' "$QUOTA_CONFIG" "$QUOTA_DATA"; then
    echo 'Deleted quota retained state' >&2; exit 1
fi
echo 'PASS: dual-stack quota/ACL/CN/blacklist enforcement, recovery, SSH confirmation, atomic rollback, scoped ownership'
