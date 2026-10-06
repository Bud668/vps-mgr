#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-ipv6.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-ipv6.* ]] && rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/etc/network/interfaces.d" "$test_dir/etc/sysctl.d"
# No test writes host network files. Real sysctl is allowed only in a disposable netns.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/network/interfaces|$test_dir/etc/network/interfaces|g" \
    -e "s|/etc/sysctl|$test_dir/etc/sysctl|g" "$repo_dir/vps-mgr.sh")
log_message() { :; }
_exim_ipv6_compat() { :; } # Exim compatibility has its own isolated regression check.
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
for caller in _do_full_init toggle_ipv6; do
    [[ $(declare -f "$caller" | grep -c '_write_disable_ipv6_conf') == 1 ]] || exit 1
done
if [[ ${1:-} == --netns ]]; then
    [[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
        echo 'Run: unshare --net bash tests/test_ipv6.sh --netns' >&2; exit 1;
    }
else
    sysctl() {
        [[ $* == '-w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1' ]]
    }
fi
printf 'auto eth0\niface eth0 inet dhcp\niface eth0 inet6 static\n    address 2001:db8::1/64\n    gateway 2001:db8::ff\n' > "$test_dir/etc/network/interfaces"
printf 'iface eth1 inet6 dhcp\n    accept_ra 1\niface eth1 inet dhcp\n' > "$test_dir/etc/network/interfaces.d/extra"
printf 'net.ipv6.conf.all.disable_ipv6 = 0\nnet.ipv4.tcp_syncookies = 1\n' > "$test_dir/etc/sysctl.conf"
before=$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")
SSH_CONNECTION='2001:db8::2 1234 2001:db8::1 22'
if _write_disable_ipv6_conf; then echo 'IPv6 SSH was not protected'; exit 1; fi
assert test ! -e "$test_dir/etc/sysctl.d/99-disable-ipv6.conf"
assert test "$before" = "$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")"
SSH_CONNECTION='192.0.2.2 1234 192.0.2.1 22'
(
    sysctl() { return 1; }
    if _write_disable_ipv6_conf; then echo 'Denied sysctl reported success'; exit 1; fi
    assert test ! -e "$test_dir/etc/sysctl.d/99-disable-ipv6.conf"
    assert test "$before" = "$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")"
)
_write_disable_ipv6_conf
assert test "$(grep -c 'disable_ipv6 = 1' "$test_dir/etc/sysctl.d/99-disable-ipv6.conf")" = 3
assert test "$(cat "$test_dir/etc/sysctl.conf")" = 'net.ipv4.tcp_syncookies = 1'
assert grep -q '^iface eth0 inet dhcp' "$test_dir/etc/network/interfaces"
assert grep -q '^#V6OFF# iface eth1 inet6 dhcp' "$test_dir/etc/network/interfaces.d/extra"
disabled=$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")
_write_disable_ipv6_conf
assert test "$disabled" = "$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")"
_ipv6_ifaces_on
assert test "$before" = "$(sha256sum "$test_dir/etc/network/interfaces" "$test_dir/etc/network/interfaces.d/extra")"
if [[ ${1:-} == --netns ]]; then
    ip link add v6-test type dummy
    ip link set v6-test up
    for iface in all default lo v6-test; do
        assert test "$(sysctl -n "net.ipv6.conf.$iface.disable_ipv6")" = 1
    done
    # Simulate the next boot: saved settings must disable IPv6 again.
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sysctl -p "$test_dir/etc/sysctl.d/99-disable-ipv6.conf" >/dev/null
    assert test "$(sysctl -n net.ipv6.conf.v6-test.disable_ipv6)" = 1
fi
echo 'PASS: default-off entry points, IPv6 SSH guard, permission errors, reversible interfaces and persistence'
