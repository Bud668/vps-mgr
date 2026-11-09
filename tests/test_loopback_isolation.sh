#!/usr/bin/env bash
set -euo pipefail
# Entire script must run under unshare --net. No host services or files changed.
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || exit 2
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$repo_dir/vps-mgr.sh")
peer_pid= listener_pid=
trap 'kill ${peer_pid:-} ${listener_pid:-} 2>/dev/null || true; wait 2>/dev/null || true' EXIT
unshare --net sleep 90 & peer_pid=$!
sleep 0.1
ip link set lo up
ip link add review0 type veth peer name review1
ip link set review1 netns "$peer_pid"
ip addr add 192.0.2.1/24 dev review0
ip link set review0 up
nsenter -t "$peer_pid" -n ip link set lo up
nsenter -t "$peer_pid" -n ip addr add 192.0.2.2/24 dev review1
nsenter -t "$peer_pid" -n ip link set review1 up
server_mac=$(ip -j link show review0 | jq -r '.[0].address')
peer_mac=$(nsenter -t "$peer_pid" -n ip -j link show review1 | jq -r '.[0].address')
ip neigh replace 192.0.2.2 lladdr "$peer_mac" dev review0 nud permanent
_fw_base_rules 22 | nft -f -
nft add element inet "$FW_TABLE" tcp_ports '{ 24099 }'
# Publicly allowed TCP port with a process intentionally bound only to loopback.
python3 -u - <<'PY' &
import socket, time
s=socket.socket(); s.bind(('127.0.0.1',24099)); s.listen(); time.sleep(90)
PY
listener_pid=$!
sleep 0.1
configured=$(declare -f _write_sysctl_conf | awk '/^net.ipv4.conf.all.route_localnet = / {print $3}')
[[ $configured == 0 ]] || { echo 'Loopback routing still globally enabled' >&2; exit 1; }
# Positive control proves packets really reach the server; then verify new default.
for enabled in 1 "$configured"; do
    sysctl -q -w net.ipv4.conf.all.route_localnet="$enabled"
    nsenter -t "$peer_pid" -n python3 - "$server_mac" "$peer_mac" "$enabled" <<'PY'
import socket,struct,sys,time

def checksum(data):
    if len(data)%2:data+=b'\0'
    value=sum(struct.unpack('!%dH'%(len(data)//2),data))
    value=(value>>16)+(value&65535);value+=(value>>16)
    return (~value)&65535

dstmac,srcmac=[bytes.fromhex(x.replace(':','')) for x in sys.argv[1:3]]
src=socket.inet_aton('192.0.2.2'); dst=socket.inet_aton('127.0.0.1')
sport=55020+int(sys.argv[3])
tcp=struct.pack('!HHLLBBHHH',sport,24099,1000,0,80,2,65535,0,0)
tcp=tcp[:16]+struct.pack('!H',checksum(src+dst+struct.pack('!BBH',0,6,20)+tcp))+tcp[18:]
ip=struct.pack('!BBHHHBBH4s4s',69,0,40,100,0,64,6,0,src,dst)
ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3));s.bind(('review1',0));s.settimeout(.5)
s.send(dstmac+srcmac+b'\x08\x00'+ip+tcp)
reached=False; deadline=time.monotonic()+1
while time.monotonic()<deadline:
    try:p=s.recv(65535)
    except socket.timeout:continue
    if len(p)<54 or p[12:14]!=b'\x08\x00' or p[23]!=6:continue
    i=14+(p[14]&15)*4
    if len(p)<i+20:continue
    sp,dp=struct.unpack('!HH',p[i:i+4])
    if sp==24099 and dp==sport and p[i+13]&18==18:reached=True;break
print('route_localnet='+sys.argv[3]+': external interface received SYN-ACK from loopback-only listener='+str(reached))
assert reached == (sys.argv[3]=='1')
PY
done
