#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "${VPS_MGR_TEST_SCRIPT:-$repo_dir/vps-mgr.sh}")
assert_eq() {
    [[ "$1" == "$2" ]] || { printf 'FAIL: %s (expected %s, got %s)\n' "$3" "$1" "$2" >&2; exit 1; }
}
assert_state() {
    local status=0
    _firewall_init_state || status=$?
    assert_eq "$1" "$status" "$2"
}
for pair in 1:1 10:10 80:80 080:80 100:100 1000:1000 1200:1200 1201:1176 6000:5880; do
    assert_eq "${pair#*:}" "$(_fq_maxrate_mbps "${pair%:*}")" "fq rate $pair"
done
for invalid in '' 0 -1 80mbit 1.5; do
    if _fq_maxrate_mbps "$invalid" >/dev/null; then echo "FAIL invalid bandwidth $invalid"; exit 1; fi
done
for setting in tcp_syn_retries:3:le tcp_retries2:8:ge tcp_orphan_retries:1:eq; do
    IFS=: read -r key value comparison <<< "$setting"
    declare -f _write_sysctl_conf | grep -Fq "net.ipv4.$key = $value"
    declare -f do_check_all | grep -Eq "_ck_pass_file net.ipv4.$key +$value +$comparison( |$)"
done
for caller in do_retune_bandwidth _do_full_init; do
    declare -f "$caller" | grep -Fq '_fq_maxrate_mbps "$bw_mbps"'
    declare -f "$caller" | grep -Fq '_apply_fq "$_def_if" "$_fq_maxrate"'
done
declare -f do_retune_bandwidth | grep -Fq '/etc/sysctl.d/99-custom-tuning.conf'
# A fresh image can open the dashboard before menu 1 installs jq/nftables.
for missing_dependency in jq nft; do
(
    command() {
        [[ $1 != -v || ${2:-} != "$missing_dependency" ]] || return 1
        builtin command "$@"
    }
    nft() { echo 'FAIL: unexpected nft call before dependency check' >&2; return 99; }
    jq() { echo 'FAIL: unexpected jq call before dependency check' >&2; return 99; }
    status=0
    output=$(_fw_test_deadline 2>&1) || status=$?
    assert_eq 1 "$status" "test deadline unavailable without $missing_dependency"
    assert_eq '' "$output" "no startup error without $missing_dependency"
    output=$(_fw_show_status 2>&1)
    if [[ $missing_dependency == jq ]]; then
        assert_eq '   防火墙状态缺少 jq（菜单 1 安装依赖）' "$output" 'missing jq hint'
    else
        assert_eq '   nftables 未安装（菜单 1 初始化）' "$output" 'missing nft hint'
    fi
)
done
# Kernel-created fq queues have handle 0:; change cannot configure these.
(
    _is_container() { return 1; }
    tc() {
        if [[ $* == '-j qdisc show dev boot-test' ]]; then printf '%s\n' "$qdiscs"
        else printf '%s\n' "$*"; fi
    }
    qdiscs='[{"kind":"fq","handle":"0:","root":true}]'
    assert_eq 'qdisc replace dev boot-test root fq maxrate 80mbit flow_limit 250' \
        "$(_apply_fq boot-test 80)" 'implicit root fq needs create-or-change'
    qdiscs='[{"kind":"mq","handle":"10:","root":true},{"kind":"fq","handle":"0:","parent":"10:1"},{"kind":"fq","handle":"0:","parent":"10:2"}]'
    assert_eq $'qdisc replace dev boot-test parent 10:1 fq maxrate 80mbit flow_limit 250\nqdisc replace dev boot-test parent 10:2 fq maxrate 80mbit flow_limit 250' \
        "$(_apply_fq boot-test 80)" 'implicit mq leaves need create-or-change'
)
# One entry, no mode question: containers also reach the shared full workflow.
(
    _do_full_init() { echo full; }
    _is_container() { return 1; }
    assert_eq full "$(do_quick_init </dev/null)" 'normal VPS uses full initialization'
    _is_container() { return 0; }
    log_message() { :; }
    output=$(do_quick_init </dev/null)
    assert_eq full "${output##*$'\n'}" 'container uses the same user-space initialization'
)
[[ $(declare -f _do_full_init | grep -c 'do_init_firewall') == 1 ]] || {
    echo 'FAIL: full initialization repeats firewall setup'; exit 1;
}
service_writes=0
systemctl() {
    if [[ $1 == is-active ]]; then [[ ${3:-} == "${managed_firewall:-none}" ]]
    else service_writes=$((service_writes + 1)); return 99; fi
}
log_message() { :; }
_state_locked() { "$@"; }
mktemp() { echo 'FAIL: unexpected file write' >&2; return 99; }
systemd-run() { echo 'FAIL: unexpected scheduler write' >&2; return 99; }
if [[ ${1:-} == --netns ]]; then
    [[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
        echo 'Run: unshare --net bash tests/test_network_init.sh --netns' >&2; exit 1;
    }
    assert_state 0 'empty namespace'
    nft add table inet business
    nft add chain inet business input '{ type filter hook input priority 0; policy drop; }'
    nft add rule inet business input tcp dport 443 accept
    before=$(nft list ruleset)
    if do_init_firewall --auto; then echo 'FAIL: unmanaged table accepted' >&2; exit 1; fi
    assert_eq "$before" "$(nft list ruleset)" 'existing business rules preserved'
    assert_eq 0 "$service_writes" 'no unrelated service writes'
    _is_container() { return 1; } # These dummy interfaces are in a disposable namespace.
    ip link add vps-test type dummy
    ip link set vps-test up
    tc qdisc add dev vps-test root handle 1: fq limit 1234 maxrate 100mbit flow_limit 250
    _apply_fq vps-test "$(_fq_maxrate_mbps 80)"
    tc qdisc show dev vps-test | grep -Eq 'fq 1:.*flow_limit 250p.*maxrate 80Mbit'
    assert_eq 1234 "$(tc -j qdisc show dev vps-test | jq '.[0].options.limit')" 'existing fq options preserved'
    _apply_fq vps-test 120
    tc qdisc show dev vps-test | grep -Eq 'fq 1:.*limit 1234p.*flow_limit 250p.*maxrate 120Mbit'
    tc qdisc replace dev vps-test root fq_codel
    _apply_fq vps-test 80
    tc qdisc show dev vps-test | grep -Eq 'qdisc fq .*flow_limit 250p.*maxrate 80Mbit'
    ip link add vps-mq numtxqueues 4 numrxqueues 4 type dummy
    ip link set vps-mq up
    tc qdisc replace dev vps-mq root handle 10: mq
    _apply_fq vps-mq 80
    assert_eq 4 "$(tc -j qdisc show dev vps-mq | jq '[.[] | select(.kind=="fq")]|length')" 'all mq leaves use fq'
    assert_eq 4 "$(tc qdisc show dev vps-mq | grep -c 'flow_limit 250p.*maxrate 80Mbit')" 'all mq leaves tuned'
    handles=$(tc -j qdisc show dev vps-mq | jq -c '[.[] | {kind,handle,parent}]')
    _apply_fq vps-mq 120
    assert_eq 4 "$(tc qdisc show dev vps-mq | grep -c 'maxrate 120Mbit')" 'mq retune changes every leaf'
    assert_eq "$handles" "$(tc -j qdisc show dev vps-mq | jq -c '[.[] | {kind,handle,parent}]')" 'mq root and leaf handles preserved'
    (
        ip() { echo 'default via 192.0.2.1 dev vps-mq'; }
        clear() { :; }
        output=$(do_check_all || true)
        [[ $output == *'qdisc fq 已生效（含多队列叶子）'* ]] || { echo 'FAIL: mq fq health check'; exit 1; }
    )
    tc qdisc replace dev vps-mq parent 10:1 pfifo limit 1000
    before=$(tc qdisc show dev vps-mq)
    if _apply_fq vps-mq 80; then echo 'FAIL: custom mq leaf overwritten'; exit 1; fi
    assert_eq "$before" "$(tc qdisc show dev vps-mq)" 'mixed mq tree unchanged'
    (
        ip() { echo 'default via 192.0.2.1 dev vps-mq'; }
        clear() { :; }
        output=$(do_check_all || true)
        [[ $output == *'部分队列或 maxrate/flow_limit 未完整配置'* ]] || { echo 'FAIL: mixed mq falsely reported healthy'; exit 1; }
    )
    tc qdisc replace dev vps-test root handle 2: pfifo limit 1000
    before=$(tc qdisc show dev vps-test)
    if _apply_fq vps-test 80; then echo 'FAIL: unrelated qdisc accepted'; exit 1; fi
    assert_eq "$before" "$(tc qdisc show dev vps-test)" 'unrelated qdisc preserved'
    printf 'PASS: real native firewall preservation and actual production fq helper\n'
    exit 0
fi
mock_tables=""
nft_failure=0
nft() {
    (( nft_failure == 0 )) || return 1
    [[ $* == 'list tables' ]] || return 1
    printf '%s\n' "$mock_tables"
}
assert_state 0 'empty firewall'
mock_tables='table inet business'
assert_state 1 'other nft table'
if do_init_firewall --auto >/dev/null; then echo 'FAIL: unrelated firewall accepted'; exit 1; fi
mock_tables=''
for managed_firewall in ufw firewalld netfilter-persistent nftables; do
    assert_state 1 "$managed_firewall active"
done
managed_firewall=none
nft_failure=1
assert_state 2 'read failure'
if do_init_firewall --auto >/dev/null 2>&1; then echo 'FAIL: read failure accepted'; exit 1; fi
assert_eq 0 "$service_writes" 'no service mutations'
printf 'PASS: network initialization safety regressions\n'
