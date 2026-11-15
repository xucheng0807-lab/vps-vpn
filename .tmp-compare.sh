#!/usr/bin/env bash
# Fair A/B: same VPS, same target, same conditions. VLESS/TCP vs Hysteria2/UDP.
set -u

TARGET="https://speed.cloudflare.com/__down?bytes=50000000"

run_one() {
  local kind="$1" port="$2" label="$3"
  python3 /tmp/mkcmp.py "$kind" "$port" >/dev/null 2>&1 || { echo "  build fail"; return; }
  pkill -f "cmp-$kind.json" >/dev/null 2>&1 || true
  sleep 1
  setsid sing-box run -c "/tmp/cmp-$kind.json" >"/tmp/cmp-$kind.log" 2>&1 </dev/null &
  sleep 4

  local best=0 total=0 n=0
  for i in 1 2 3; do
    local sp
    sp=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 30 --proxy "http://127.0.0.1:$port" "$TARGET" 2>/dev/null || echo 0)
    sp=${sp%.*}
    [ -z "$sp" ] && sp=0
    echo "    run$i: $sp B/s"
    total=$((total + sp)); n=$((n + 1))
    [ "$sp" -gt "$best" ] && best=$sp
  done
  local avg=$((total / n))
  printf "  %-10s avg=%s B/s (%.1f Mbps)  best=%s B/s (%.1f Mbps)\n" \
    "$label" "$avg" "$(awk -v v="$avg" 'BEGIN{print v*8/1000000}')" \
    "$best" "$(awk -v v="$best" 'BEGIN{print v*8/1000000}')"
  pkill -f "cmp-$kind.json" >/dev/null 2>&1 || true
  sleep 1
}

echo "=== 场景 1: 正常链路 ==="
run_one vless 11001 "VLESS"
run_one hy2   11002 "Hysteria2"

echo
echo "=== 场景 2: 模拟 3% 丢包 (netem, lo) ==="
tc qdisc del dev lo root 2>/dev/null || true
tc qdisc add dev lo root netem loss 3% 2>/dev/null && echo "  netem: loss 3% applied" || echo "  netem unavailable"
run_one vless 11003 "VLESS"
run_one hy2   11004 "Hysteria2"
tc qdisc del dev lo root 2>/dev/null || true

echo
echo "=== 场景 3: 模拟 100ms 延迟 + 5% 丢包 ==="
tc qdisc add dev lo root netem delay 100ms loss 5% 2>/dev/null && echo "  netem: delay 100ms loss 5%" || echo "  netem unavailable"
run_one vless 11005 "VLESS"
run_one hy2   11006 "Hysteria2"
tc qdisc del dev lo root 2>/dev/null || true

echo
echo "=== 清理 ==="
tc qdisc del dev lo root 2>/dev/null || true
pkill -f "cmp-" >/dev/null 2>&1 || true
echo done
