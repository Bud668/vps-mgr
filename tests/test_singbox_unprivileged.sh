#!/usr/bin/env bash
set -euo pipefail
# Run with: VPS_MGR_REAL_SBX=/path/to/verified/sing-box unshare --net bash tests/test_singbox_unprivileged.sh
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || { echo 'Disposable network namespace required' >&2; exit 2; }
[[ -x ${VPS_MGR_REAL_SBX:-} ]] || { echo 'Verified sing-box binary required' >&2; exit 2; }
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/vps-mgr-sbx-native.XXXXXXXX)
trap 'rm -rf "$test_dir"' EXIT
install -m755 "$VPS_MGR_REAL_SBX" "$test_dir/sing-box"
# shellcheck source=/dev/null
source <(sed -e '/^main "\$@"$/d' -e "s|/etc/|$test_dir/etc/|g" \
    -e "s|^readonly SBX_BIN=.*|readonly SBX_BIN=\"$test_dir/sing-box\"|" "$repo_dir/vps-mgr.sh")
log_message() { :; }
sleep() { :; }
systemctl() { :; }
_sbx_ensure_user() { :; }
_check_port_available() { :; }
open_firewall_port() { :; }
_firewall_open_port() { :; }
_sbx_socks_fw_apply() { :; }
test_uid=$(id -u nobody); test_gid=$(id -g nobody)
chown() {
    if [[ $1 == root:singboxproxy ]]; then shift; command chown "root:$test_gid" "$@"
    else command chown "$@"; fi
}
mkdir "$test_dir/etc"
chmod 711 "$test_dir" "$test_dir/etc"
_sbx_permissions
ss_password=$(openssl rand -base64 32)
_sbx_add_node ss 1443 2022-blake3-aes-256-gcm "$ss_password"
_sbx_add_node socks 108 test-user test-password ''
_sbx_add_node hy2 443 test-password test-obfs 50 100
ip link set lo up
# Make low-port binding genuinely require the capability inside this namespace.
sysctl -qw net.ipv4.ip_unprivileged_port_start=1024
python3 - "$SBX_BIN" "$SBX_CONF" "$test_dir" "$test_uid" "$test_gid" "$ss_password" <<'PY'
import http.server, json, os, pathlib, socket, struct, subprocess, sys, threading, time
binary, config, folder, uid, gid, ss_password = sys.argv[1:]
root = pathlib.Path(folder)
prefix = ['setpriv', '--reuid', uid, '--regid', gid, '--clear-groups', '--no-new-privs',
          '--bounding-set=-all,+net_bind_service', '--inh-caps=+net_bind_service', '--ambient-caps=+net_bind_service']
client = {'log': {'level': 'error'}, 'inbounds': [], 'outbounds': [], 'route': {'rules': []}}
for index, outbound in enumerate([
    {'type': 'shadowsocks', 'server_port': 1443, 'method': '2022-blake3-aes-256-gcm', 'password': ss_password},
    {'type': 'socks', 'server_port': 108, 'username': 'test-user', 'password': 'test-password'},
    {'type': 'hysteria2', 'server_port': 443, 'password': 'test-password', 'up_mbps': 50, 'down_mbps': 100,
     'obfs': {'type': 'salamander', 'password': 'test-obfs'}, 'tls': {'enabled': True, 'insecure': True, 'server_name': 'www.bing.com'}},
]):
    tag = f'proxy-{index}'
    outbound.update(server='127.0.0.1', tag=tag)
    client['outbounds'].append(outbound)
    client['inbounds'].append({'type': 'socks', 'tag': tag, 'listen': '127.0.0.1', 'listen_port': 1081+index})
    client['route']['rules'].append({'inbound': [tag], 'outbound': tag})
client_path = root/'client.json'
client_path.write_text(json.dumps(client)); os.chown(client_path, 0, int(gid)); os.chmod(client_path, 0o640)
class Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'UNPRIVILEGED_PROXY_OK')
    def log_message(self, *args): pass
httpd = http.server.ThreadingHTTPServer(('127.0.0.1',18080), Echo)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
processes = []
def read_exact(sock, n):
    data=b''
    while len(data)<n:
        chunk=sock.recv(n-len(data))
        if not chunk: raise RuntimeError('Unexpected proxy EOF')
        data+=chunk
    return data
try:
    for name, path in [('server', config), ('client', str(client_path))]:
        with (root/f'{name}.log').open('w') as log:
            processes.append(subprocess.Popen(prefix+[binary, 'run', '-c', path], stdout=log, stderr=log))
    for index in range(3):
        deadline=time.monotonic()+12
        while True:
            try: sock=socket.create_connection(('127.0.0.1',1081+index), timeout=3); break
            except OSError:
                assert time.monotonic()<deadline, 'proxy startup timed out'
                time.sleep(.1)
        with sock:
            sock.settimeout(10)
            sock.sendall(b'\x05\x01\x00'); assert read_exact(sock,2)==b'\x05\x00'
            sock.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',18080))
            response=read_exact(sock,4); assert response[1]==0, response
            if response[3]==1: read_exact(sock,6)
            elif response[3]==4: read_exact(sock,18)
            else: read_exact(sock,read_exact(sock,1)[0]+2)
            sock.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n')
            data=b''
            while True:
                chunk=sock.recv(8192)
                if not chunk: break
                data+=chunk
            assert b'UNPRIVILEGED_PROXY_OK' in data, data
        print('PASS: actual unprivileged '+['SS2022','SOCKS5 (TCP 108)','Hysteria2 (UDP 443)'][index]+' forwarding')
    for process in processes:
        status=pathlib.Path(f'/proc/{process.pid}/status').read_text()
        fields=dict(line.split(':',1) for line in status.splitlines() if ':' in line)
        assert fields['Uid'].split()==[uid]*4
        assert int(fields['CapBnd'].strip(),16)==0x400
        assert fields['NoNewPrivs'].strip()=='1'
except Exception:
    for path in root.glob('*.log'): print(path.name, path.read_text(), file=sys.stderr)
    raise
finally:
    for process in processes: process.terminate()
    for process in processes:
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    httpd.shutdown()
PY
