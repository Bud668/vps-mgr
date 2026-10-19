#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-self-update.XXXXXXXX)
trap '[[ $test_dir == /tmp/vps-mgr-self-update.* ]] && rm -rf "$test_dir"' EXIT

while IFS='|' read -r current release auto_expected manual_expected candidate answer_input; do
    for mode in auto manual; do
        (
            if [[ $mode == auto ]]; then expected=$auto_expected; else expected=$manual_expected; fi
            [[ $expected != skip ]] || exit 0
            # Load real updater logic with a fixture version; never source the downloaded candidate.
            # shellcheck source=/dev/null
            source <(sed -e '/^main "\$@"$/d' \
                -e "s|^readonly WORK_DIR=.*|readonly WORK_DIR=\"$test_dir/state\"|" \
                -e "s|^readonly SCRIPT_VERSION=.*|readonly SCRIPT_VERSION=\"$current\"|" "$repo_dir/vps-mgr.sh")
            log_message() { :; }
            sleep() { :; }
            realpath() { printf '%s\n' "$test_dir/current"; }
            exec() { [[ $1 == "$test_dir/current" ]]; }
            get_latest_github_release() { printf 'lookup\n' >> "$test_dir/queries"; printf '%s\n' "$release"; }
            assert() { "$@" || { printf 'FAIL: %s → %s (%s): %s\n' "$current" "$release" "$mode" "$*" >&2; exit 1; }; }
            curl() {
                printf 'download\n' >> "$test_dir/calls"
                while (( $# )); do
                    if [[ $1 == -o ]]; then
                        cp "$test_dir/candidate" "$2"
                        return
                    fi
                    shift
                done
                return 1
            }
            printf '#!/bin/bash\nreadonly SCRIPT_VERSION="%s"\n' "$current" > "$test_dir/current"
            cp "$test_dir/current" "$test_dir/original"
            printf '#!/bin/bash\nreadonly SCRIPT_VERSION="%s"\n' "${candidate:-${release#v}}" > "$test_dir/candidate"
            [[ $expected != invalid ]] || printf 'if\n' >> "$test_dir/candidate"
            rm -f "$test_dir/current.bak" "$test_dir/calls" "$test_dir/queries"
            mkdir -p "$WORK_DIR"
            if [[ $expected == optout ]]; then
                rm -f "$SELF_AUTOUPDATE_FLAG"
                if [[ $mode == auto ]]; then expected=off; else expected=update; fi
            else
                : > "$SELF_AUTOUPDATE_FLAG"
            fi
            printf -v answer '%b' "${answer_input:-y}"
            if [[ $expected == backup_fail ]]; then
                cp() {
                    [[ ${*: -1} != "$test_dir/current.bak" ]] || return 1
                    command cp "$@"
                }
            fi
            result=0
            if [[ $mode == auto ]]; then
                output=$(self_update auto </dev/null 2>&1) || result=$?
            elif [[ $expected == eof ]]; then
                output=$(self_update </dev/null 2>&1) || result=$?
            else
                output=$(self_update <<< "$answer" 2>&1) || result=$?
            fi
            if [[ $mode == manual && $auto_expected == blocked ]]; then
                assert grep -q '不负责迁移配置' <<< "$output"
                assert grep -Fq "https://github.com/Bud668/vps-mgr/releases/tag/$release" <<< "$output"
            fi
            case $expected in
                off)
                    [[ $output == *脚本自动更新已关闭* ]] || exit 1
                    assert test ! -e "$test_dir/queries" ;;
                blocked) [[ $output == *已阻止跨大版本升级* ]] || exit 1 ;;
                downgrade) [[ $output == *跳过降级* ]] || exit 1 ;;
                current) [[ $output == *已是最新* ]] || exit 1 ;;
                declined|eof) [[ $output == *发现新版本* ]] || exit 1 ;;
                update)
                    assert grep -q '已更新到' <<< "$output"
                    assert cmp -s "$test_dir/current" "$test_dir/candidate"
                    assert cmp -s "$test_dir/current.bak" "$test_dir/original"
                    assert test -x "$test_dir/current"
                    assert test "$(cat "$test_dir/calls")" = download ;;
                mismatch|invalid)
                    assert test "$result" -ne 0
                    [[ $output == *已放弃更新* || $output == *语法校验失败* ]] || exit 1
                    assert test "$(cat "$test_dir/calls")" = download ;;
                backup_fail)
                    assert test "$result" -ne 0
                    assert grep -q '备份失败' <<< "$output"
                    assert test "$(cat "$test_dir/calls")" = download ;;
                *) exit 1 ;;
            esac
            if [[ $expected != mismatch && $expected != invalid && $expected != backup_fail ]]; then assert test "$result" -eq 0; fi
            if [[ $expected != update ]]; then
                assert cmp -s "$test_dir/current" "$test_dir/original"
                assert test ! -e "$test_dir/current.bak"
                if [[ $expected != mismatch && $expected != invalid && $expected != backup_fail ]]; then assert test ! -e "$test_dir/calls"; fi
            fi
            # Failed and refused updates leave no temporary replacement behind.
            leftovers=$(find "$test_dir" -maxdepth 1 -name 'current.*' ! -name current.bak -print)
            assert test -z "$leftovers"
        )
    done
done <<'CASES'
1.4.1|v2.0.0|blocked|declined||n
2.0.0|v3.0.0|blocked|update||y\nv3.0.0
2.0.0|v20.0.0|blocked|update||Y\nv20.0.0
2.0.0-beta.14|v3.0.0|blocked|update||y\nv3.0.0
2.0.0|v3.0.0|optout|optout||y\nv3.0.0
2.0.0|v3.0.0|blocked|declined||n\nv3.0.0
2.0.0|v3.0.0|blocked|declined||\nv3.0.0
2.0.0|v3.0.0|blocked|declined||invalid\nv3.0.0
2.0.0|v3.0.0|blocked|declined||y
2.0.0|v3.0.0|blocked|declined||y\n
2.0.0|v3.0.0|blocked|declined||y\nq
2.0.0|v3.0.0|blocked|declined||y\ny
2.0.0|v3.0.0|blocked|declined||y\nv3.0.1
2.0.0|v3.0.0|blocked|declined||y\n3.0.0
2.0.0|v3.0.0|blocked|eof||
2.0.0|v3.0.0|blocked|mismatch|3.0.1|y\nv3.0.0
2.0.0|v3.0.0|blocked|invalid||y\nv3.0.0
2.0.0|v3.0.0|blocked|backup_fail||y\nv3.0.0
2.0.0|v1.4.1|downgrade|downgrade||y\nv1.4.1
2.3.0|v2.2.9|downgrade|downgrade||
2.0.0|v2.0.0|current|current||
2.0.0|v2.0.1|update|update||
2.0.0|v2.0.1|update|update||\n
2.0.0|v2.0.1|optout|optout||
2.0.1|v2.0.2|update|update||
2.9.0|v2.10.0|update|update||
2.0.0-beta.14|v2.0.0|update|update||
2.0.0|v2.1.0|skip|declined||n
2.0.0|v2.1.0|skip|eof||
2.0.0|v2.1.0|mismatch|mismatch|3.0.0|
2.0.0|v2.1.0|mismatch|mismatch|2.1.1|
2.0.0|v2.1.0|invalid|invalid||
2.0.0|v2.1.0|backup_fail|backup_fail||
CASES

# The real menu switch is explicit and persistent, independent of daily reminders.
(
    # shellcheck source=/dev/null
    source <(sed -e '/^main "\$@"$/d' \
        -e "s|^readonly WORK_DIR=.*|readonly WORK_DIR=\"$test_dir/state\"|" "$repo_dir/vps-mgr.sh")
    log_message() { :; }
    clear() { :; }
    get_installed_version() { :; }
    get_cached_latest_version() { :; }
    systemctl() { return 0; }
    install_autoupdate() { printf 'daily\n' >> "$test_dir/daily"; }
    uninstall_autoupdate() { echo 'FAIL: opt-out stopped daily reminders' >&2; return 1; }
    rm -f "$SELF_AUTOUPDATE_FLAG"
    output=$(_do_update_menu <<< 0)
    [[ $output == *'手动更新；跨大版本需二次确认'* && $output == *'默认关闭；仅同大版本正式版'* ]] || exit 1
    _do_update_menu <<< 7 >/dev/null
    [[ -f $SELF_AUTOUPDATE_FLAG && $(stat -c %a "$SELF_AUTOUPDATE_FLAG") == 600 ]] || exit 1
    [[ $(cat "$test_dir/daily") == daily ]] || exit 1
    _do_update_menu <<< 7 >/dev/null
    [[ ! -e $SELF_AUTOUPDATE_FLAG ]] || exit 1
)
printf 'PASS: default-off updates, strict automatic major guard, manual double confirmation, cancellation, backups and download validation\n'
