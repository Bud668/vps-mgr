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
    -e "s|/usr/share/zoneinfo/Asia/Shanghai|$test_dir/zoneinfo/Asia/Shanghai|g" \
    -e "s|/var/log/|$test_dir/log/|g" "$repo_dir/vps-mgr.sh")
mkdir -p "$test_dir/etc/apt/apt.conf.d" "$test_dir/etc/systemd/system" "$test_dir/run" \
    "$test_dir/var-run" "$test_dir/log/unattended-upgrades" "$test_dir/zoneinfo/Asia" "$WORK_DIR"
touch "$test_dir/zoneinfo/Asia/Shanghai"
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
# A slim image must acquire Shanghai timezone data before configuring any timer.
for timezone_result in failed missing installed; do
(
    : > "$test_dir/calls"
    rm "$test_dir/zoneinfo/Asia/Shanghai" 2>/dev/null || true
    config_before=$(sha256sum "$test_dir/etc/apt/apt.conf.d/99vps-mgr-security-updates" 2>/dev/null || true)
    _apt_quiet() {
        record "apt-quiet $*"
        [[ $* == '安装上海时区数据 install -y -qq tzdata' ]] || return 99
        case $timezone_result in
            failed) return 1 ;;
            missing) return 0 ;;
            installed) touch "$test_dir/zoneinfo/Asia/Shanghai" ;;
        esac
    }
    if [[ $timezone_result == installed ]]; then
        _install_security_updates
        assert test -r "$test_dir/zoneinfo/Asia/Shanghai"
        assert grep -q 'systemctl enable --now vps-mgr-security-reboot.timer' "$test_dir/calls"
    else
        reject _install_security_updates
        assert test "$config_before" = "$(sha256sum "$test_dir/etc/apt/apt.conf.d/99vps-mgr-security-updates" 2>/dev/null || true)"
        assert test ! -e "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
        reject grep -q '^systemctl ' "$test_dir/calls"
    fi
    assert grep -qx 'apt-quiet 安装上海时区数据 install -y -qq tzdata' "$test_dir/calls"
)
done
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
for timer in apt-daily.timer apt-daily-upgrade.timer vps-mgr-security-reboot.timer; do
    assert grep -qx "systemctl is-active --quiet $timer" "$test_dir/calls"
    assert grep -qx "systemctl is-enabled --quiet $timer" "$test_dir/calls"
done
if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service" \
        "$test_dir/etc/systemd/system/vps-mgr-security-reboot.service" \
        "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
fi
assert grep -Fxq 'OnCalendar=*-*-* 04:00:00 Asia/Shanghai' "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
assert grep -Fxq 'Persistent=false' "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
assert grep -Fxq 'RandomizedDelaySec=0' "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
assert grep -Fxq 'AccuracySec=1s' "$test_dir/etc/systemd/system/vps-mgr-security-reboot.timer"
assert grep -Fq 'security-update-reboot' "$test_dir/etc/systemd/system/vps-mgr-security-reboot.service"

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
    for failure in apt_active apt_enabled reboot_enable reboot_active reboot_enabled none; do
        reboot_timer_enabled=0
        systemctl() {
            case "$*" in
                'is-active --quiet apt-daily-upgrade.timer') [[ $failure != apt_active ]] ;;
                'is-enabled --quiet apt-daily-upgrade.timer') [[ $failure != apt_enabled ]] ;;
                'enable --now vps-mgr-security-reboot.timer --quiet')
                    reboot_timer_enabled=1; [[ $failure != reboot_enable ]] ;;
                'is-active --quiet vps-mgr-security-reboot.timer') [[ $failure != reboot_active ]] ;;
                'is-enabled --quiet vps-mgr-security-reboot.timer') [[ $failure != reboot_enabled ]] ;;
                'disable --now vps-mgr-security-reboot.timer') reboot_timer_enabled=0 ;;
                *) return 0 ;;
            esac
        }
        if [[ $failure == none ]]; then
            _install_security_updates
            assert test "$reboot_timer_enabled" = 1
        else
            reject _install_security_updates
            assert test "$reboot_timer_enabled" = 0
        fi
    done
)
rm "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
mkdir "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
reject _install_security_updates
rmdir "$test_dir/etc/systemd/system/vps-mgr-security-update-alert.service"
_install_security_updates
_security_updates_menu <<< 2
assert grep -q 'systemctl disable --now vps-mgr-security-reboot.timer' "$test_dir/calls"
assert grep -Fqx 'APT::Periodic::Unattended-Upgrade "0";' < <(apt-config dump)
reject _security_updates_policy_ok
_security_updates_menu <<< 1
assert _security_updates_policy_ok
(
    systemctl() {
        case $1 in disable|cat) return 1 ;; *) return 0 ;; esac
    }
    # An older installation has no reboot unit, but must still allow stopping updates.
    _security_updates_menu <<< 2
    assert grep -Fqx 'APT::Periodic::Unattended-Upgrade "0";' < <(apt-config dump)
)
_install_security_updates
printf 'APT::Periodic::Unattended-Upgrade "1";\n' > "$test_dir/etc/apt/apt.conf.d/zz-provider"
reject _security_updates_menu <<< 2
rm "$test_dir/etc/apt/apt.conf.d/zz-provider"
_install_security_updates

# Log timestamps are local like unattended-upgrades; old errors must not alert.
get_node_id() { echo 'test-server'; }
send_telegram() { printf '%s\n' "$1" >> "$test_dir/messages"; }
journalctl() { printf '%s\n' "${fixture_journal:-}"; }
printf 'TG_BOT_TOKEN=123:offline\nTG_CHAT_HUB=-100123\nTG_THREAD_SSH=4\nTG_THREAD_UPDATE=1004\n' > "$TG_CONF"
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
assert test "$TG_THREAD_ID" = 1004
before=$(sha256sum "$test_dir/messages")
_security_updates_notify failed
assert test "$before" = "$(sha256sum "$test_dir/messages")"
# A changed destination must receive its first notice even on the same day.
sed -i 's/TG_THREAD_UPDATE=1004/TG_THREAD_UPDATE=1005/' "$TG_CONF"
_security_updates_notify failed
assert test "$TG_THREAD_ID" = 1005
assert test "$before" != "$(sha256sum "$test_dir/messages")"
before=$(sha256sum "$test_dir/messages")
sed -i 's/TG_CHAT_HUB=-100123/TG_CHAT_HUB=-100456/' "$TG_CONF"
_security_updates_notify failed
assert test "$TG_CHAT_ID" = -100456
assert test "$before" != "$(sha256sum "$test_dir/messages")"
# Missing/invalid update topic never falls back to the SSH topic or general chat.
for thread in '' 0 bad; do
    before=$(sha256sum "$test_dir/messages" "$WORK_DIR/security-update.notice")
    sed -i "s/^TG_THREAD_UPDATE=.*/TG_THREAD_UPDATE=$thread/" "$TG_CONF"
    _security_updates_notify failed
    assert test "$before" = "$(sha256sum "$test_dir/messages" "$WORK_DIR/security-update.notice")"
done
sed -i 's/^TG_THREAD_UPDATE=.*/TG_THREAD_UPDATE=1004/' "$TG_CONF"
touch "$test_dir/var-run/reboot-required"
_security_updates_notify completed
assert grep -q '系统更新待重启生效' "$test_dir/messages"
assert grep -q '04:00' "$test_dir/messages"
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
(
    _security_reboot_enabled() { return 1; }
    before=$(sha256sum "$test_dir/messages")
    _security_updates_notify completed
    assert test "$before" != "$(sha256sum "$test_dir/messages")"
    assert grep -q '定时重启未启用' "$test_dir/messages"
)
rm "$test_dir/var-run/reboot-required" "$WORK_DIR/security-update.notice"
INVOCATION_ID=123abc
fixture_journal='download updated metadata (error)'
_security_updates_notify download
assert grep -q '1:0$' "$WORK_DIR/security-update.notice"
rm "$TG_CONF" "$WORK_DIR/security-update.notice"
_security_updates_notify failed
assert test ! -e "$WORK_DIR/security-update.notice"

# Timer scheduling and manual invocations share the same guards; none can reboot here.
(
    for timer_state in enabled disabled inactive; do
        systemctl() {
            case $1 in
                is-enabled) [[ $timer_state != disabled ]] ;;
                is-active) [[ $timer_state != inactive ]] ;;
                *) return 99 ;;
            esac
        }
        if [[ $timer_state == enabled ]]; then assert _security_reboot_enabled
        else reject _security_reboot_enabled; fi
    done
)
(
    _security_updates_policy_ok() { [[ $scenario != policy_disabled ]]; }
    _security_reboot_enabled() { [[ $scenario != timer_disabled ]]; }
    date() {
        [[ $* == +%H:%M && $TZ == Asia/Shanghai ]] || return 99
        printf '%s\n' "$fixture_time"
    }
    python3() { cat >/dev/null; record lock-check; }
    systemctl() {
        [[ $1 == show ]] || return 99
        [[ $scenario != unreadable ]] || return 1
        if [[ $2 == "$busy_unit" ]]; then printf '%s\n' "$fixture_state"
        else echo inactive; fi
    }
    for scenario in ready no_marker policy_disabled timer_disabled before after active activating deactivating failed unknown unreadable; do
        for busy_unit in apt-daily.service apt-daily-upgrade.service; do
            : > "$test_dir/calls"
            fixture_time=04:00; fixture_state=inactive
            touch "$test_dir/var-run/reboot-required"
            case $scenario in
                no_marker) rm "$test_dir/var-run/reboot-required" ;;
                before) fixture_time=03:59 ;;
                after) fixture_time=04:01 ;;
                active|activating|deactivating|failed) fixture_state=$scenario ;;
                unknown) fixture_state='' ;;
            esac
            if [[ $scenario == unreadable ]]; then reject _security_updates_reboot
            else _security_updates_reboot; fi
            if [[ $scenario == ready ]]; then assert grep -qx lock-check "$test_dir/calls"
            else reject grep -qx lock-check "$test_dir/calls"; fi
        done
    done
)

# Run the production lock checker against temporary files, with all reboot calls intercepted.
python3 - "$repo_dir/vps-mgr.sh" "$test_dir" <<'PY'
import fcntl
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[2]) / 'reboot-locks'
root.mkdir()
script = Path(sys.argv[1]).read_text()
code = script.split("<<'SECURITY_REBOOT_PY'\n", 1)[1].split('\nSECURITY_REBOOT_PY', 1)[0]
locks = [
    ('/var/lib/apt/daily_lock', 'flock'),
    ('/var/lib/dpkg/lock-frontend', 'lockf'),
    ('/var/lib/dpkg/lock', 'lockf'),
    ('/var/lib/apt/lists/lock', 'lockf'),
    ('/var/cache/apt/archives/lock', 'lockf'),
    ('/var/run/unattended-upgrades.lock', 'lockf'),
]
mapped = []
for original, kind in locks:
    path = root / original.lstrip('/')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    mapped.append((str(path), kind))
    code = code.replace('"' + original + '"', repr(str(path)))
marker = root / 'var/run/reboot-required'
code = code.replace('"/var/run/reboot-required"', repr(str(marker)))
checker = root / 'checker.py'
checker.write_text(code)
requests = root / 'requests'
worker = r'''
import json, os, subprocess, sys
from pathlib import Path
from unittest.mock import patch
root, checker, request, locks, scenario = sys.argv[1:]
original_open, original_run = os.open, subprocess.run
def guarded_open(path, *args, **kwargs):
    assert os.path.commonpath([root, os.path.abspath(path)]) == root, path
    return original_open(path, *args, **kwargs)
def audit(event, args):
    if event == 'subprocess.Popen':
        assert args[0] == sys.executable, 'Unexpected process: ' + repr(args[0])
    assert event != 'os.system', 'Unexpected shell command'
sys.addaudithook(audit)
def reboot(command, **kwargs):
    if command == ['dpkg', '--audit']:
        assert kwargs.get('capture_output') is True and kwargs.get('text') is True
        assert kwargs.get('timeout') == 30
        if scenario == 'audit_incomplete':
            return subprocess.CompletedProcess(command, 0, 'half-configured package', '')
        if scenario == 'audit_failed':
            return subprocess.CompletedProcess(command, 1, '', 'audit failed')
        return subprocess.CompletedProcess(command, 0, '', '')
    assert command == ['systemctl', 'reboot'] and kwargs.get('check') is True
    # A second process must find every package-manager lock still held here.
    probe = """
import fcntl, json, sys
for path, kind in json.loads(sys.argv[1]):
    with open(path, 'r+') as handle:
        try:
            getattr(fcntl, kind)(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            continue
        raise AssertionError('Lock released before reboot: ' + path)
"""
    original_run([sys.executable, '-c', probe, locks], check=True)
    Path(request).write_text('reboot requested')
    if scenario == 'reboot_failure':
        raise subprocess.CalledProcessError(1, command)
    return subprocess.CompletedProcess(command, 0)
with patch('os.open', guarded_open), patch('subprocess.run', reboot):
    exec(compile(Path(checker).read_text(), checker, 'exec'), {'__name__': '__main__'})
'''
def run(scenario, expected=0, reboot=False):
    requests.unlink(missing_ok=True)
    result = subprocess.run([sys.executable, '-c', worker, str(root), str(checker), str(requests),
                             json.dumps(mapped), scenario], capture_output=True, text=True)
    assert result.returncode == expected, (scenario, result.stdout, result.stderr)
    assert requests.exists() == reboot, (scenario, result.stdout, result.stderr)

marker.touch()
run('ready', reboot=True)
run('audit_incomplete')
run('audit_failed')
for path, kind in mapped:
    with open(path, 'r+') as handle:
        getattr(fcntl, kind)(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run('busy_' + kind)
marker.unlink()
run('marker_removed')
marker.touch()
unsafe = Path(mapped[2][0])
unsafe.unlink()
unsafe.symlink_to(marker)
run('unsafe_lock', expected=1)
unsafe.unlink()
unsafe.touch()
run('reboot_failure', expected=1, reboot=True)
for path, kind in mapped:
    with open(path, 'r+') as handle:
        getattr(fcntl, kind)(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
print('PASS: pending-only reboot, all package locks held through submission, busy/error refusal')
PY
printf 'PASS: official-only APT policy, Shanghai reboot guards, update-topic routing and retryable notices\n'
