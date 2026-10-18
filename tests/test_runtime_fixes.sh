#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-runtime-tests.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-runtime-tests.* ]] && rm -rf "$test_dir"' EXIT
# Exercise production functions with private files, real flock/jq, and no host services/network.
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' \
    -e "s|/etc/|$test_dir/etc/|g" -e "s|/opt/proxy-manager|$test_dir/state|g" \
    -e "s|/usr/local/|$test_dir/usr/local/|g" -e 's|^readonly SBX_BIN=.*|readonly SBX_BIN=fake_sbx|' \
    -e "s|/var/run/|$test_dir/var-run/|g" -e "s|/var/log/|$test_dir/log/|g" \
    -e "s|^readonly FW_LOCK=.*|readonly FW_LOCK=\"$test_dir/state.lock\"|" \
    -e 's|/dev/tty|/dev/stdin|g' "$repo_dir/vps-mgr.sh")
mkdir -p "$WORK_DIR" "$QUOTA_DIR" "$SBX_ETC" "$SBX_ST" "$REALM_CONFIG_DIR" \
    "$test_dir/etc/systemd/system" "$test_dir/etc/fail2ban/jail.d" "$test_dir/etc/apt/apt.conf.d"
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if "$@"; then printf 'FAIL: accepted %s\n' "$*" >&2; exit 1; fi; }
log_message() { :; }
record() { printf '%s\n' "$*" >> "$test_dir/calls"; }
_tg_permissions() { :; }
systemctl() { record "systemctl $*"; }
curl() { echo 'FAIL: unexpected network call' >&2; return 99; }
apt-get() { echo 'FAIL: unexpected package operation' >&2; return 99; }
reboot() { echo 'FAIL: unexpected reboot' >&2; return 99; }

# 1: only an actual affirmative reply (or a successfully read blank line) confirms.
for answer in y Y yes YES ''; do _confirm_reboot <<< "$answer" >/dev/null; done
for answer in n N no NO q Q; do reject _confirm_reboot <<< "$answer"; done
reject _confirm_reboot </dev/null
reject _confirm_reboot <<< 'invalid'
reject _confirm_reboot <<< $'invalid\nno'
_confirm_reboot <<< $'invalid\nyes' >/dev/null
for caller in _do_full_init do_system_update; do
    assert grep -q '_confirm_reboot' < <(declare -f "$caller")
done

# 2/7: direct-paste seed, comments, optional topics, trailing blanks, immediate q, EOF.
for scenario in full seeded minimal comments bracketed seeded_bracketed q mid_q bracketed_q invalid_token invalid_hub invalid_topic eof short_eof save_fail monitor_fail notify_fail; do
(
    : > "$test_dir/calls"
    _tg_api() { record api; printf '{"ok":true,"result":{"username":"offline_bot"}}'; }
    _setup_ssh_tg_monitor() { record monitor; [[ $scenario != monitor_fail ]]; }
    _tg_notify_configured() { record notify; [[ $scenario != notify_fail ]]; }
    install_quota_services() { record quota; }
    if [[ $scenario == save_fail ]]; then _write_tg_conf() { record save-failed; return 1; }; fi
    payload=$'123:fake_secret\n-100123\n4\n5\n6\n\ny'
    seed=''
    case $scenario in
        seeded) seed=123:fake_secret; payload=$'-100123\n4\n5\n6\n\ny' ;;
        minimal) payload=$'123:fake_secret\n-100123\n\n\ny' ;;
        comments) payload=$'# comment\n123:fake_secret\n\n-100123\n4\n5\n6\ny' ;;
        bracketed) payload=$'\e[200~123:fake_secret\r\n-100123\r\n4\r\n5\r\n6\e[201~\r\n\e[200~y\e[201~' ;;
        seeded_bracketed) seed=$'\e[200~123:fake_secret'; payload=$'-100123\n4\n5\n6\n\e[201~y' ;;
        q) payload=q ;;
        mid_q) payload=$'123:fake_secret\nq' ;;
        bracketed_q) payload=$'\e[200~Q\e[201~' ;;
        invalid_token) payload=$'123:fake_secret!\n-100123\n4\n5\n6\nq' ;;
        invalid_hub) payload=$'123:fake_secret\n-100oops\n4\n5\n6\nq' ;;
        invalid_topic) payload=$'123:fake_secret\n-100123\n4\n5\n6x\nq' ;;
        eof) payload='' ;;
        short_eof) payload=123:fake_secret ;;
    esac
    rc=0
    if [[ $scenario == eof ]]; then
        output=$(_tg_input_tokens test-server </dev/null 2>&1) || rc=$?
    else output=$(_tg_input_tokens test-server "$seed" <<< "$payload" 2>&1) || rc=$?; fi
    reject grep -Fq fake_secret <<< "$output"
    case $scenario in
        full|seeded|minimal|comments|bracketed|seeded_bracketed)
            assert test "$rc" = 0
            assert test "$(_tg_cfg_get "$TG_CONF" TG_BOT_TOKEN)" = 123:fake_secret
            assert _tg_config_valid
            assert grep -qx monitor "$test_dir/calls" ;;
        *) assert test "$rc" != 0 ;;
    esac
    case $scenario in
        q|mid_q|bracketed_q|invalid_*|eof|short_eof) assert test ! -s "$test_dir/calls" ;;
        save_fail) reject grep -qx monitor "$test_dir/calls"; reject grep -q '✓ 已保存' <<< "$output" ;;
        monitor_fail) assert grep -q 'SSH 监控未就绪' <<< "$output" ;;
    esac
    case $scenario in
        seeded|seeded_bracketed)
            assert grep -q '已收到 Token（隐藏）' <<< "$output"
            reject grep -q '粘贴配置，支持' <<< "$output" ;;
        invalid_token) assert grep -q '第 1 行 Token 格式不正确' <<< "$output" ;;
        invalid_hub) assert grep -q '第 2 行 Chat ID 格式不正确' <<< "$output" ;;
        invalid_topic) assert grep -q '第 3–5 行话题 ID 格式不正确' <<< "$output" ;;
    esac
)
done
for scenario in token name threads; do
(
    _write_tg_conf 123:previous -100123 Old_name 4 5 6
    before=$(sha256sum "$TG_CONF")
    printf() {
        case "$scenario:$1" in
            token:TG_BOT_TOKEN=*|name:SERVER_NAME=*|threads:TG_THREAD_SSH=*) return 1 ;;
        esac
        builtin printf "$@"
    }
    reject _write_tg_conf 123:new -100456 New_name 7 8 9
    assert test "$(sha256sum "$TG_CONF")" = "$before"
)
done
(
    _write_tg_conf 123:offline -100123 Test_server 4 5 6
    : > "$test_dir/calls"
    id() { :; }
    mkdir -p "$SSH_TG_SCRIPT"
    if output=$(_setup_ssh_tg_monitor 2>&1); then echo 'Monitor script write failure hidden'; exit 1; fi
    reject grep -q 'SSH 通知已启用' <<< "$output"
    reject grep -q 'systemctl restart' "$test_dir/calls"
    rmdir "$SSH_TG_SCRIPT"
)
(
    _tg_resolve_channel() { TG_BOT_TOKEN=123:offline; TG_CHAT_ID=-100123; TG_THREAD_ID=4; }
    send_telegram() { return 1; }
    reject _tg_notify_configured test-server
)

# Real TTY: both init's first prompt and the config reader must accept terminal paste framing.
python3 - "$repo_dir/vps-mgr.sh" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import termios
import time

code = r'''
source <(sed '/^main "\$@"$/d' "$1")
log_message() { :; }
test_scenario=${3:-}
_tg_api() { [[ $test_scenario != late_extra ]] || sleep 0.3; printf '{"ok":true,"result":{"username":"offline_bot"}}'; }
_write_tg_conf() { printf '\nPTY_SAVED\n'; }
_setup_ssh_tg_monitor() { :; }
_tg_notify_configured() { :; }
install_quota_services() { :; }
terminal_before=$(stty -g </dev/tty)
rc=0
if [[ $2 == init ]]; then
    _tg_config_valid() { return 1; }
    init_tg_test() {
        local _init_srv_name=pty-node _ok_tg=0
        # Run the real initialization input block without any host setup operations.
        eval "$(declare -f _do_full_init | sed -n '/if _tg_config_valid; then/,/Fail2Ban/ { /Fail2Ban/d; p; }')"
        rc=$((1 - _ok_tg))
    }
    init_tg_test
else
    _tg_input_tokens pty-node || rc=$?
fi
[[ $(stty -g </dev/tty) == "$terminal_before" ]] || { printf '\nPTY_TTY_BROKEN\n'; exit 1; }
printf '\nPTY_TTY_OK\n'
printf '\nPTY_DONE=%s\n' "$rc"
'''
fields = [b'1234567890:pty_fake_secret_With-Dashes_1234567890', b'-1001234567890', b'4', b'5', b'12345678']
plain = b'\n'.join(fields)
cases = [('plain', plain + b'\n\n\n', 0), ('no_final_newline', plain, 0),
         ('q', b'q\n', 1), ('Q', b'Q\n', 1), ('bracketed_q', b'\x1b[200~Q\x1b[201~\n', 1),
         ('confirm_q', plain + b'\n', 1),
         ('extra', plain + b'\n7\ny\n', 1),
         ('extra_framed', b'\x1b[200~' + plain + b'\ny\n7\x1b[201~', 1),
         ('late_extra', plain + b'\n', 1),
         ('split_plain', b'\n'.join(fields[:4]) + b'\n12', 0),
         ('split_framed', b'\x1b[200~' + b'\n'.join(fields[:4]) + b'\n12', 0),
         ('comments', b'# comment\n' + plain + b'\n# trailing comment\n', 0),
         ('minimal', b'\n'.join(fields[:2]) + b'\n\n\n', 0),
         ('manual', fields[0] + b'\n', 0), ('manual_edit', fields[0] + b'\n', 0)]
for separator in (b'\n', b'\r', b'\r\n'):
    block = separator.join(fields)
    cases += [('bracketed', b'\x1b[200~' + block + b'\x1b[201~', 0),
              ('marker_on_next_line', b'\x1b[200~' + block + separator + b'\x1b[201~\n', 0)]
for entry, name, payload, result in [(entry, *case) for entry in ('config', 'init') for case in cases]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp('bash', ['bash', '--noprofile', '--norc', '-c', code, 'pty-test', sys.argv[1], entry, name])
    output = b''
    sent_at = None
    tail_sent = False
    confirm_sent = False
    cancel_sent = False
    manual_index = 1
    last_manual = 0
    prompt = '是否现在配置'.encode() if entry == 'init' else b'>>> '
    deadline = time.monotonic() + 8
    try:
        while time.monotonic() < deadline:
            if sent_at is None and prompt in output and not termios.tcgetattr(fd)[3] & termios.ECHO:
                os.write(fd, payload)
                sent_at = time.monotonic()
                last_manual = sent_at
            if name.startswith('split_') and sent_at is not None and not tail_sent and time.monotonic() - sent_at > (0.8 if name == 'split_framed' else 0.1):
                assert b'offline_bot' not in output and b'PTY_SAVED' not in output, output
                os.write(fd, b'345678' + (b'\x1b[201~' if name == 'split_framed' else b''))
                tail_sent = True
            if name.startswith('manual') and sent_at is not None and time.monotonic() - last_manual > 0.2:
                if manual_index < 4 and f'已接收 {manual_index}/5'.encode() in output:
                    os.write(fd, fields[manual_index] + b'\n')
                    manual_index += 1
                    last_manual = time.monotonic()
                elif manual_index == 4 and '已接收 4/5'.encode() in output:
                    os.write(fd, b'129\x7f' if name == 'manual_edit' else b'12')
                    manual_index += 1
                    last_manual = time.monotonic()
                elif manual_index == 5 and time.monotonic() - last_manual > 0.8:
                    assert b'offline_bot' not in output and b'PTY_SAVED' not in output, output
                    os.write(fd, b'345678\n')
                    manual_index += 1
            if name == 'late_extra' and '正在验证 Bot...'.encode() in output and not tail_sent:
                os.write(fd, b'y\n')
                tail_sent = True
            if (name.startswith('extra') or name == 'late_extra') and output.count(b'>>> ') == 2 and not cancel_sent:
                assert b'PTY_SAVED' not in output, output
                if name != 'late_extra':
                    assert b'offline_bot' not in output, output
                os.write(fd, b'q\n')
                cancel_sent = True
            if '确认写入？'.encode() in output and not confirm_sent:
                assert b'PTY_SAVED' not in output, output
                if name != 'minimal':
                    assert b'12345678' in output, (entry, name, output)
                os.write(fd, b'Q\n' if name == 'confirm_q' else b'y\n')
                confirm_sent = True
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
        assert sent_at is not None and f'PTY_DONE={result}'.encode() in output, (entry, name, output)
        assert b'PTY_TTY_OK' in output, (entry, name, output)
        assert b'pty_fake_secret' not in output, output
        prompts = 2 if name.startswith('extra') or name == 'late_extra' else 0 if entry == 'init' and name in ('q', 'Q', 'bracketed_q') else 1
        assert output.count(b'>>> ') == prompts, (entry, name, output)
        assert '格式不正确'.encode() not in output, (entry, name, output)
        assert (b'PTY_SAVED' in output) == (result == 0), output
        if result == 0 and name != 'minimal':
            assert '已接收 5/5 项'.encode() in output, (entry, name, output)
        if name.startswith('extra'):
            assert '配置超过 5 项或含多余输入'.encode() in output, output
            assert '已接收 6/5'.encode() not in output, output
        if name == 'late_extra':
            assert '验证期间收到多余输入'.encode() in output, output
    finally:
        ended, _ = os.waitpid(pid, os.WNOHANG)
        if ended == 0:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)
print('PASS: real TTY auto-submit, progress, extra-input guard, split paste, manual input and terminal restore')

for interrupt in (b'\x03', b'\x04'):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp('bash', ['bash', '--noprofile', '--norc', '-c', code, 'pty-test', sys.argv[1], 'config'])
    output = b''
    interrupted = False
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            if b'>>> ' in output and not interrupted and not termios.tcgetattr(fd)[3] & termios.ECHO:
                os.write(fd, interrupt)
                interrupted = True
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    output += os.read(fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
        assert interrupted and b'PTY_SAVED' not in output, output
        flags = termios.tcgetattr(fd)[3]
        assert flags & termios.ECHO and flags & termios.ICANON, output
        assert b'\x1b[?2004l' in output, output
    finally:
        ended, _ = os.waitpid(pid, os.WNOHANG)
        if ended == 0:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)
print('PASS: Ctrl-C / EOF restore terminal echo and canonical input')
PY

# 3: failed enforcement restores intent; manual actions and timers propagate failure.
(
    _fw_element() { return 1; }
    printf '24080|2026-10|10|20|30|40|0|-\n' > "$QUOTA_DATA"
    before=$(sha256sum "$QUOTA_DATA")
    reject quota_pause_port 24080 manual
    assert test "$(sha256sum "$QUOTA_DATA")" = "$before"
    printf '24080|2026-10|10|20|30|40|1|manual\n' > "$QUOTA_DATA"
    before=$(sha256sum "$QUOTA_DATA")
    reject quota_resume_port 24080
    assert test "$(sha256sum "$QUOTA_DATA")" = "$before"
    _quota_pick_port() { port=24080; }
    for operation in quota_manual_pause quota_manual_resume; do
        if output=$("$operation" 2>&1); then echo 'Failed quota operation reported success'; exit 1; fi
        reject grep -Eq '已手动暂停|已恢复' <<< "$output"
    done
    _fw_element() { :; }
    quota_resume_port 24080
    assert grep -q '|0|-$' "$QUOTA_DATA"
    quota_pause_port 24080 manual
    assert grep -q '|1|manual$' "$QUOTA_DATA"
    _quota_write_data() { return 1; }
    _fw_element() { echo 'FAIL: firewall changed after state write failure' >&2; exit 99; }
    reject quota_resume_port 24080
)
(
    before=$(sha256sum "$QUOTA_DATA")
    printf() { [[ $1 != '%s\n' ]] || return 1; builtin printf "$@"; }
    _fw_element() { echo 'FAIL: firewall changed after record append failure' >&2; exit 99; }
    if quota_resume_port 24080; then echo 'Quota append failure hidden'; exit 1; fi
    assert test "$(sha256sum "$QUOTA_DATA")" = "$before"
)
for scenario in reload enable_check enable_daily active enabled write success; do
(
    touch "$QUOTA_DIR/.timer_disabled"
    systemctl() {
        case "$scenario:$1:${3:-}" in
            reload:daemon-reload:*|enable_check:enable:quota-check.timer|enable_daily:enable:quota-daily.timer|active:is-active:*|enabled:is-enabled:*) return 1 ;;
        esac
    }
    if [[ $scenario == write ]]; then mv() { return 1; }; fi
    rc=0; output=$(install_quota_services 2>&1) || rc=$?
    if [[ $scenario == success ]]; then
        assert test "$rc" = 0
        assert test ! -e "$QUOTA_DIR/.timer_disabled"
        assert grep -q '安装完成' <<< "$output"
    else
        assert test "$rc" != 0
        assert test -e "$QUOTA_DIR/.timer_disabled"
        reject grep -q '安装完成\|定时器已启动' <<< "$output"
    fi
)
done

# 4: valid IP stays usable without GeoIP; malformed/expired cache is refreshed.
(
    get_public_ip() { echo 'FAIL: fresh valid IP should not need network' >&2; return 99; }
    for cc in UN '' US broken; do
        printf 'SERVER_IP=203.0.113.42\nSERVER_COUNTRY_CODE=%s\n' "$cc" > "$CACHE_FILE"
        SERVER_IP=127.0.0.1
        get_server_info
        assert test "$SERVER_IP" = 203.0.113.42
    done
    get_public_ip() { printf 198.51.100.25; }
    get_geo_info() { return 1; }
    printf 'SERVER_IP=999.1.1.1\nSERVER_COUNTRY_CODE=US\n' > "$CACHE_FILE"
    get_server_info
    assert test "$SERVER_IP" = 198.51.100.25
    assert test "$SERVER_COUNTRY_CODE" = UN
    SERVER_IP=127.0.0.1
    get_server_info
    assert test "$SERVER_IP" = 198.51.100.25
    touch -d '2 days ago' "$CACHE_FILE"
    get_public_ip() { printf 198.51.100.26; }
    get_server_info
    assert test "$SERVER_IP" = 198.51.100.26
)

# 5: every quota rule is enforced before any slow external notification, with flock free.
for scenario in normal enforcement_failure; do
(
    : > "$test_dir/notices"
    printf '24080|first|100|-|0\n24081|second|100|-|0\n' > "$QUOTA_CONFIG"
    : > "$QUOTA_DATA"
    quota_init() { :; }
    quota_get_port_bytes() { printf '200 0\n'; }
    get_node_id() { printf test-server; }
    _fw_element() { [[ $scenario != enforcement_failure || $3 != 24080 ]]; }
    _tg_resolve_channel() { TG_BOT_TOKEN=123:offline; TG_CHAT_ID=-100123; }
    send_telegram() {
        assert test "${_STATE_LOCKED:-0}" = 0
        assert flock -n "$FW_LOCK" true
        assert grep -q '^24081|.*|1|quota$' "$QUOTA_DATA"
        printf '%s\n' "$1" >> "$test_dir/notices"
        return 1 # TG outage must not undo enforcement or turn it into a lock timeout.
    }
    rc=0; quota_check_all || rc=$?
    if [[ $scenario == normal ]]; then
        assert test "$rc" = 0
        assert test "$(grep -c '流量超限' "$test_dir/notices")" = 2
    else
        assert test "$rc" != 0
        reject grep -q 'first' "$test_dir/notices"
        assert grep -q '^24080|.*|0|-$' "$QUOTA_DATA"
    fi
)
done

# 6: jq gets credentials through private descriptors, including quotes/backslashes.
(
    secret='audit_SECRET_"quote\$(not_a_command)'
    jq() {
        [[ $* != *audit_SECRET* ]] || { echo 'FAIL: credential in jq argv' >&2; exit 99; }
        command jq "$@"
    }
    fake_sbx() { :; }
    sleep() { :; }
    chown() { :; }
    printf 'S_PORT=24080\nS_METHOD=aes-128-gcm\nS_PW=%s\n' "$secret" > "$SBX_ST/ss-24080.env"
    printf 'SK_PORT=24081\nSK_USER=test\nSK_PW=%s\n' "$secret" > "$SBX_ST/socks-24081.env"
    printf 'H_PORT=24082\nH_PW=%s\nH_OBFS=%s\nH_UP=50\nH_DOWN=100\nH_CRT=test.crt\nH_KEY=test.key\n' \
        "$secret" "$secret" > "$SBX_ST/hy2-24082.env"
    sbx_render
    assert test "$(jq -r '.inbounds[0].password' "$SBX_CONF")" = "$secret"
    assert test "$(jq -r '.inbounds[1].users[0].password' "$SBX_CONF")" = "$secret"
    assert test "$(jq -r '.inbounds[2].obfs.password' "$SBX_CONF")" = "$secret"
    assert test "$(stat -c %a "$SBX_CONF")" = 600
    printf '{"endpoints":[]}' > "$REALM_CONFIG_FILE"
    printf '{}' > "$REALM_META_FILE"
    _check_port_available() { :; }
    validate_realm_config() { :; }
    _fw_has_element() { return 1; }
    open_firewall_port() { :; }
    _realm_add_endpoint 24083 192.0.2.1:443 "$secret" test UN
    assert test "$(jq -r '.["24083"].psk' "$REALM_META_FILE")" = "$secret"
)

# 8: package stdout stays quiet on success; errors, original status and private log survive.
(
    apt-get() { printf 'package-install-details\n'; }
    output=$(_apt_quiet 'test install' install -y -qq fake-package)
    assert test -z "$output"
    assert grep -q package-install-details "$WORK_DIR/apt-install.log"
    assert test "$(stat -c %a "$WORK_DIR/apt-install.log")" = 600
    apt-get() { printf 'simulated-dpkg-failure\n' >&2; return 42; }
    rc=0; output=$(_apt_quiet 'test failure' install -y fake-package 2>&1) || rc=$?
    assert test "$rc" = 42
    assert grep -q simulated-dpkg-failure <<< "$output"
    assert grep -Fq "$WORK_DIR/apt-install.log" <<< "$output"
    assert grep -q package-install-details "$WORK_DIR/apt-install.log"
)

# 9: names work without TG, preserve credentials on rename, and don't lie on failure.
(
    rm -f "$TG_CONF"
    systemctl() { [[ $1 != is-active ]]; }
    _save_server_name Name_without_TG
    assert test "$(_tg_cfg_get "$TG_CONF" SERVER_NAME)" = Name_without_TG
    reject _tg_config_valid
    _write_tg_conf 123:offline -100123 Old_name 4 5 6
    _set_server_name <<< New_name
    assert test "$(_tg_cfg_get "$TG_CONF" SERVER_NAME)" = New_name
    assert test "$(_tg_cfg_get "$TG_CONF" TG_BOT_TOKEN)" = 123:offline
    assert test "$(_tg_cfg_get "$TG_CONF" TG_THREAD_DDNS)" = 6
    before=$(sha256sum "$TG_CONF")
    mv() { return 1; }
    reject _save_server_name Failed_name
    assert test "$(sha256sum "$TG_CONF")" = "$before"
    unset -f mv
    systemctl() { [[ $1 != restart ]]; }
    reject _save_server_name Saved_but_monitor_failed
    assert test "$(_tg_cfg_get "$TG_CONF" SERVER_NAME)" = Saved_but_monitor_failed
)

# 10: read-only health distinguishes enabled, running, never executed, and failed jobs.
for scenario in fresh completed running job_failed tg_down f2b_down tcping_closed timer_disabled policy_bad; do
(
    : > "$test_dir/calls"
    _ck_pass() { printf 'PASS %s\n' "$1"; }
    _ck_warn() { printf 'WARN %s\n' "$1"; }
    _ck_fail() { printf 'FAIL %s\n' "$1"; }
    _is_container() { return 1; }
    _tg_config_valid() { return 0; }
    _security_updates_policy_ok() { [[ $scenario != policy_bad ]]; }
    unattended-upgrade() { echo 'FAIL: attempted upgrade during health check' >&2; exit 99; }
    fail2ban-client() { [[ $scenario != f2b_down ]]; }
    timedatectl() { echo yes; }
    ss() { printf 'LISTEN 0 128 0.0.0.0:9999 0.0.0.0:*\n'; }
    _fw_has_element() { [[ $scenario != tcping_closed ]]; }
    touch "$test_dir/etc/fail2ban/jail.d/sshd.conf" "$test_dir/etc/apt/apt.conf.d/99vps-mgr-security-updates" \
        "$test_dir/etc/systemd/system/vps-mgr-fq.service"
    printf 'PORT=9999\n' > "$TCPING_CONFIG_FILE"
    systemctl() {
        record "systemctl $*"
        case $1 in
            is-active) [[ $scenario != tg_down || $3 != "$SSH_TG_SERVICE" ]] ;;
            is-enabled) [[ $scenario != timer_disabled || $3 != apt-daily-upgrade.timer ]] ;;
            show)
                case $4 in
                    ActiveState) if [[ $scenario == running ]]; then echo activating; else echo inactive; fi ;;
                    Result) if [[ $scenario == job_failed && $2 == apt-daily-upgrade.service ]]; then echo exit-code; else echo success; fi ;;
                    ExecMainStartTimestamp) if [[ $2 == vps-mgr-fq.service || $scenario != fresh ]]; then echo '2026-10-18 00:00:00 UTC'; fi ;;
                    *) echo 'FAIL: unexpected property' >&2; exit 99 ;;
                esac ;;
            *) echo 'FAIL: mutating systemctl in health check' >&2; exit 99 ;;
        esac
    }
    output=$(_check_runtime_services)
    assert grep -q 'PASS fq 开机恢复已成功执行' <<< "$output"
    case $scenario in
        fresh) assert grep -q '尚未执行' <<< "$output"; reject grep -q '最近任务退出成功' <<< "$output" ;;
        completed) assert grep -q '最近任务退出成功' <<< "$output" ;;
        running) assert grep -q '正在执行' <<< "$output"; reject grep -q '最近任务退出成功' <<< "$output" ;;
        job_failed) assert grep -q 'FAIL apt-daily-upgrade.service 最近任务失败' <<< "$output" ;;
        tg_down) assert grep -q 'FAIL TG 已配置' <<< "$output" ;;
        f2b_down) assert grep -q 'FAIL Fail2Ban' <<< "$output" ;;
        tcping_closed) assert grep -q 'FAIL TCPing' <<< "$output" ;;
        timer_disabled) assert grep -q 'FAIL apt-daily-upgrade.timer' <<< "$output" ;;
        policy_bad) assert grep -q 'FAIL 安全补丁组件' <<< "$output" ;;
    esac
)
done
printf 'PASS: 10 runtime fixes (confirmation, TG, quota, cache, locking, credentials, input, logs, names, health)\n'
