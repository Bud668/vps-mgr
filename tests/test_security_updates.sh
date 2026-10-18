#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-security-tests.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-security-tests.* ]] && rm -rf "$test_dir"' EXIT
# No packages are installed and no live units are changed, even when run as root.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e "s|/var/run/|$test_dir/var-run/|g" -e "s|/run/|$test_dir/run/|g" \
    -e "s|/var/log/|$test_dir/log/|g" "$repo_dir/vps-mgr.sh")
mkdir -p "$test_dir/etc/apt/apt.conf.d" "$test_dir/etc/systemd/system" "$test_dir/run" \
    "$test_dir/var-run" "$test_dir/log/unattended-upgrades" "$WORK_DIR"
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
log_message() { record "log $*"; }
realpath() { printf '%s/vps-mgr.sh\n' "$repo_dir"; }
systemctl() { record "systemctl $*"; }
apt-get() { echo 'FAIL: unexpected package install' >&2; return 99; }
unattended-upgrade() { echo 'FAIL: unexpected package update' >&2; return 99; }
reboot() { echo 'FAIL: unexpected reboot' >&2; return 99; }
curl() { echo 'FAIL: unexpected live notification' >&2; return 99; }
# Native APT parser, real distro defaults if installed, isolated override path.
cp /etc/os-release "$test_dir/etc/os-release"
cp /etc/apt/apt.conf.d/* "$test_dir/etc/apt/apt.conf.d/"
# Ubuntu's Docker-only override disables native APT jobs. It is not a VPS
# default; remove it only from this fixture, and test conflicting policies below.
rm -f "$test_dir/etc/apt/apt.conf.d/docker-disable-periodic-update"
printf 'Dir::Etc::main "%s/no-main.conf";\nDir::Etc::parts "%s/etc/apt/apt.conf.d";\n' \
    "$test_dir" "$test_dir" > "$test_dir/apt-isolated.conf"
apt-config() {
    APT_CONFIG="$test_dir/apt-isolated.conf" command apt-config "$@"
}
_install_security_updates
assert _security_updates_policy_ok
if [[ -f /usr/bin/unattended-upgrade ]]; then
    # Use the package's real origin matcher, never its upgrade entry point.
    APT_CONFIG="$test_dir/apt-isolated.conf" /usr/bin/python3 - <<'PY'
import apt_pkg
import runpy
from types import SimpleNamespace
apt_pkg.init()
ua = runpy.run_path('/usr/bin/unattended-upgrade', run_name='policy_test')
allowed = ua['get_allowed_origins']()
codename = ua['DISTRO_CODENAME']
def check(origin, archive, label, expected):
    release = SimpleNamespace(origin=origin, archive=archive, label=label,
                              codename=archive, component='main', site='test.invalid')
    assert ua['is_allowed_origin'](release, allowed) == expected, (release, allowed)
check('Debian', codename + '-security', 'Debian-Security', True)
check('Ubuntu', codename + '-security', 'Ubuntu', True)
check('Debian', codename, 'Debian', False)
check('Ubuntu', codename + '-updates', 'Ubuntu', False)
check('XanMod', codename + '-security', 'XanMod', False)
check('Untrusted', codename + '-security', 'Ubuntu', False)
PY
fi
assert grep -q 'security-update-notify failed' "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
assert grep -q 'ExecStartPost=-/bin/bash' "$test_dir/etc/systemd/system/apt-daily-upgrade.service.d/vps-mgr-notify.conf"
for timer in apt-daily.timer apt-daily-upgrade.timer; do
    assert grep -qx "systemctl is-active --quiet $timer" "$test_dir/calls"
    assert grep -qx "systemctl is-enabled --quiet $timer" "$test_dir/calls"
done
if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
fi

# A later admin/provider setting cannot silently broaden updates or allow reboot.
policy_file="$test_dir/etc/apt/apt.conf.d/99vps-mgr-security-updates"
for override in 'Unattended-Upgrade::Origins-Pattern:: "origin=Untrusted";' \
    'Unattended-Upgrade::Allowed-Origins:: "Debian:stable";' \
    'Unattended-Upgrade::Automatic-Reboot "true";' 'APT::Periodic::Enable "0";'; do
    before=$(sha256sum "$policy_file")
    printf '%s\n' "$override" > "$test_dir/etc/apt/apt.conf.d/zz-provider"
    reject _security_updates_policy_ok
    reject _install_security_updates
    assert test "$before" = "$(sha256sum "$policy_file")"
    rm "$test_dir/etc/apt/apt.conf.d/zz-provider"
done
(
    systemctl() { [[ $1 != is-enabled ]]; }
    reject _install_security_updates
)
rm "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
mkdir "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
reject _install_security_updates
rmdir "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
_install_security_updates
_security_updates_menu <<< 2
assert grep -Fqx 'APT::Periodic::Unattended-Upgrade "0";' < <(apt-config dump)
reject _security_updates_policy_ok
_security_updates_menu <<< 1
assert _security_updates_policy_ok
printf 'APT::Periodic::Unattended-Upgrade "1";\n' > "$test_dir/etc/apt/apt.conf.d/zz-provider"
reject _security_updates_menu <<< 2
rm "$test_dir/etc/apt/apt.conf.d/zz-provider"
_install_security_updates

# Log timestamps are local like unattended-upgrades; old errors must not alert.
get_node_id() { echo 'test-server'; }
send_telegram() { printf '%s\n' "$1" >> "$test_dir/messages"; }
journalctl() { printf '%s\n' "${fixture_journal:-}"; }
printf 'TG_BOT_TOKEN=123:offline\nTG_CHAT_HUB=-100123\nTG_THREAD_SSH=4\n' > "$TG_CONF"
touch "$test_dir/run/vps-mgr-security-update.started"
fixture_since=$(stat -c %Y "$test_dir/run/vps-mgr-security-update.started")
fixture_log="$test_dir/log/unattended-upgrades/unattended-upgrades.log"
printf '%s ERROR previous run\n' "$(date -d "@$((fixture_since - 3600))" '+%Y-%m-%d %H:%M:%S')" > "$fixture_log"
printf 'Traceback (most recent call last):\nold error details\n' >> "$fixture_log"
_security_updates_notify completed
assert test ! -e "$test_dir/messages"
printf '%s ERROR this run\n' "$(date -d "@$fixture_since" '+%Y-%m-%d %H:%M:%S')" >> "$fixture_log"
_security_updates_notify completed
assert grep -q '安装失败' "$test_dir/messages"
assert test "$TG_THREAD_ID" = 4
before=$(sha256sum "$test_dir/messages")
_security_updates_notify failed
assert test "$before" = "$(sha256sum "$test_dir/messages")"
touch "$test_dir/var-run/reboot-required"
_security_updates_notify completed
assert grep -q '系统更新待重启生效' "$test_dir/messages"
assert test -f "$test_dir/var-run/reboot-required"
assert test "$(stat -c %a "$WORK_DIR/security-update.notice")" = 600
(
    : > "$fixture_log"
    send_telegram() { return 1; }
    before=$(sha256sum "$WORK_DIR/security-update.notice")
    reject _security_updates_notify completed
    assert test "$before" = "$(sha256sum "$WORK_DIR/security-update.notice")"
)
_security_updates_notify completed
assert grep -q '0:1$' "$WORK_DIR/security-update.notice"
rm "$test_dir/var-run/reboot-required" "$WORK_DIR/security-update.notice"
INVOCATION_ID=123abc
fixture_journal='download updated metadata (error)'
_security_updates_notify download
assert grep -q '1:0$' "$WORK_DIR/security-update.notice"
rm "$TG_CONF" "$WORK_DIR/security-update.notice"
_security_updates_notify failed
assert test ! -e "$WORK_DIR/security-update.notice"
printf 'PASS: native official-only APT policy, timer persistence, disable/repair and failure/reboot notifications\n'
