#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-dns-tests.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-dns-tests.* ]] && rm -rf "$test_dir"' EXIT
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' -e "s|/etc/|$test_dir/etc/|g" "$repo_dir/vps-mgr.sh")
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }

_install_dhcp_dns_hook
hook_dir=$test_dir/etc/dhcp/dhclient-enter-hooks.d
hook=$hook_dir/zz-vps-mgr-dns
assert test "$(stat -c %a "$hook")" = 644
sh -n "$hook"
before=$(sha256sum "$hook")
_install_dhcp_dns_hook
assert test "$(sha256sum "$hook")" = "$before"
for operation in mkdir mktemp cat chmod mv; do
(
    eval "$operation() { return 1; }"
    reject _install_dhcp_dns_hook
)
    assert test "$(sha256sum "$hook")" = "$before"
    reject compgen -G "$hook_dir/.vps-mgr-dns.*"
done
rm "$hook"
mkdir "$hook"
reject _install_dhcp_dns_hook 2>/dev/null
assert test -z "$(ls -A "$hook")"
rmdir "$hook"
_install_dhcp_dns_hook

# Source the distro's real hook loader and DNS function, never its network event handlers.
dhclient_script=${DHCLIENT_SCRIPT:-/sbin/dhclient-script}
assert test -r "$dhclient_script"
awk '/^case "\$reason" in$/ {found=1; exit} {print} END {if (!found) exit 1}' \
    "$dhclient_script" | sed "s|/etc/|$test_dir/etc/|g" > "$test_dir/dhclient-prefix"
assert grep -q '^make_resolv_conf()' "$test_dir/dhclient-prefix"
assert grep -q '^run_hookdir .*dhclient-enter-hooks.d' "$test_dir/dhclient-prefix"
reject grep -q '^case "\$reason" in' "$test_dir/dhclient-prefix"
printf 'other_hook_ran=yes\n' > "$hook_dir/aa-unrelated-hook"
touch "$test_dir/etc/fstab"
export test_dir
for scenario in cf google unlocked unmanaged symlink missing attr_fail indexed; do
    export scenario
    rm -f "$test_dir/etc/resolv.conf"
    printf '# Managed by vps-mgr DNS\nnameserver 1.1.1.1\nnameserver 1.0.0.1\n' > "$test_dir/etc/resolv.conf"
    case $scenario in
        google) printf '# Managed by vps-mgr DNS\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$test_dir/etc/resolv.conf" ;;
        unmanaged) printf 'nameserver 192.0.2.53\n' > "$test_dir/etc/resolv.conf" ;;
        symlink) mv "$test_dir/etc/resolv.conf" "$test_dir/resolved"; ln -s "$test_dir/resolved" "$test_dir/etc/resolv.conf" ;;
        missing) rm "$test_dir/etc/resolv.conf" ;;
    esac
    # dash executes the generated POSIX hook; immutable flags are mocked so CI needs no host privileges.
    sh <<'SH'
set -e
lsattr() {
    case $scenario in
        attr_fail) return 1 ;;
        unlocked) printf '%s\n' '--------------e------- resolv.conf' ;;
        indexed) printf '%s\n' '----------I---e------- resolv.conf' ;;
        *) printf '%s\n' '----i---------e------- resolv.conf' ;;
    esac
}
new_ip_address=192.0.2.10
new_routers=192.0.2.1
new_domain_name_servers=192.0.2.53
new_interface_mtu=1500
reason=RENEW
before=$(cat "$test_dir/etc/resolv.conf" 2>/dev/null || :)
. "$test_dir/dhclient-prefix"
[ "$other_hook_ran" = yes ]
make_resolv_conf
[ "$new_ip_address" = 192.0.2.10 ] && [ "$new_routers" = 192.0.2.1 ]
[ "$new_domain_name_servers" = 192.0.2.53 ] && [ "$new_interface_mtu" = 1500 ]
[ "$reason" = RENEW ]
case $scenario in
    cf|google) [ "$(cat "$test_dir/etc/resolv.conf")" = "$before" ] ;;
    *) grep -qx 'nameserver 192.0.2.53' "$test_dir/etc/resolv.conf" ;;
esac
SH
done
"${MTR_BIN:-mtr}" --version
echo 'PASS: DHCP DNS hook, atomic install, native resolver behavior and CLI mtr'
