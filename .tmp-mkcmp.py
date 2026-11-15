import json, sys

st = {}
for line in open('/root/vps-vpn/state.env'):
    line = line.strip()
    if '=' in line:
        k, v = line.split('=', 1)
        st[k] = v

kind = sys.argv[1]
port = int(sys.argv[2])

ob = None
if kind == 'vless':
    ob = {
        "type": "vless",
        "tag": "proxy",
        "server": st["PUBLIC_IP"],
        "server_port": int(st["PORT"]),
        "uuid": st["UUID"],
        "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True,
            "server_name": "www.microsoft.com",
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {
                "enabled": True,
                "public_key": st["REALITY_PUBLIC_KEY"],
                "short_id": st["SHORT_ID"],
            },
        },
    }
elif kind == 'hy2':
    ob = {
        "type": "hysteria2",
        "tag": "proxy",
        "server": st["PUBLIC_IP"],
        "server_port": int(st["HY2_PORT"]),
        "password": st["HY2_PASSWORD"],
        "tls": {
            "enabled": True,
            "server_name": "www.microsoft.com",
            "insecure": True,
            "alpn": ["h3"],
        },
    }

cfg = {
    "log": {"level": "warn"},
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}],
    "outbounds": [ob],
}
json.dump(cfg, open(f'/tmp/cmp-{kind}.json', 'w'), indent=2)
print(f"wrote /tmp/cmp-{kind}.json")
