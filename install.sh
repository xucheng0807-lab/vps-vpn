#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="vps-vpn"
# shellcheck disable=SC2034  # consumed by state/config functions defined below
STATE_DIR="${STATE_DIR:-/root/vps-vpn}"
DEFAULT_PORT=443
DEFAULT_HOP_RANGE="20000-30000"
DEFAULT_REALITY_TARGET="learn.microsoft.com"
readonly REALITY_SNI_CANDIDATES=(
    "learn.microsoft.com"
    "www.apple.com"
    "www.nvidia.com"
    "www.amd.com"
    "swdist.apple.com"
)

# Installable paths (overridable for tests).
SING_BOX_CONFIG_PATH="${SING_BOX_CONFIG_PATH:-/etc/sing-box/config.json}"
CLI_INSTALL_PATH="${CLI_INSTALL_PATH:-/usr/local/bin/vps-vpn}"
PORT_HOP_HELPER_PATH="${PORT_HOP_HELPER_PATH:-/usr/local/libexec/vps-vpn-port-hop}"
PORT_HOP_NFT_PATH="${PORT_HOP_NFT_PATH:-/etc/vps-vpn/port-hop.nft}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --ip IP             手动指定公网 IPv4 地址（默认自动检测）
  --port PORT         指定 VLESS TCP 端口（默认 443）
  --sni DOMAIN        指定 REALITY 伪装域名（默认自动验证 TLS 1.3 + H2 并择低延迟目标）
  --hy2-port PORT     指定 Hysteria 2 的 UDP 监听端口（默认随机高端口）
  --hop-range A-B     指定 Hysteria 2 端口跳跃 UDP 范围（默认 20000-30000）
  --no-port-hop       关闭 Hysteria 2 端口跳跃，仅使用单一 UDP 端口
  --hy2-up MBPS       可选：设置 HY2 上行带宽（Mbps），与 --hy2-down 同时指定可启用 Brutal
  --hy2-down MBPS     可选：设置 HY2 下行带宽（Mbps），与 --hy2-up 同时指定可启用 Brutal
  --no-hy2            不部署 Hysteria 2，仅保留 VLESS + REALITY
  --upgrade           即使已安装满足版本的 sing-box，也强制升级到脚本目标版本
  --skip-deps         跳过自动安装系统依赖（已自行备好环境时使用）
  --help              显示此帮助信息
EOF
    exit "${1:-0}"
}

is_valid_domain() {
    local d="$1"
    [[ ${#d} -ge 3 && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

is_valid_port_range() {
    local range="$1" lo hi
    [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    lo=$((10#${BASH_REMATCH[1]}))
    hi=$((10#${BASH_REMATCH[2]}))
    (( lo >= 1024 && hi <= 65535 && lo < hi ))
}

parse_args() {
    IP=""
    PORT="$DEFAULT_PORT"
    PORT_EXPLICIT=0
    SKIP_DEPS=0
    UPGRADE_SING_BOX=0
    # Deliberately empty: generate_credentials calls choose_hy2_port() when this
    # is unset.
    HY2_PORT=""
    HY2_PORT_EXPLICIT=0
    ENABLE_HY2=1
    ENABLE_PORT_HOP=1
    PORT_HOP_EXPLICIT=0
    HY2_HOP_RANGE="$DEFAULT_HOP_RANGE"
    HY2_HOP_RANGE_EXPLICIT=0
    REALITY_TARGET=""
    SNI_EXPLICIT=0
    HY2_UP=""
    HY2_DOWN=""
    HY2_BW_EXPLICIT=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)
                [[ $# -ge 2 ]] || { echo "错误：--ip 需要一个参数" >&2; usage 2; }
                if ! is_valid_public_ipv4 "$2"; then
                    echo "错误：--ip 不是合法的公网 IPv4 地址: $2" >&2
                    usage 2
                fi
                IP="$2"
                shift 2
                ;;
            --port)
                [[ $# -ge 2 ]] || { echo "错误：--port 需要一个参数" >&2; usage 2; }
                if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 || 10#$2 > 65535 )); then
                    echo "错误：--port 必须是 1-65535 之间的端口号: $2" >&2
                    usage 2
                fi
                PORT="$((10#$2))"
                PORT_EXPLICIT=1
                shift 2
                ;;
            --sni)
                [[ $# -ge 2 ]] || { echo "错误：--sni 需要一个参数" >&2; usage 2; }
                if ! is_valid_domain "$2"; then
                    echo "错误：--sni 不是合法的域名: $2" >&2
                    usage 2
                fi
                REALITY_TARGET="$2"
                SNI_EXPLICIT=1
                shift 2
                ;;
            --hy2-port)
                [[ $# -ge 2 ]] || { echo "错误：--hy2-port 需要一个参数" >&2; usage 2; }
                if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 || 10#$2 > 65535 )); then
                    echo "错误：--hy2-port 必须是 1-65535 之间的端口号: $2" >&2
                    usage 2
                fi
                HY2_PORT="$((10#$2))"
                HY2_PORT_EXPLICIT=1
                shift 2
                ;;
            --hop-range)
                [[ $# -ge 2 ]] || { echo "错误：--hop-range 需要一个参数（如 20000-30000）" >&2; usage 2; }
                if ! is_valid_port_range "$2"; then
                    echo "错误：--hop-range 格式无效，需为 1024-65535 之间的起止范围（如 20000-30000）: $2" >&2
                    usage 2
                fi
                HY2_HOP_RANGE="$2"
                HY2_HOP_RANGE_EXPLICIT=1
                ENABLE_PORT_HOP=1
                PORT_HOP_EXPLICIT=1
                shift 2
                ;;
            --no-port-hop)
                ENABLE_PORT_HOP=0
                PORT_HOP_EXPLICIT=1
                shift
                ;;
            --hy2-up)
                [[ $# -ge 2 ]] || { echo "错误：--hy2-up 需要一个整数参数（单位 Mbps）" >&2; usage 2; }
                if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 || 10#$2 > 10000 )); then
                    echo "错误：--hy2-up 必须是 1-10000 之间的正整数（Mbps）: $2" >&2
                    usage 2
                fi
                HY2_UP="$((10#$2))"
                HY2_BW_EXPLICIT=1
                shift 2
                ;;
            --hy2-down)
                [[ $# -ge 2 ]] || { echo "错误：--hy2-down 需要一个整数参数（单位 Mbps）" >&2; usage 2; }
                if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 || 10#$2 > 10000 )); then
                    echo "错误：--hy2-down 必须是 1-10000 之间的正整数（Mbps）: $2" >&2
                    usage 2
                fi
                HY2_DOWN="$((10#$2))"
                HY2_BW_EXPLICIT=1
                shift 2
                ;;
            --no-hy2)
                ENABLE_HY2=0
                shift
                ;;
            --upgrade)
                UPGRADE_SING_BOX=1
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --help)
                usage 0
                ;;
            *)
                echo "未知参数: $1" >&2
                usage 2
                ;;
        esac
    done

    if [[ -n "$HY2_UP" && -z "$HY2_DOWN" ]] || [[ -z "$HY2_UP" && -n "$HY2_DOWN" ]]; then
        echo "错误：--hy2-up 与 --hy2-down 必须同时指定以启用 Brutal 拥塞控制" >&2
        usage 2
    fi
}

# Strict validator: a legal global-unicast IPv4 address only.
# Rejects malformed octets, private, loopback, link-local, CGNAT and reserved.
is_valid_public_ipv4() {
    local ip="$1" a b c d o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || return 1
    done
    a=$((10#$a)); b=$((10#$b))
    (( a == 0 )) && return 1                                   # 0.0.0.0/8
    (( a == 10 )) && return 1                                  # 10/8 private
    (( a == 127 )) && return 1                                 # loopback
    (( a >= 224 )) && return 1                                 # multicast / reserved
    (( a == 169 && b == 254 )) && return 1                     # link-local
    (( a == 172 && b >= 16 && b <= 31 )) && return 1           # 172.16/12 private
    (( a == 192 && b == 168 )) && return 1                     # 192.168/16 private
    (( a == 100 && b >= 64 && b <= 127 )) && return 1          # 100.64/10 CGNAT
    (( a == 192 && b == 0 )) && return 1                       # 192.0.0/24, 192.0.2/24 (TEST-NET-1)
    (( a == 198 && (b == 18 || b == 19) )) && return 1         # 198.18/15 benchmark
    (( a == 198 && b == 51 )) && return 1                      # 198.51.100/24 (TEST-NET-2)
    (( a == 203 && b == 0 )) && return 1                       # 203.0.113/24 (TEST-NET-3)
    return 0
}

# Detect the public IPv4 and set PUBLIC_IP (global; not run in a subshell so
# IP_DETECT_SINGLE survives for the summary hint). Returns non-zero when
# undetectable/ambiguous.
detect_public_ip() {
    local services=("https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip")
    local results=() uniq=()
    local service ip r u found
    IP_DETECT_SINGLE=0

    for service in "${services[@]}"; do
        ip=$(curl -fsSL --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]') || true
        if [[ -n "$ip" ]] && is_valid_public_ipv4 "$ip"; then
            results+=("$ip")
        fi
    done

    for r in "${results[@]+"${results[@]}"}"; do
        found=0
        for u in "${uniq[@]+"${uniq[@]}"}"; do
            [[ "$u" == "$r" ]] && { found=1; break; }
        done
        [[ $found -eq 0 ]] && uniq+=("$r")
    done

    case "${#uniq[@]}" in
        0) return 1 ;;
        1)
            [[ ${#results[@]} -lt 2 ]] && IP_DETECT_SINGLE=1
            PUBLIC_IP="${uniq[0]}"
            return 0
            ;;
        *) return 1 ;;
    esac
}

# Resolve the real (non-root) user who invoked sudo. Uses getent so the home
# directory comes from the system account database, never from path guessing.
# Populates USER_NAME, USER_HOME, USER_ID, GROUP_ID.
detect_user_context() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local record
        record=$(getent passwd "$SUDO_USER" 2>/dev/null) || true
        if [[ -z "$record" ]]; then
            echo "错误：无法解析用户 $SUDO_USER" >&2
            return 1
        fi
        IFS=: read -r _ _ USER_ID GROUP_ID _ USER_HOME _ <<<"$record"
        USER_NAME="$SUDO_USER"
        echo "检测到用户: $USER_NAME (home: $USER_HOME)" >&2
    else
        USER_NAME="root"
        USER_HOME="/root"
        USER_ID=0
        GROUP_ID=0
        echo "检测到用户: $USER_NAME (home: $USER_HOME)" >&2
    fi
}

# --- REALITY SNI probe & selection ------------------------------------------

# Verify that a candidate host supports TLS 1.3 + HTTP/2 (ALPN h2) on TCP 443.
# Prints handshake latency in ms (integer) on success; returns non-zero on failure.
probe_sni_target() {
    local host="$1" out ms=""
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 5 openssl s_client -connect "$host:443" -servername "$host" \
            -tls1_3 -alpn h2 -brief </dev/null 2>&1) || return 1
    else
        out=$(openssl s_client -connect "$host:443" -servername "$host" \
            -tls1_3 -alpn h2 -brief </dev/null 2>&1) || return 1
    fi
    grep -qi 'TLSv1\.3' <<<"$out" || return 1
    grep -qi 'ALPN.*h2' <<<"$out" || return 1

    # Measure TCP connect + TLS handshake time via curl when available.
    if command -v curl >/dev/null 2>&1; then
        local sec
        sec=$(curl -o /dev/null -sS --connect-timeout 3 --max-time 5 \
            --tlsv1.3 --http2 -w '%{time_appconnect}' "https://$host/" 2>/dev/null || true)
        if [[ "$sec" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            ms=$(awk -v s="$sec" 'BEGIN { printf "%d", s * 1000 }')
        fi
    fi
    echo "${ms:-999}"
    return 0
}

# Resolve REALITY_TARGET:
# 1. Explicit --sni: verify TLS 1.3 + H2 reachability (fail clearly if broken).
# 2. Existing state.env: reuse persisted SNI (or www.microsoft.com for legacy v1 state).
# 3. Fresh install: probe curated candidates and pick the lowest-latency TLS 1.3 + H2 target.
select_reality_sni() {
    if [[ "${SNI_EXPLICIT:-0}" -eq 1 ]]; then
        if [[ "${SKIP_SNI_CHECK:-0}" -eq 1 ]]; then
            echo "使用指定 REALITY SNI: $REALITY_TARGET" >&2
            return 0
        fi
        local ms
        if ms=$(probe_sni_target "$REALITY_TARGET"); then
            echo "已验证 REALITY SNI: $REALITY_TARGET (TLS 1.3 + H2, ${ms}ms)" >&2
            return 0
        fi
        echo "错误：指定的 --sni $REALITY_TARGET 未通过 TLS 1.3 + H2 连通性校验，请更换域名" >&2
        return 1
    fi

    if [[ -n "${REALITY_TARGET:-}" ]]; then
        echo "复用已有 REALITY SNI: $REALITY_TARGET" >&2
        return 0
    fi

    if [[ "${SKIP_SNI_CHECK:-0}" -eq 1 ]]; then
        REALITY_TARGET="$DEFAULT_REALITY_TARGET"
        return 0
    fi

    echo "正在自动测速优选 REALITY 伪装目标（TLS 1.3 + H2）..." >&2
    local best_host="" best_ms=999999 cand ms
    for cand in "${REALITY_SNI_CANDIDATES[@]}"; do
        if ms=$(probe_sni_target "$cand" 2>/dev/null); then
            if [[ "$ms" =~ ^[0-9]+$ ]] && (( ms < best_ms )); then
                best_ms="$ms"
                best_host="$cand"
            fi
        fi
    done

    if [[ -n "$best_host" ]]; then
        REALITY_TARGET="$best_host"
        echo "已优选 REALITY SNI: $REALITY_TARGET (TLS 1.3 + H2, ${best_ms}ms)" >&2
    else
        REALITY_TARGET="$DEFAULT_REALITY_TARGET"
        echo "提示：候选目标探测未成功，回退默认 REALITY SNI: $REALITY_TARGET" >&2
    fi
    return 0
}

# --- credentials & state ----------------------------------------------------

readonly UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly HEX_RE='^[0-9a-fA-F]+$'
readonly KEY_RE='^[A-Za-z0-9_=-]+$'
readonly PW_RE='^[A-Za-z0-9._-]+$'

# Generate a UUID (Linux kernel interface, falling back to openssl).
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local h
        h=$(openssl rand -hex 16)
        printf '%s-%s-%s-%s-%s\n' \
            "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
    fi
}

# Parse `sing-box generate reality-keypair` output into REALITY_PRIVATE_KEY/
# REALITY_PUBLIC_KEY. Accepts "PrivateKey: x" / "Private key: x" (case &
# spacing insensitive) and bare base64 lines.
parse_keypair() {
    local out="$1" line lower val
    while IFS= read -r line; do
        lower="${line,,}"                       # lowercase for matching
        if [[ "$lower" == *private* ]]; then
            val="${line#*: }"
            [[ "$val" == "$line" ]] && val="${line#*:}"
            REALITY_PRIVATE_KEY="${val//[[:space:]]/}"
        elif [[ "$lower" == *public* ]]; then
            val="${line#*: }"
            [[ "$val" == "$line" ]] && val="${line#*:}"
            REALITY_PUBLIC_KEY="${val//[[:space:]]/}"
        fi
    done <<<"$out"

    if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
        local -a lines=()
        mapfile -t lines <<<"$out"
        REALITY_PRIVATE_KEY="${lines[0]:-}"; REALITY_PUBLIC_KEY="${lines[1]:-}"
        REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY//[[:space:]]/}"
        REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY//[[:space:]]/}"
    fi
    [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] || return 1
}

# Compute lowercase hex SHA-256 fingerprint of a PEM certificate (for Mihomo
# SSL pinning & hysteria2:// pinSHA256).
get_cert_fingerprint() {
    local crt="$1" raw
    [[ -s "$crt" ]] || return 1
    raw=$(openssl x509 -noout -fingerprint -sha256 -in "$crt" 2>/dev/null) || return 1
    raw="${raw#*=}"
    raw="${raw//:/}"
    raw="${raw//[[:space:]]/}"
    printf '%s\n' "${raw,,}"
}

# Self-signed certificate for Hysteria 2 (required: hysteria2 has no REALITY).
# Uses REALITY_TARGET as CN/SAN instead of a fingerprintable "vps-vpn" string.
# Certs go under SING_BOX_CERT_DIR (/etc/sing-box), NOT /root/vps-vpn: the
# service runs as the unprivileged "sing-box" user and cannot traverse /root.
# Reuses an existing pair unless force=1 (rotation) or legacy CN=vps-vpn upgrade.
generate_hy2_cert() {
    local force="${1:-0}"
    local dir="${SING_BOX_CERT_DIR:-/etc/sing-box}"
    local crt="$dir/hy2.crt" key="$dir/hy2.key"
    local cn="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    mkdir -p "$dir"

    if [[ "$force" -ne 1 && -s "$crt" && -s "$key" ]]; then
        HY2_CERT_FINGERPRINT=$(get_cert_fingerprint "$crt" || true)
        return 0
    fi

    local tmpkey tmpcrt cfg
    tmpkey=$(mktemp)
    tmpcrt=$(mktemp)
    cfg=$(mktemp)
    cat > "$cfg" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $cn
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$cn
CNF
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$tmpkey" -out "$tmpcrt" -days 3650 -nodes \
        -config "$cfg" >/dev/null 2>&1; then
        echo "错误：无法生成 Hysteria 2 自签证书" >&2
        rm -f "$tmpkey" "$tmpcrt" "$cfg"
        return 1
    fi
    rm -f "$cfg"
    # Move into place, then hand ownership to the service user so it can read.
    install -m 600 "$tmpkey" "$key"
    install -m 644 "$tmpcrt" "$crt"
    rm -f "$tmpkey" "$tmpcrt"
    local svc="${SING_BOX_SERVICE_USER:-sing-box}"
    if id "$svc" >/dev/null 2>&1; then
        chown "$svc:$svc" "$key" "$crt" 2>/dev/null || true
    fi
    chmod 600 "$key"
    chmod 644 "$crt"
    HY2_CERT_FINGERPRINT=$(get_cert_fingerprint "$crt" || true)
    echo "已生成 Hysteria 2 自签证书（CN=$cn）" >&2
}

generate_credentials() {
    if [[ -f "$STATE_DIR/state.env" ]]; then
        echo "加载已有凭据..." >&2
        load_state || return 1
        local changed=0

        # Reuse the stored VLESS port unless explicitly overridden.
        if [[ "${PORT_EXPLICIT:-0}" -eq 0 && -n "${STATE_PORT:-}" ]]; then
            PORT="$STATE_PORT"
        elif [[ "${PORT_EXPLICIT:-0}" -eq 1 && "${STATE_PORT:-}" != "$PORT" ]]; then
            changed=1
        fi

        # Reuse the stored HY2 port unless explicitly overridden via --hy2-port.
        if [[ "${HY2_PORT_EXPLICIT:-0}" -eq 0 && -n "${STATE_HY2_PORT:-}" ]]; then
            HY2_PORT="$STATE_HY2_PORT"
        elif [[ "${HY2_PORT_EXPLICIT:-0}" -eq 1 && "${STATE_HY2_PORT:-}" != "$HY2_PORT" ]]; then
            changed=1
        fi

        # Reuse stored REALITY SNI unless --sni was explicitly given.
        # Legacy v1 state.env had no REALITY_TARGET key and used www.microsoft.com.
        if [[ "${SNI_EXPLICIT:-0}" -eq 0 ]]; then
            if [[ -n "${STATE_REALITY_TARGET:-}" ]]; then
                REALITY_TARGET="$STATE_REALITY_TARGET"
            else
                REALITY_TARGET="www.microsoft.com"
                changed=1
            fi
        else
            select_reality_sni || return 1
            if [[ "${STATE_REALITY_TARGET:-}" != "$REALITY_TARGET" ]]; then
                changed=1
            fi
        fi

        # Port hopping range & toggle reconciliation.
        if [[ "${PORT_HOP_EXPLICIT:-0}" -eq 0 && -n "${STATE_ENABLE_PORT_HOP:-}" ]]; then
            ENABLE_PORT_HOP="$STATE_ENABLE_PORT_HOP"
        elif [[ "${PORT_HOP_EXPLICIT:-0}" -eq 1 && "${STATE_ENABLE_PORT_HOP:-}" != "$ENABLE_PORT_HOP" ]]; then
            changed=1
        fi
        if [[ "${HY2_HOP_RANGE_EXPLICIT:-0}" -eq 0 && -n "${STATE_HY2_HOP_RANGE:-}" ]]; then
            HY2_HOP_RANGE="$STATE_HY2_HOP_RANGE"
        elif [[ "${HY2_HOP_RANGE_EXPLICIT:-0}" -eq 1 && "${STATE_HY2_HOP_RANGE:-}" != "$HY2_HOP_RANGE" ]]; then
            changed=1
        fi

        # Optional Brutal bandwidth reconciliation.
        if [[ "${HY2_BW_EXPLICIT:-0}" -eq 0 ]]; then
            HY2_UP="${STATE_HY2_UP:-}"
            HY2_DOWN="${STATE_HY2_DOWN:-}"
        elif [[ "${STATE_HY2_UP:-}" != "${HY2_UP:-}" || "${STATE_HY2_DOWN:-}" != "${HY2_DOWN:-}" ]]; then
            changed=1
        fi

        # Backfill Hysteria 2 credentials when upgrading a legacy state.env.
        if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
            if [[ -z "${HY2_PORT:-}" ]]; then
                HY2_PORT=$(choose_hy2_port)
                changed=1
            fi
            if [[ -z "${HY2_PASSWORD:-}" ]]; then
                HY2_PASSWORD=$(openssl rand -hex 16)
                changed=1
            fi
        fi

        [[ $changed -eq 1 ]] && save_state
        return 0
    fi

    echo "生成新凭据..." >&2
    UUID=$(gen_uuid)
    [[ "$UUID" =~ $UUID_RE ]] || { echo "错误：生成的 UUID 无效" >&2; return 1; }

    local keypair
    keypair=$(sing-box generate reality-keypair) || {
        echo "错误：无法生成 REALITY 密钥对（sing-box 未安装？）" >&2
        return 1
    }
    parse_keypair "$keypair" || { echo "错误：解析 REALITY 密钥对失败" >&2; return 1; }

    SHORT_ID=$(openssl rand -hex 4)
    select_reality_sni || return 1

    if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
        HY2_PORT="${HY2_PORT:-$(choose_hy2_port)}"
        HY2_PASSWORD=$(openssl rand -hex 16)
    fi
    save_state
}

# Read state.env without sourcing it. Rejects bad value formats; ignores any
# key outside the known set. Never overwrites CLI-explicit overrides.
load_state() {
    local file="$STATE_DIR/state.env" key value n=0
    STATE_PORT=""
    STATE_HY2_PORT=""
    STATE_REALITY_TARGET=""
    STATE_ENABLE_PORT_HOP=""
    STATE_HY2_HOP_RANGE=""
    STATE_HY2_UP=""
    STATE_HY2_DOWN=""

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            UUID)
                [[ "$value" =~ $UUID_RE ]] || { echo "错误：state.env 中 UUID 格式无效" >&2; return 1; }
                UUID="$value" ;;
            REALITY_PRIVATE_KEY)
                [[ -n "$value" && "$value" =~ $KEY_RE ]] || { echo "错误：state.env 中 REALITY_PRIVATE_KEY 格式无效" >&2; return 1; }
                REALITY_PRIVATE_KEY="$value" ;;
            REALITY_PUBLIC_KEY)
                [[ -z "$value" || "$value" =~ $KEY_RE ]] || { echo "错误：state.env 中 REALITY_PUBLIC_KEY 格式无效" >&2; return 1; }
                REALITY_PUBLIC_KEY="$value" ;;
            SHORT_ID)
                [[ "$value" =~ $HEX_RE ]] || { echo "错误：state.env 中 SHORT_ID 格式无效" >&2; return 1; }
                SHORT_ID="$value" ;;
            PORT)
                [[ "$value" =~ ^[0-9]+$ ]] || { echo "错误：state.env 中 PORT 格式无效" >&2; return 1; }
                STATE_PORT="$value" ;;
            PUBLIC_IP)
                ;; # detected fresh or provided via --ip on each run
            REALITY_TARGET)
                if [[ -n "$value" ]]; then
                    is_valid_domain "$value" || { echo "错误：state.env 中 REALITY_TARGET 格式无效" >&2; return 1; }
                    STATE_REALITY_TARGET="$value"
                    [[ "${SNI_EXPLICIT:-0}" -eq 0 ]] && REALITY_TARGET="$value"
                fi ;;
            HY2_PORT)
                if [[ -n "$value" ]]; then
                    [[ "$value" =~ ^[0-9]+$ ]] || { echo "错误：state.env 中 HY2_PORT 格式无效" >&2; return 1; }
                    STATE_HY2_PORT="$value"
                    [[ "${HY2_PORT_EXPLICIT:-0}" -eq 0 ]] && HY2_PORT="$value"
                fi ;;
            HY2_PASSWORD)
                [[ -z "$value" || "$value" =~ $PW_RE ]] || { echo "错误：state.env 中 HY2_PASSWORD 格式无效" >&2; return 1; }
                HY2_PASSWORD="$value" ;;
            ENABLE_PORT_HOP)
                [[ -z "$value" || "$value" == "0" || "$value" == "1" ]] || { echo "错误：state.env 中 ENABLE_PORT_HOP 格式无效" >&2; return 1; }
                STATE_ENABLE_PORT_HOP="$value" ;;
            HY2_HOP_RANGE)
                if [[ -n "$value" ]]; then
                    is_valid_port_range "$value" || { echo "错误：state.env 中 HY2_HOP_RANGE 格式无效" >&2; return 1; }
                    STATE_HY2_HOP_RANGE="$value"
                fi ;;
            HY2_UP)
                [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] || { echo "错误：state.env 中 HY2_UP 格式无效" >&2; return 1; }
                STATE_HY2_UP="$value" ;;
            HY2_DOWN)
                [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] || { echo "错误：state.env 中 HY2_DOWN 格式无效" >&2; return 1; }
                STATE_HY2_DOWN="$value" ;;
            HY2_CERT_FINGERPRINT)
                [[ -z "$value" || "$value" =~ $HEX_RE ]] || { echo "错误：state.env 中 HY2_CERT_FINGERPRINT 格式无效" >&2; return 1; }
                HY2_CERT_FINGERPRINT="$value" ;;
            *) ;;  # unknown key: ignore, never evaluate
        esac
        n=$((n + 1))
    done < "$file"

    (( n > 0 )) || { echo "错误：state.env 内容无效" >&2; return 1; }
    [[ -n "${UUID:-}" ]] || { echo "错误：state.env 缺少 UUID" >&2; return 1; }
    [[ -n "${REALITY_PRIVATE_KEY:-}" ]] || { echo "错误：state.env 缺少私钥" >&2; return 1; }
    [[ -n "${SHORT_ID:-}" ]] || { echo "错误：state.env 缺少 SHORT_ID" >&2; return 1; }
    return 0
}

# Atomically write state.env with 0600 perms inside a 0700 directory.
save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.state.env.XXXXXX")
    chmod 600 "$tmp"
    {
        printf 'UUID=%s\n' "$UUID"
        printf 'REALITY_PRIVATE_KEY=%s\n' "$REALITY_PRIVATE_KEY"
        printf 'REALITY_PUBLIC_KEY=%s\n' "${REALITY_PUBLIC_KEY:-}"
        printf 'SHORT_ID=%s\n' "$SHORT_ID"
        printf 'PORT=%s\n' "$PORT"
        printf 'PUBLIC_IP=%s\n' "${PUBLIC_IP:-}"
        printf 'REALITY_TARGET=%s\n' "${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
        printf 'HY2_PORT=%s\n' "${HY2_PORT:-}"
        printf 'HY2_PASSWORD=%s\n' "${HY2_PASSWORD:-}"
        printf 'ENABLE_PORT_HOP=%s\n' "${ENABLE_PORT_HOP:-1}"
        printf 'HY2_HOP_RANGE=%s\n' "${HY2_HOP_RANGE:-$DEFAULT_HOP_RANGE}"
        printf 'HY2_UP=%s\n' "${HY2_UP:-}"
        printf 'HY2_DOWN=%s\n' "${HY2_DOWN:-}"
        printf 'HY2_CERT_FINGERPRINT=%s\n' "${HY2_CERT_FINGERPRINT:-}"
    } > "$tmp"
    mv -f "$tmp" "$STATE_DIR/state.env"
    chmod 600 "$STATE_DIR/state.env"
}

# --- server config ----------------------------------------------------------

# Embedded server template (VLESS + REALITY only, with private/IMDS protection).
server_template() {
    cat <<'JSON'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": {{PORT}},
      "users": [
        {
          "uuid": "{{UUID}}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "{{REALITY_TARGET}}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "{{REALITY_TARGET}}",
            "server_port": 443
          },
          "private_key": "{{REALITY_PRIVATE_KEY}}",
          "short_id": ["{{SHORT_ID}}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff",
        "timeout": "1s"
      },
      {
        "action": "resolve",
        "strategy": "prefer_ipv4"
      },
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "ip_cidr": [
          "169.254.0.0/16",
          "100.64.0.0/10"
        ],
        "action": "reject"
      }
    ],
    "final": "direct"
  }
}
JSON
}

# Embedded server template WITH Hysteria 2 (masquerade + optional Brutal limits
# + private/IMDS protection).
server_template_hy2() {
    local bw_lines=""
    if [[ -n "${HY2_UP:-}" && -n "${HY2_DOWN:-}" ]]; then
        # Server perspective: client down = server up, client up = server down.
        bw_lines="      \"up_mbps\": ${HY2_DOWN},
      \"down_mbps\": ${HY2_UP},"
    fi
    cat <<JSON
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": {{PORT}},
      "users": [
        {
          "uuid": "{{UUID}}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "{{REALITY_TARGET}}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "{{REALITY_TARGET}}",
            "server_port": 443
          },
          "private_key": "{{REALITY_PRIVATE_KEY}}",
          "short_id": ["{{SHORT_ID}}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": {{HY2_PORT}},
${bw_lines:+${bw_lines}
}      "users": [
        {
          "password": "{{HY2_PASSWORD}}"
        }
      ],
      "masquerade": "https://{{REALITY_TARGET}}",
      "tls": {
        "enabled": true,
        "server_name": "{{REALITY_TARGET}}",
        "alpn": ["h3"],
        "certificate_path": "{{HY2_CERT}}",
        "key_path": "{{HY2_KEY}}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff",
        "timeout": "1s"
      },
      {
        "action": "resolve",
        "strategy": "prefer_ipv4"
      },
      {
        "ip_is_private": true,
        "action": "reject"
      },
      {
        "ip_cidr": [
          "169.254.0.0/16",
          "100.64.0.0/10"
        ],
        "action": "reject"
      }
    ],
    "final": "direct"
  }
}
JSON
}

# Render the server JSON from the embedded template. Dynamic values are already
# format-validated upstream; uses | delimiter for sed safety. Prints path.
generate_server_config() {
    local config_file="$STATE_DIR/sing-box-server.json"
    local target="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    local cert_dir="${SING_BOX_CERT_DIR:-/etc/sing-box}"

    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.server.json.XXXXXX")
    if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
        server_template_hy2 | sed \
            -e "s|{{PORT}}|$PORT|g" \
            -e "s|{{UUID}}|$UUID|g" \
            -e "s|{{REALITY_TARGET}}|$target|g" \
            -e "s|{{REALITY_PRIVATE_KEY}}|$REALITY_PRIVATE_KEY|g" \
            -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
            -e "s|{{HY2_CERT}}|$cert_dir/hy2.crt|g" \
            -e "s|{{HY2_KEY}}|$cert_dir/hy2.key|g" \
            -e "s|{{HY2_PORT}}|$HY2_PORT|g" \
            -e "s|{{HY2_PASSWORD}}|$HY2_PASSWORD|g" > "$tmp"
    else
        server_template | sed \
            -e "s|{{PORT}}|$PORT|g" \
            -e "s|{{UUID}}|$UUID|g" \
            -e "s|{{REALITY_TARGET}}|$target|g" \
            -e "s|{{REALITY_PRIVATE_KEY}}|$REALITY_PRIVATE_KEY|g" \
            -e "s|{{SHORT_ID}}|$SHORT_ID|g" > "$tmp"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$config_file"
    chmod 600 "$config_file"
    echo "$config_file"
}

# Verify a server config with sing-box. Non-zero with a diagnostic on failure.
validate_config() {
    local config_file="$1"
    if ! sing-box check -c "$config_file" 2>/dev/null; then
        echo "错误：sing-box 配置校验失败" >&2
        return 1
    fi
}

# --- client config ----------------------------------------------------------

# Shared Mihomo base settings: whitelist China direct split routing (.mrs),
# Fake-IP split DNS (no China DoH deadlock, no remote DNS leak), sniffer,
# persistent manual selection.
client_yaml_header() {
    cat <<'YAML'
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: strict

profile:
  store-selected: true
  store-fake-ip: true

sniffer:
  enable: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-domain:
    - "Mijia Cloud"
    - "+.push.apple.com"

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  respect-rules: true
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.arpa"
    - "time.*.com"
    - "time.*.gov"
    - "time.*.edu.cn"
    - "time.*.apple.com"
    - "ntp.*.com"
    - "+.ntp.org.cn"
    - "+.stun.*.*"
    - "+.stun.*.*.*"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "dns.msftncsi.com"
    - "captive.apple.com"
    - "connectivitycheck.gstatic.com"
    - "localhost.ptlogin2.qq.com"
    - "localhost.sec.qq.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query#DIRECT
    - https://1.12.12.12/dns-query#DIRECT
  direct-nameserver:
    - https://223.5.5.5/dns-query#DIRECT
    - https://1.12.12.12/dns-query#DIRECT
  nameserver-policy:
    "rule-set:private_domain,cn_domain":
      - https://223.5.5.5/dns-query#DIRECT
      - https://1.12.12.12/dns-query#DIRECT
  nameserver:
    - https://1.1.1.1/dns-query#Proxy
    - https://8.8.8.8/dns-query#Proxy

YAML
}

client_yaml_footer() {
    cat <<'YAML'

rule-providers:
  private_domain:
    type: http
    behavior: domain
    format: mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/private.mrs"
    path: ./ruleset/private_domain.mrs
    interval: 86400
  cn_domain:
    type: http
    behavior: domain
    format: mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs"
    path: ./ruleset/cn_domain.mrs
    interval: 86400
  private_ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/private.mrs"
    path: ./ruleset/private_ip.mrs
    interval: 86400
  cn_ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.mrs"
    path: ./ruleset/cn_ip.mrs
    interval: 86400

rules:
  - "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
  - "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
  - "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"
  - "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
  - "RULE-SET,private_domain,DIRECT"
  - "RULE-SET,private_ip,DIRECT,no-resolve"
  - "RULE-SET,cn_domain,DIRECT"
  - "RULE-SET,cn_ip,DIRECT,no-resolve"
  - "MATCH,Proxy"
YAML
}

# Embedded Mihomo client template (VLESS + REALITY only).
client_template() {
    client_yaml_header
    cat <<'YAML'
proxies:
  - name: "vps-vpn-vless"
    type: vless
    server: {{PUBLIC_IP}}
    port: {{PORT}}
    uuid: {{UUID}}
    flow: xtls-rprx-vision
    network: tcp
    udp: true
    tls: true
    servername: {{REALITY_TARGET}}
    client-fingerprint: chrome
    reality-opts:
      public-key: {{REALITY_PUBLIC_KEY}}
      short-id: {{SHORT_ID}}

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "vps-vpn-vless"
      - "DIRECT"
YAML
    client_yaml_footer
}

# Client template with both nodes. "Proxy" is a plain select group so the user
# switches protocols by hand (zero background probing).
client_template_hy2() {
    client_yaml_header
    cat <<'YAML'
proxies:
  - name: "vps-vpn-vless"
    type: vless
    server: {{PUBLIC_IP}}
    port: {{PORT}}
    uuid: {{UUID}}
    flow: xtls-rprx-vision
    network: tcp
    udp: true
    tls: true
    servername: {{REALITY_TARGET}}
    client-fingerprint: chrome
    reality-opts:
      public-key: {{REALITY_PUBLIC_KEY}}
      short-id: {{SHORT_ID}}
  - name: "vps-vpn-hy2"
    type: hysteria2
    server: {{PUBLIC_IP}}
    port: {{HY2_PORT}}
YAML
    if [[ "${ENABLE_PORT_HOP:-1}" -eq 1 && -n "${HY2_HOP_RANGE:-}" ]]; then
        cat <<'YAML'
    ports: {{HY2_HOP_RANGE}}
    hop-interval: 30
YAML
    fi
    cat <<'YAML'
    password: {{HY2_PASSWORD}}
    sni: {{REALITY_TARGET}}
YAML
    if [[ -n "${HY2_CERT_FINGERPRINT:-}" ]]; then
        cat <<'YAML'
    skip-cert-verify: false
    fingerprint: {{HY2_CERT_FINGERPRINT}}
YAML
    else
        cat <<'YAML'
    skip-cert-verify: true
YAML
    fi
    cat <<'YAML'
    alpn:
      - h3
    udp: true
YAML
    if [[ -n "${HY2_UP:-}" && -n "${HY2_DOWN:-}" ]]; then
        cat <<'YAML'
    up: {{HY2_UP}} Mbps
    down: {{HY2_DOWN}} Mbps
YAML
    fi
    cat <<'YAML'

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "vps-vpn-hy2"
      - "vps-vpn-vless"
      - "DIRECT"
YAML
    client_yaml_footer
}

# Render the Mihomo YAML from the embedded template and, when running as a
# non-root user, drop a 0600 copy into that user's home. Never emits the
# REALITY private key. Prints the main config path.
generate_client_config() {
    local main_config="$STATE_DIR/client.yaml"
    local user_config="$USER_HOME/vps-vpn/client.yaml"
    local target="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    local hop_range="${HY2_HOP_RANGE:-$DEFAULT_HOP_RANGE}"

    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.client.yaml.XXXXXX")
    if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
        client_template_hy2 | sed \
            -e "s|{{PUBLIC_IP}}|$PUBLIC_IP|g" \
            -e "s|{{PORT}}|$PORT|g" \
            -e "s|{{UUID}}|$UUID|g" \
            -e "s|{{REALITY_TARGET}}|$target|g" \
            -e "s|{{REALITY_PUBLIC_KEY}}|$REALITY_PUBLIC_KEY|g" \
            -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
            -e "s|{{HY2_PORT}}|$HY2_PORT|g" \
            -e "s|{{HY2_HOP_RANGE}}|$hop_range|g" \
            -e "s|{{HY2_PASSWORD}}|$HY2_PASSWORD|g" \
            -e "s|{{HY2_CERT_FINGERPRINT}}|${HY2_CERT_FINGERPRINT:-}|g" \
            -e "s|{{HY2_UP}}|${HY2_UP:-}|g" \
            -e "s|{{HY2_DOWN}}|${HY2_DOWN:-}|g" > "$tmp"
    else
        client_template | sed \
            -e "s|{{PUBLIC_IP}}|$PUBLIC_IP|g" \
            -e "s|{{PORT}}|$PORT|g" \
            -e "s|{{UUID}}|$UUID|g" \
            -e "s|{{REALITY_TARGET}}|$target|g" \
            -e "s|{{REALITY_PUBLIC_KEY}}|$REALITY_PUBLIC_KEY|g" \
            -e "s|{{SHORT_ID}}|$SHORT_ID|g" > "$tmp"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$main_config"
    chmod 600 "$main_config"

    if [[ "$USER_NAME" != "root" ]]; then
        mkdir -p "$USER_HOME/vps-vpn"
        # Hand the directory to the user first so `scp`/downloads work.
        chown "$USER_ID:$GROUP_ID" "$USER_HOME/vps-vpn" 2>/dev/null || true
        chmod 700 "$USER_HOME/vps-vpn"
        cp "$main_config" "$user_config"
        chown "$USER_ID:$GROUP_ID" "$user_config" 2>/dev/null || true
        chmod 600 "$user_config"
    fi

    echo "$main_config"
}

# Build standard single-node URIs for secondary clients (Shadowrocket / v2rayN / sing-box).
build_vless_uri() {
    local target="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#vps-vpn-vless\n' \
        "$UUID" "$PUBLIC_IP" "$PORT" "$target" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
}

build_hy2_uri() {
    local target="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    local query="sni=${target}&alpn=h3"
    if [[ -n "${HY2_CERT_FINGERPRINT:-}" ]]; then
        query="${query}&insecure=0&pinSHA256=${HY2_CERT_FINGERPRINT}"
    else
        query="${query}&insecure=1"
    fi
    if [[ "${ENABLE_PORT_HOP:-1}" -eq 1 && -n "${HY2_HOP_RANGE:-}" ]]; then
        query="${query}&mport=${HY2_HOP_RANGE}"
    fi
    printf 'hysteria2://%s@%s:%s/?%s#vps-vpn-hy2\n' \
        "$HY2_PASSWORD" "$PUBLIC_IP" "$HY2_PORT" "$query"
}

# Validate the client YAML with real Mihomo when available (`mihomo -t -f`).
# Without Mihomo, fall back to a structural check and say so explicitly.
validate_client_config() {
    local config_file="$1"
    if command -v mihomo >/dev/null 2>&1; then
        if mihomo -t -f "$config_file" >/dev/null 2>&1; then
            return 0
        fi
        echo "错误：客户端配置校验失败（mihomo -t）" >&2
        return 1
    fi

    # Fallback: required keys/fields present and no leftover placeholders.
    local missing=()
    grep -q '^proxies:' "$config_file" || missing+=("proxies")
    grep -q 'type: vless' "$config_file" || missing+=("type: vless")
    grep -q 'reality-opts:' "$config_file" || missing+=("reality-opts")
    grep -q 'public-key:' "$config_file" || missing+=("public-key")
    grep -q 'enhanced-mode: fake-ip' "$config_file" || missing+=("fake-ip")
    if [[ ${#missing[@]} -gt 0 ]] || grep -q '{{' "$config_file"; then
        echo "错误：客户端配置校验失败（缺少: ${missing[*]:-占位符未替换}）" >&2
        return 1
    fi
    echo "提示：未找到 mihomo，已用结构检查替代真实兼容性校验" >&2
    return 0
}

# --- install & service ------------------------------------------------------

# Pinned version. Must be >= 1.11: sing-box 1.10.0 has a REALITY defect that
# rejects every client with "REALITY: processed invalid connection".
readonly SING_BOX_VERSION="1.14.4"
readonly SING_BOX_MIN_VERSION="1.11.0"

# Return 0 if semantic version $1 >= $2 (numeric major.minor.patch).
version_ge() {
    local a="$1" b="$2"
    local a1 a2 a3 b1 b2 b3
    IFS='.' read -r a1 a2 a3 <<<"${a%%-*}"
    IFS='.' read -r b1 b2 b3 <<<"${b%%-*}"
    a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
    b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
    if (( a1 != b1 )); then (( a1 > b1 )); return; fi
    if (( a2 != b2 )); then (( a2 > b2 )); return; fi
    (( a3 >= b3 ))
}

# Extract installed sing-box semver (e.g. "1.14.4"); prints nothing if unknown.
get_sing_box_version() {
    local line
    line=$(sing-box version 2>/dev/null | head -n 1 || true)
    if [[ "$line" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

install_sing_box() {
    if command -v sing-box >/dev/null 2>&1; then
        local current_ver
        current_ver=$(get_sing_box_version)
        if [[ "${UPGRADE_SING_BOX:-0}" -eq 0 ]]; then
            if [[ -z "$current_ver" ]] || version_ge "$current_ver" "$SING_BOX_MIN_VERSION"; then
                echo "sing-box${current_ver:+ v$current_ver} 已安装，跳过安装步骤" >&2
                return 0
            fi
            echo "检测到 sing-box v$current_ver 低于最低安全版本 $SING_BOX_MIN_VERSION（存在 REALITY 缺陷），将升级到 v$SING_BOX_VERSION..." >&2
        else
            echo "按 --upgrade 要求安装/升级 sing-box v$SING_BOX_VERSION..." >&2
        fi
    else
        echo "安装 sing-box v$SING_BOX_VERSION..." >&2
    fi
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SING_BOX_VERSION"
}

# Apply proper ownership & mode on /etc/sing-box/config.json so the unprivileged
# sing-box 1.12+ service user can always read it cleanly.
fix_config_permissions() {
    local path="$1"
    local svc="${SING_BOX_SERVICE_USER:-sing-box}"
    if id "$svc" >/dev/null 2>&1; then
        chown "$svc:$svc" "$path" 2>/dev/null || true
    fi
    chmod 600 "$path"
}

# Install the vetted config and (re)start the systemd unit.
setup_service() {
    local config_file="$1"
    mkdir -p "$(dirname "$SING_BOX_CONFIG_PATH")"
    cp "$config_file" "$SING_BOX_CONFIG_PATH"
    fix_config_permissions "$SING_BOX_CONFIG_PATH"

    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true

    if ! systemctl is-active --quiet sing-box; then
        echo "错误：sing-box 服务启动失败" >&2
        systemctl status sing-box --no-pager >&2 || true
        return 1
    fi
    echo "sing-box 服务已启动" >&2
}

# Refuse to proceed when another process already owns the port.
# Args: $1=port, $2=proto ("tcp" default, or "udp").
check_port_available() {
    local port="$1"
    local proto="${2:-tcp}"
    local holders=""

    if command -v lsof >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            holders=$(lsof -nP -iUDP:"$port" 2>/dev/null | tail -n +2 || true)
        else
            holders=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)
        fi
        if [[ -n "$holders" ]]; then
            if grep -qi 'sing-box' <<<"$holders"; then
                return 0
            fi
            if [[ "$proto" == "udp" ]]; then
                echo "错误：UDP 端口 $port 已被占用，请用 --hy2-port 指定其他端口" >&2
            else
                echo "错误：TCP 端口 $port 已被占用，请用 --port 指定其他端口" >&2
            fi
            echo "$holders" >&2
            return 1
        fi
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        local ss_flag="-ltn"
        [[ "$proto" == "udp" ]] && ss_flag="-lun"
        if ss "$ss_flag" 2>/dev/null | grep -q ":$port "; then
            echo "警告：检测到 ${proto^^} 端口 $port 已被监听，若非本项目服务请更换端口" >&2
        fi
    fi
    return 0
}

# Generate a uniform random integer in [lo, hi] (not limited to Bash $RANDOM's 32767).
rand_int_range() {
    local lo="$1" hi="$2" span hex val
    span=$(( hi - lo + 1 ))
    if command -v shuf >/dev/null 2>&1; then
        shuf -i "${lo}-${hi}" -n 1
        return 0
    fi
    hex=$(openssl rand -hex 4 2>/dev/null || printf '%04x%04x' "$RANDOM" "$RANDOM")
    val=$(( 16#${hex:0:8} ))
    echo $(( lo + (val % span) ))
}

# Pick a random high UDP port for Hysteria 2.
# Uses 30001-60000 by default (safe high ports, never <1024 privileged ports,
# never 8443 QUIC-alt, never collides with VLESS $PORT or default hop range).
choose_hy2_port() {
    local lo="${HY2_PORT_MIN:-30001}"
    local hi="${HY2_PORT_MAX:-60000}"
    local attempts="${HY2_PORT_ATTEMPTS:-50}"
    local hop_lo=0 hop_hi=0
    if [[ "${ENABLE_PORT_HOP:-1}" -eq 1 && "${HY2_HOP_RANGE:-}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        hop_lo=$((10#${BASH_REMATCH[1]}))
        hop_hi=$((10#${BASH_REMATCH[2]}))
    fi
    local i candidate
    for (( i = 0; i < attempts; i++ )); do
        candidate=$(rand_int_range "$lo" "$hi")
        [[ "$candidate" -eq 8443 ]] && continue
        [[ -n "${PORT:-}" && "$candidate" -eq "$PORT" ]] && continue
        if (( hop_lo > 0 && candidate >= hop_lo && candidate <= hop_hi )); then
            continue
        fi
        if command -v ss >/dev/null 2>&1 && ss -lntu 2>/dev/null | grep -q ":$candidate "; then
            continue
        fi
        echo "$candidate"
        return 0
    done
    echo 39443
}

# Best-effort listening-port check. Args: $1=port, $2=proto ("tcp" default, or "udp").
check_listening() {
    local port="$1"
    local proto="${2:-tcp}"
    local attempts="${LISTEN_CHECK_ATTEMPTS:-30}"
    local delay="${LISTEN_CHECK_DELAY:-0.2}"
    local ss_flag="-ltn" label="TCP"
    if [[ "$proto" == "udp" ]]; then
        ss_flag="-lun"
        label="UDP"
    fi
    local i
    command -v ss >/dev/null 2>&1 || return 0
    for (( i = 0; i < attempts; i++ )); do
        if ss "$ss_flag" 2>/dev/null | grep -q ":$port "; then
            echo "$label $port 正在监听" >&2
            return 0
        fi
        if (( i + 1 < attempts )); then
            sleep "$delay" 2>/dev/null || true
        fi
    done
    echo "警告：未检测到 $label $port 监听，请检查服务日志" >&2
    return 0
}

# --- Hysteria 2 port hopping (isolated nftables / iptables + systemd) -------

setup_port_hopping() {
    local udp_port="$1"
    local hop_range="$2"

    if [[ "${ENABLE_HY2:-1}" -ne 1 || "${ENABLE_PORT_HOP:-1}" -ne 1 || -z "$hop_range" ]]; then
        disable_port_hopping
        return 0
    fi

    local hop_colon="${hop_range//-/:}"
    local helper_dir
    helper_dir=$(dirname "$PORT_HOP_HELPER_PATH")
    mkdir -p "$helper_dir" "$(dirname "$PORT_HOP_NFT_PATH")"

    cat > "$PORT_HOP_NFT_PATH" <<NFT
table inet vps_vpn_hop {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport $hop_range redirect to :$udp_port
    }
}
NFT
    chmod 644 "$PORT_HOP_NFT_PATH"

    cat > "$PORT_HOP_HELPER_PATH" <<HELPER
#!/usr/bin/env bash
set -euo pipefail
NFT_FILE="$PORT_HOP_NFT_PATH"
HOP_COLON="$hop_colon"
UDP_PORT="$udp_port"

clear_rules() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet vps_vpn_hop 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -t nat -C PREROUTING -j VPS_VPN_HOP 2>/dev/null; do
            iptables -t nat -D PREROUTING -j VPS_VPN_HOP 2>/dev/null || true
        done
        iptables -t nat -F VPS_VPN_HOP 2>/dev/null || true
        iptables -t nat -X VPS_VPN_HOP 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -t nat -C PREROUTING -j VPS_VPN_HOP 2>/dev/null; do
            ip6tables -t nat -D PREROUTING -j VPS_VPN_HOP 2>/dev/null || true
        done
        ip6tables -t nat -F VPS_VPN_HOP 2>/dev/null || true
        ip6tables -t nat -X VPS_VPN_HOP 2>/dev/null || true
    fi
}

apply_rules() {
    clear_rules
    if command -v nft >/dev/null 2>&1 && [[ -f "\$NFT_FILE" ]]; then
        if nft -f "\$NFT_FILE" 2>/dev/null; then
            return 0
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -N VPS_VPN_HOP 2>/dev/null || iptables -t nat -F VPS_VPN_HOP
        iptables -t nat -A VPS_VPN_HOP -p udp --dport "\$HOP_COLON" -j REDIRECT --to-ports "\$UDP_PORT"
        iptables -t nat -A PREROUTING -j VPS_VPN_HOP
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -N VPS_VPN_HOP 2>/dev/null || ip6tables -t nat -F VPS_VPN_HOP || true
            ip6tables -t nat -A VPS_VPN_HOP -p udp --dport "\$HOP_COLON" -j REDIRECT --to-ports "\$UDP_PORT" 2>/dev/null || true
            ip6tables -t nat -A PREROUTING -j VPS_VPN_HOP 2>/dev/null || true
        fi
        return 0
    fi
    echo "警告：未找到 nft 或 iptables，跳过端口跳跃 NAT 规则" >&2
    return 0
}

case "\${1:-apply}" in
    apply) apply_rules ;;
    clear) clear_rules ;;
    *) echo "Usage: \$0 {apply|clear}" >&2; exit 2 ;;
esac
HELPER
    chmod 755 "$PORT_HOP_HELPER_PATH"

    if mkdir -p "$SYSTEMD_UNIT_DIR" 2>/dev/null; then
        cat > "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service" <<UNIT
[Unit]
Description=vps-vpn Hysteria 2 UDP Port Hopping NAT rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$PORT_HOP_HELPER_PATH apply
ExecStop=$PORT_HOP_HELPER_PATH clear

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service"
    fi

    if [[ "${PORT_HOP_APPLY:-1}" -eq 1 ]]; then
        "$PORT_HOP_HELPER_PATH" apply || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable vps-vpn-port-hop.service >/dev/null 2>&1 || true
            systemctl restart vps-vpn-port-hop.service >/dev/null 2>&1 || true
        fi
        echo "已启用 Hysteria 2 端口跳跃: UDP $hop_range -> $udp_port" >&2
    fi
}

disable_port_hopping() {
    if [[ "${PORT_HOP_APPLY:-1}" -eq 1 ]]; then
        if [[ -x "$PORT_HOP_HELPER_PATH" ]]; then
            "$PORT_HOP_HELPER_PATH" clear >/dev/null 2>&1 || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now vps-vpn-port-hop.service >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service" "$PORT_HOP_HELPER_PATH" "$PORT_HOP_NFT_PATH" 2>/dev/null || true
    if [[ "${PORT_HOP_APPLY:-1}" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

# --- backup & restore -------------------------------------------------------

# Snapshot the config into STATE_DIR/backups (0700 dir, 0600 file).
backup_config() {
    local config_file="$1"
    local backup_dir="$STATE_DIR/backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file
    backup_file="$backup_dir/config.json.$timestamp"

    [[ -f "$config_file" ]] || return 0

    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    cp "$config_file" "$backup_file"
    chmod 600 "$backup_file"
    echo "配置已备份到: $backup_file" >&2
}

# Restore the most recent snapshot onto config_file. Non-zero when none exists.
restore_config() {
    local config_file="$1"
    local backup_dir="$STATE_DIR/backups"
    local latest_backup="" f
    for f in "$backup_dir"/config.json.*; do
        [[ -f "$f" ]] || continue
        [[ "$f" > "$latest_backup" ]] && latest_backup="$f"
    done

    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$config_file"
        fix_config_permissions "$config_file"
        echo "已从备份恢复配置: $latest_backup" >&2
        return 0
    fi
    echo "错误：找不到可用的备份文件" >&2
    return 1
}

# --- installed management CLI (/usr/local/bin/vps-vpn) ----------------------

install_cli() {
    local cli_dir
    cli_dir=$(dirname "$CLI_INSTALL_PATH")
    mkdir -p "$cli_dir"

    local tmp
    tmp=$(mktemp "$cli_dir/.vps-vpn.XXXXXX")
    cat > "$tmp" <<'CLIEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/root/vps-vpn}"
SING_BOX_CONFIG_PATH="${SING_BOX_CONFIG_PATH:-/etc/sing-box/config.json}"
SING_BOX_CERT_DIR="${SING_BOX_CERT_DIR:-/etc/sing-box}"
PORT_HOP_HELPER_PATH="${PORT_HOP_HELPER_PATH:-/usr/local/libexec/vps-vpn-port-hop}"
PORT_HOP_NFT_PATH="${PORT_HOP_NFT_PATH:-/etc/vps-vpn/port-hop.nft}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"
MODULES_DIR="${MODULES_DIR:-/etc/modules-load.d}"
REPO_INSTALL_URL="https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh"

require_root() {
    if [[ "${EUID_OVERRIDE:-$EUID}" -ne 0 ]]; then
        echo "错误：请使用 sudo vps-vpn 运行此命令" >&2
        exit 1
    fi
}

load_vps_state() {
    local f="$STATE_DIR/state.env" k v
    if [[ ! -f "$f" ]]; then
        echo "错误：未找到状态文件 $f（请先运行安装脚本）" >&2
        exit 1
    fi
    UUID=""; REALITY_PUBLIC_KEY=""; SHORT_ID=""
    PORT=""; PUBLIC_IP=""; REALITY_TARGET="www.microsoft.com"
    HY2_PORT=""; HY2_PASSWORD=""; ENABLE_PORT_HOP="0"; HY2_HOP_RANGE=""
    HY2_UP=""; HY2_DOWN=""; HY2_CERT_FINGERPRINT=""
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        case "$k" in
            UUID) UUID="$v" ;;
            REALITY_PUBLIC_KEY) REALITY_PUBLIC_KEY="$v" ;;
            SHORT_ID) SHORT_ID="$v" ;;
            PORT) PORT="$v" ;;
            PUBLIC_IP) PUBLIC_IP="$v" ;;
            REALITY_TARGET) [[ -n "$v" ]] && REALITY_TARGET="$v" ;;
            HY2_PORT) HY2_PORT="$v" ;;
            HY2_PASSWORD) HY2_PASSWORD="$v" ;;
            ENABLE_PORT_HOP) ENABLE_PORT_HOP="$v" ;;
            HY2_HOP_RANGE) HY2_HOP_RANGE="$v" ;;
            HY2_UP) HY2_UP="$v" ;;
            HY2_DOWN) HY2_DOWN="$v" ;;
            HY2_CERT_FINGERPRINT) HY2_CERT_FINGERPRINT="$v" ;;
            *) ;;
        esac
    done < "$f"
}

print_qr() {
    local text="$1"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 -m 1 "$text"
    else
        echo "（提示：未安装 qrencode，无法渲染终端二维码；可直接复制上方链接）"
    fi
}

cmd_status() {
    load_vps_state
    echo "========================================"
    echo "vps-vpn 运行状态"
    echo "========================================"
    echo "sing-box 版本: $(sing-box version 2>/dev/null | head -n 1 || echo '未安装')"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "服务状态: active (running)"
    else
        echo "服务状态: inactive / stopped"
    fi
    echo "公网 IP: ${PUBLIC_IP:-未知}"
    echo "VLESS + REALITY: TCP ${PORT} (SNI: ${REALITY_TARGET})"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
        echo "  └─ TCP ${PORT} 监听正常"
    else
        echo "  └─ 警告：TCP ${PORT} 未检测到监听"
    fi
    if [[ -n "$HY2_PORT" ]]; then
        echo "Hysteria 2: UDP ${HY2_PORT}"
        if command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | grep -q ":${HY2_PORT} "; then
            echo "  └─ UDP ${HY2_PORT} 监听正常"
        else
            echo "  └─ 警告：UDP ${HY2_PORT} 未检测到监听"
        fi
        if [[ "$ENABLE_PORT_HOP" == "1" && -n "$HY2_HOP_RANGE" ]]; then
            local hop_state="未加载"
            if command -v nft >/dev/null 2>&1 && nft list table inet vps_vpn_hop >/dev/null 2>&1; then
                hop_state="nftables 已生效"
            elif command -v iptables >/dev/null 2>&1 && iptables -t nat -S VPS_VPN_HOP >/dev/null 2>&1; then
                hop_state="iptables 已生效"
            fi
            echo "  └─ 端口跳跃: UDP ${HY2_HOP_RANGE} -> ${HY2_PORT} (${hop_state})"
        fi
    fi
    echo "TCP 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "UDP rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo '未知')"
    if command -v ufw >/dev/null 2>&1; then
        echo "UFW 状态: $(ufw status 2>/dev/null | head -n 1 || echo '未知')"
    fi
    echo "========================================"
}

cmd_info() {
    load_vps_state
    local user_name="${SUDO_USER:-root}"
    local yaml_path="$STATE_DIR/client.yaml"
    local scp_path="$yaml_path"
    if [[ "$user_name" != "root" && -f "/home/$user_name/vps-vpn/client.yaml" ]]; then
        scp_path="/home/$user_name/vps-vpn/client.yaml"
    fi
    cat <<EOF
========================================
vps-vpn 连接信息
========================================
公网地址: $PUBLIC_IP
VLESS + REALITY: TCP $PORT (SNI: $REALITY_TARGET)
EOF
    if [[ -n "$HY2_PORT" ]]; then
        echo "Hysteria 2: UDP $HY2_PORT"
        if [[ "$ENABLE_PORT_HOP" == "1" && -n "$HY2_HOP_RANGE" ]]; then
            echo "Hysteria 2 端口跳跃: UDP $HY2_HOP_RANGE -> $HY2_PORT"
        fi
        if [[ -n "$HY2_CERT_FINGERPRINT" ]]; then
            echo "HY2 证书 SHA-256 指纹: $HY2_CERT_FINGERPRINT"
        fi
        if [[ -n "$HY2_UP" && -n "$HY2_DOWN" ]]; then
            echo "HY2 拥塞控制: Brutal (up ${HY2_UP} Mbps / down ${HY2_DOWN} Mbps)"
        else
            echo "HY2 拥塞控制: QUIC BBR 自适应"
        fi
    fi
    cat <<EOF
客户端配置: $yaml_path

电脑 scp 拉取：
  scp ${user_name}@${PUBLIC_IP}:${scp_path} .

手机/电脑临时扫码导入：
  sudo vps-vpn share

单节点链接与二维码：
  sudo vps-vpn uri
========================================
EOF
}

cmd_uri() {
    load_vps_state
    local vless_uri hy2_uri
    vless_uri="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#vps-vpn-vless"
    echo "=== VLESS + REALITY 节点链接 ==="
    echo "$vless_uri"
    echo ""
    print_qr "$vless_uri"

    if [[ -n "$HY2_PORT" && -n "$HY2_PASSWORD" ]]; then
        local q="sni=${REALITY_TARGET}&alpn=h3"
        if [[ -n "$HY2_CERT_FINGERPRINT" ]]; then
            q="${q}&insecure=0&pinSHA256=${HY2_CERT_FINGERPRINT}"
        else
            q="${q}&insecure=1"
        fi
        if [[ "$ENABLE_PORT_HOP" == "1" && -n "$HY2_HOP_RANGE" ]]; then
            q="${q}&mport=${HY2_HOP_RANGE}"
        fi
        hy2_uri="hysteria2://${HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}/?${q}#vps-vpn-hy2"
        echo ""
        echo "=== Hysteria 2 节点链接 ==="
        echo "$hy2_uri"
        echo ""
        print_qr "$hy2_uri"
    fi
    echo ""
    echo "提示：Clash Verge / CMFA 推荐导入完整 client.yaml（含白名单分流与 Fake-IP DNS）；以上单节点链接适合 Shadowrocket / v2rayN / sing-box。"
}

cmd_share() {
    load_vps_state
    local share_port="" timeout_sec=300 max_downloads=2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) share_port="${2:?--port 需要端口号}"; shift 2 ;;
            --timeout) timeout_sec="${2:?--timeout 需要秒数}"; shift 2 ;;
            --downloads) max_downloads="${2:?--downloads 需要次数}"; shift 2 ;;
            *) echo "未知参数: $1" >&2; exit 2 ;;
        esac
    done

    local yaml="$STATE_DIR/client.yaml"
    if [[ ! -f "$yaml" ]]; then
        echo "错误：未找到客户端配置 $yaml" >&2
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "错误：临时分享依赖 python3，请先安装 python3 或改用 scp 下载 $yaml" >&2
        exit 1
    fi

    if [[ -z "$share_port" ]]; then
        share_port=$(shuf -i 40000-60000 -n 1 2>/dev/null || echo $((40000 + RANDOM % 20000)))
    fi
    local token
    token=$(openssl rand -hex 32)
    local url="http://${PUBLIC_IP}:${share_port}/${token}/vps-vpn.yaml"
    local clash_url="clash://install-config?url=${url}&name=vps-vpn"

    local ufw_opened=0
    cleanup_share() {
        if [[ "$ufw_opened" -eq 1 ]]; then
            ufw delete allow "${share_port}/tcp" >/dev/null 2>&1 || true
            echo "已关闭临时 UFW 端口 ${share_port}/tcp" >&2
        fi
    }
    trap cleanup_share EXIT INT TERM

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${share_port}/tcp" comment 'vps-vpn-share' >/dev/null 2>&1 || true
        ufw_opened=1
    fi

    cat <<EOF
========================================
一次性临时配置分享已启动
========================================
下载地址（CMFA / Clash Verge「从 URL 导入」粘贴此链接）:
  $url

Clash 快捷导入链接:
  $clash_url

有效时长: ${timeout_sec} 秒 | 最大下载次数: ${max_downloads} 次（达限或按 Ctrl+C 自动关闭）
注意：若使用 AWS / Lightsail / GCP 等带独立云安全组的 VPS，需临时放行 TCP ${share_port}，或直接改用 scp 拉取后在电脑局域网传给手机。

手机 CMFA 扫码导入（可直接扫描下方二维码）：
EOF
    print_qr "$url"
    echo ""
    echo "等待客户端拉取中..."

    python3 - "$yaml" "$share_port" "$token" "$timeout_sec" "$max_downloads" <<'PYEOF'
import http.server
import socketserver
import sys
import threading

yaml_path, port_s, token, timeout_s, max_dl_s = sys.argv[1:6]
port = int(port_s)
timeout = int(timeout_s)
max_dl = int(max_dl_s)
expected_path = f"/{token}/vps-vpn.yaml"
with open(yaml_path, "rb") as fh:
    payload = fh.read()

state = {"count": 0}

class OneShotHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path != expected_path:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Content-Disposition", 'attachment; filename="vps-vpn.yaml"')
        self.send_header("Profile-Title", "vps-vpn")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        state["count"] += 1
        print(f"已成功下载 ({state['count']}/{max_dl}) 来自 {self.client_address[0]}", flush=True)
        if state["count"] >= max_dl:
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt, *args):
        pass

class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

httpd = ReuseTCPServer(("0.0.0.0", port), OneShotHandler)
timer = threading.Timer(timeout, httpd.shutdown)
timer.daemon = True
timer.start()
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    timer.cancel()
    httpd.server_close()
print("临时分享服务已关闭。", flush=True)
PYEOF
}

cmd_update() {
    local target_ver="${1:-}"
    echo "正在更新 sing-box${target_ver:+ 到 v$target_ver}..."
    if [[ -n "$target_ver" ]]; then
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$target_ver"
    else
        curl -fsSL https://sing-box.app/install.sh | bash
    fi
    if sing-box check -c "$SING_BOX_CONFIG_PATH"; then
        systemctl restart sing-box
        systemctl is-active --quiet sing-box && echo "sing-box 更新并重启成功: $(sing-box version | head -n 1)"
    else
        echo "错误：新版本 sing-box 校验现有配置失败，请检查日志" >&2
        exit 1
    fi
}

cmd_rotate() {
    load_vps_state
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$STATE_DIR/backups"
    chmod 700 "$STATE_DIR/backups"
    cp "$STATE_DIR/state.env" "$STATE_DIR/backups/state.env.$ts"
    chmod 600 "$STATE_DIR/backups/state.env.$ts"
    echo "已备份旧凭据到 $STATE_DIR/backups/state.env.$ts"

    # Preserve ports, SNI, hop settings, and Brutal limits while rotating secrets.
    local args=(--port "$PORT" --sni "$REALITY_TARGET")
    [[ -n "$PUBLIC_IP" ]] && args+=(--ip "$PUBLIC_IP")
    if [[ -n "$HY2_PORT" ]]; then
        args+=(--hy2-port "$HY2_PORT")
        if [[ "$ENABLE_PORT_HOP" == "1" && -n "$HY2_HOP_RANGE" ]]; then
            args+=(--hop-range "$HY2_HOP_RANGE")
        else
            args+=(--no-port-hop)
        fi
        if [[ -n "$HY2_UP" && -n "$HY2_DOWN" ]]; then
            args+=(--hy2-up "$HY2_UP" --hy2-down "$HY2_DOWN")
        fi
    else
        args+=(--no-hy2)
    fi

    rm -f "$STATE_DIR/state.env" "$SING_BOX_CERT_DIR/hy2.crt" "$SING_BOX_CERT_DIR/hy2.key"
    curl -fsSL "$REPO_INSTALL_URL" | bash -s -- "${args[@]}"
    echo "凭据已轮换完成，请重新将新的 client.yaml 导入电脑 Clash Verge 与手机 CMFA。"
}

cmd_uninstall() {
    local yes=0
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1
    if [[ "$yes" -ne 1 ]]; then
        read -r -p "确认彻底卸载 vps-vpn（将停止服务、清理配置、NAT 规则与凭据）？[y/N]: " ans
        [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo "已取消卸载"; return 0; }
    fi

    systemctl disable --now sing-box >/dev/null 2>&1 || true
    if [[ -x "$PORT_HOP_HELPER_PATH" ]]; then
        "$PORT_HOP_HELPER_PATH" clear >/dev/null 2>&1 || true
    fi
    systemctl disable --now vps-vpn-port-hop.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service" "$PORT_HOP_HELPER_PATH" "$PORT_HOP_NFT_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true

    # Remove only UFW rules explicitly tagged with comment 'vps-vpn'.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        local nums
        nums=$(ufw status numbered 2>/dev/null | awk '/vps-vpn/ { gsub(/[\[\]]/, "", $1); print $1 }' | sort -rn || true)
        local n
        for n in $nums; do
            [[ "$n" =~ ^[0-9]+$ ]] && ufw --force delete "$n" >/dev/null 2>&1 || true
        done
    fi

    rm -f "$SING_BOX_CONFIG_PATH" "$SING_BOX_CERT_DIR/hy2.crt" "$SING_BOX_CERT_DIR/hy2.key"
    rm -f "$SYSCTL_DIR/99-bbr.conf" "$SYSCTL_DIR/99-vps-vpn-udp.conf" "$MODULES_DIR/bbr.conf"
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local uhome
        uhome=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
        [[ -n "$uhome" ]] && rm -rf "$uhome/vps-vpn"
    fi
    rm -rf "$STATE_DIR"
    echo "vps-vpn 已清理完毕（sing-box 软件包本体如需卸载可执行: sudo apt remove sing-box）。"
    rm -f "$0"
}

show_menu() {
    while true; do
        cat <<'MENU'

========================================
        vps-vpn 管理菜单
========================================
  1. 查看运行状态（服务/端口/跳跃/BBR/缓冲）
  2. 查看连接信息与 scp 下载命令
  3. 一次性临时分享配置（URL + 二维码）
  4. 显示单节点链接与二维码（vless:// / hysteria2://）
  5. 查看实时服务日志（Ctrl+C 退出）
  6. 重启 sing-box 服务
  7. 更新 sing-box 内核
  8. 轮换所有凭据与证书
  9. 卸载 vps-vpn
  0. 退出
========================================
MENU
        read -r -p "请输入选项 [0-9]: " choice
        case "$choice" in
            1) cmd_status ;;
            2) cmd_info ;;
            3) cmd_share ;;
            4) cmd_uri ;;
            5) journalctl -u sing-box -f ;;
            6) systemctl restart sing-box && echo "已重启 sing-box" ;;
            7) cmd_update ;;
            8) cmd_rotate ;;
            9) cmd_uninstall; break ;;
            0) break ;;
            *) echo "无效选项，请重新输入" ;;
        esac
    done
}

cli_help() {
    cat <<'HELP'
Usage: sudo vps-vpn [COMMAND]

不带参数运行将打开交互式中文管理菜单。

Commands:
  status      查看服务、端口监听、端口跳跃、BBR 与 UDP 缓冲状态
  info        显示公网地址、端口、指纹及 scp 下载命令
  share       启动一次性临时分享服务（随机 Token URL + 终端二维码，自动销毁）
  uri         输出标准 vless:// 与 hysteria2:// 链接及终端二维码
  update      更新 sing-box 内核并校验重启
  rotate      备份并轮换全部凭据与证书
  uninstall   清理服务、配置、NAT/UFW 规则与状态文件
  help        显示此帮助信息
HELP
}

main_cli() {
    case "${1:-}" in
        help|-h|--help) cli_help; exit 0 ;;
        status)    require_root; cmd_status ;;
        info)      require_root; cmd_info ;;
        share)     require_root; shift; cmd_share "$@" ;;
        uri)       require_root; cmd_uri ;;
        update)    require_root; shift; cmd_update "$@" ;;
        rotate)    require_root; cmd_rotate ;;
        uninstall) require_root; shift; cmd_uninstall "$@" ;;
        "")
            require_root
            if [[ -t 0 ]]; then
                show_menu
            else
                cli_help
            fi
            ;;
        *)
            echo "未知子命令: $1" >&2
            cli_help >&2
            exit 2
            ;;
    esac
}

main_cli "$@"
CLIEOF
    chmod 755 "$tmp"
    mv -f "$tmp" "$CLI_INSTALL_PATH"
    chmod 755 "$CLI_INSTALL_PATH"
    echo "已安装管理命令: $CLI_INSTALL_PATH（运行 sudo vps-vpn 打开菜单）" >&2
}

# --- summary ----------------------------------------------------------------

# Human-readable completion summary. Emits paths, endpoint, download command
# and management commands — never UUID, keys or full YAML.
print_summary() {
    local client_config="$1"
    local target="${REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
    local hy2_port=""
    if [[ "${ENABLE_HY2:-1}" -eq 1 && -n "${HY2_PORT:-}" ]]; then
        hy2_port="$HY2_PORT"
    fi
    local hop_range=""
    if [[ -n "$hy2_port" && "${ENABLE_PORT_HOP:-1}" -eq 1 && -n "${HY2_HOP_RANGE:-}" ]]; then
        hop_range="$HY2_HOP_RANGE"
    fi

    cat <<EOF

========================================
安装完成！
========================================

公网地址: $PUBLIC_IP
VLESS + REALITY 端口: $PORT/TCP（SNI: $target）
EOF

    if [[ -n "$hy2_port" ]]; then
        echo "Hysteria 2 端口: $hy2_port/UDP"
        if [[ -n "$hop_range" ]]; then
            echo "Hysteria 2 端口跳跃: $hop_range/UDP -> $hy2_port/UDP（每 30 秒平滑跳换）"
        fi
        if [[ -n "${HY2_UP:-}" && -n "${HY2_DOWN:-}" ]]; then
            echo "Hysteria 2 拥塞控制: Brutal（up ${HY2_UP} Mbps / down ${HY2_DOWN} Mbps）"
        else
            echo "Hysteria 2 拥塞控制: QUIC BBR 自适应（PC/手机通用免调参）"
        fi
    fi

    local sg_udp=""
    if [[ -n "$hop_range" ]]; then
        sg_udp=" 与 UDP $hop_range（若不开跳跃则放行 UDP $hy2_port）"
    elif [[ -n "$hy2_port" ]]; then
        sg_udp=" 与 UDP $hy2_port"
    fi

    cat <<EOF
服务端配置: $SING_BOX_CONFIG_PATH
客户端配置: $client_config

环境：系统依赖与内核网络优化已就绪；本机防火墙状态见上一步输出（云安全组仍需你在控制台放行 TCP ${PORT}${sg_udp}）。

方式一：电脑 scp 下载客户端配置：
EOF

    if [[ "$USER_NAME" != "root" ]]; then
        cat <<EOF
  scp $USER_NAME@$PUBLIC_IP:/home/$USER_NAME/vps-vpn/client.yaml .

或使用 SSH 密钥：
  scp -i /path/to/key.pem $USER_NAME@$PUBLIC_IP:/home/$USER_NAME/vps-vpn/client.yaml .
EOF
    else
        cat <<EOF
  scp root@$PUBLIC_IP:/root/vps-vpn/client.yaml .

或使用 SSH 密钥：
  scp -i /path/to/key.pem root@$PUBLIC_IP:/root/vps-vpn/client.yaml .
EOF
    fi

    cat <<EOF

方式二：手机 CMFA / 电脑 Clash Verge 临时扫码一键导入（自动销毁）：
  sudo vps-vpn share

方式三：输出单节点 vless:// / hysteria2:// 链接与二维码：
  sudo vps-vpn uri

客户端规则说明：
  - 白名单分流（MetaCubeX .mrs）：国内域名/IP 与局域网直连，海外与 AI 流量全走代理
  - Fake-IP 分流 DNS：国内走阿里/腾讯 DoH 直连解析，海外不落地直连解析
EOF

    if [[ -n "$hy2_port" ]]; then
        cat <<EOF
  - Proxy 策略组含两个节点，纯手动切换且重启记忆选择：
      * vps-vpn-hy2     Hysteria 2，UDP${hop_range:+ 端口跳跃 $hop_range}，晚高峰/丢包环境更快
      * vps-vpn-vless   VLESS + REALITY，TCP $PORT，UDP 被封锁时切到它
EOF
    fi

    if [[ "${IP_DETECT_SINGLE:-0}" -eq 1 ]]; then
        echo "提示：公网 IP 仅由单个服务确认，请自行核验为 $PUBLIC_IP"
    fi

    cat <<EOF

装后管理命令：
  交互菜单: sudo vps-vpn
  运行状态: sudo vps-vpn status
  分享配置: sudo vps-vpn share
  查看日志: sudo journalctl -u sing-box -f
  卸载清理: sudo vps-vpn uninstall

========================================
EOF
}

# --- environment bootstrap --------------------------------------------------

# Validate the host: supported Ubuntu (>=22.04) or Debian (>=11), amd64/arm64, root.
check_environment() {
    local os_file="${OS_RELEASE_FILE:-/etc/os-release}"
    local arch="${ARCH_OVERRIDE:-$(uname -m)}"
    local uid="${EUID_OVERRIDE:-$EUID}"
    local id="" ver=""

    if [[ ! -r "$os_file" ]]; then
        echo "错误：无法读取 $os_file，无法确认操作系统" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    id=$(. "$os_file" 2>/dev/null; echo "${ID:-}")
    # shellcheck source=/dev/null
    ver=$(. "$os_file" 2>/dev/null; echo "${VERSION_ID:-}")

    case "$id" in
        ubuntu)
            case "$ver" in
                22.04|24.04) ;;  # verified
                *)
                    if [[ "$ver" =~ ^([0-9]{2})\.([0-9]{2})$ ]] && (( 10#${BASH_REMATCH[1]} >= 22 )); then
                        echo "提示：Ubuntu $ver 未在本项目实测验证，将按兼容模式继续安装" >&2
                    else
                        echo "错误：仅支持 Ubuntu 22.04 及以上或 Debian 11 及以上（检测到 Ubuntu $ver）" >&2
                        return 1
                    fi
                    ;;
            esac
            ;;
        debian)
            local deb_major="${ver%%.*}"
            case "$deb_major" in
                11|12|13) ;;  # verified/supported Debian releases
                *)
                    if [[ "$deb_major" =~ ^[0-9]+$ ]] && (( 10#$deb_major >= 11 )); then
                        echo "提示：Debian $ver 未在本项目实测验证，将按兼容模式继续安装" >&2
                    else
                        echo "错误：仅支持 Ubuntu 22.04 及以上或 Debian 11 及以上（检测到 Debian $ver）" >&2
                        return 1
                    fi
                    ;;
            esac
            ;;
        *)
            echo "错误：仅支持 Ubuntu / Debian（检测到 ID=$id）" >&2
            return 1
            ;;
    esac

    case "$arch" in
        x86_64|amd64|aarch64|arm64) ;;
        *) echo "错误：仅支持 amd64/arm64 架构（检测到 $arch）" >&2; return 1 ;;
    esac
    if [[ "$uid" -ne 0 ]]; then
        echo "错误：需要 root 权限运行（请使用 sudo）" >&2
        return 1
    fi
}

# Ensure required system tools exist, installing missing ones via apt when
# possible. Idempotent; SKIP_DEPS=1 short-circuits. qrencode is optional
# (best-effort so a missing package never blocks installation).
ensure_dependencies() {
    local need=() tool pkg
    local -A pkg_of=(
        [curl]=curl [openssl]=openssl [sed]=sed [awk]=gawk
        [ip]=iproute2 [ss]=iproute2 [getent]=libc-bin [lsof]=lsof
    )

    for tool in curl openssl sed awk ip ss getent lsof; do
        command -v "$tool" >/dev/null 2>&1 || need+=("$tool")
    done

    local need_qr=0
    command -v qrencode >/dev/null 2>&1 || need_qr=1

    if [[ ${#need[@]} -eq 0 && $need_qr -eq 0 ]]; then
        return 0
    fi

    if [[ "${SKIP_DEPS:-0}" -eq 1 ]]; then
        if [[ ${#need[@]} -gt 0 ]]; then
            echo "提示：--skip-deps 已启用，跳过自动安装；缺失命令: ${need[*]}" >&2
        fi
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        if [[ ${#need[@]} -eq 0 ]]; then
            return 0
        fi
        echo "错误：缺少命令: ${need[*]}，且未找到 apt-get，请手动安装后重试或使用 --skip-deps" >&2
        return 1
    fi

    local -a pkgs=()
    for tool in "${need[@]}"; do
        pkg="${pkg_of[$tool]:-$tool}"
        [[ -n "$pkg" ]] || continue
        case " ${pkgs[*]-} " in *" $pkg "*) ;; *) pkgs+=("$pkg") ;; esac
    done

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo "安装缺失依赖: ${pkgs[*]}..." >&2
        DEBIAN_FRONTEND=noninteractive apt-get update -y >&2 || true
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >&2; then
            echo "错误：依赖安装失败，请检查网络或源后重试" >&2
            return 1
        fi
        echo "依赖已安装完成" >&2
    fi

    if [[ $need_qr -eq 1 ]]; then
        if [[ ${#pkgs[@]} -eq 0 ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y >&2 || true
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >&2 || \
            echo "提示：可选依赖 qrencode 安装失败，终端二维码将降级为纯链接输出" >&2
    fi
}

# If ufw is installed AND active, allow the given ports with 'vps-vpn' comments
# so uninstall can remove ONLY our own rules. Never disables ufw or touches SSH.
configure_firewall() {
    local tcp_port="$1"
    local udp_port="${2:-}"
    local hop_range="${3:-}"
    command -v ufw >/dev/null 2>&1 || return 0
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$tcp_port"/tcp comment 'vps-vpn' >/dev/null 2>&1 || true
        echo "已放行本机防火墙 TCP 端口 $tcp_port" >&2
        if [[ -n "$udp_port" ]]; then
            ufw allow "$udp_port"/udp comment 'vps-vpn' >/dev/null 2>&1 || true
            echo "已放行本机防火墙 UDP 端口 $udp_port" >&2
        fi
        if [[ -n "$hop_range" ]]; then
            local ufw_range="${hop_range//-/:}"
            ufw allow "$ufw_range"/udp comment 'vps-vpn' >/dev/null 2>&1 || true
            echo "已放行本机防火墙 UDP 端口跳跃范围 $ufw_range" >&2
        fi
    fi
    return 0
}

# Enable BBR for the TCP leg (VLESS). Advisory only.
enable_bbr() {
    local sysctl_dir="${SYSCTL_DIR:-/etc/sysctl.d}"
    local modules_dir="${MODULES_DIR:-/etc/modules-load.d}"
    local apply="${SYSCTL_APPLY:-1}"
    local available

    modprobe tcp_bbr >/dev/null 2>&1 || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")

    if [[ "$available" != *bbr* ]]; then
        echo "提示：当前内核不支持 BBR（可用: ${available:-未知}），跳过 TCP 加速" >&2
        return 0
    fi

    if mkdir -p "$modules_dir" 2>/dev/null; then
        printf 'tcp_bbr\n' > "$modules_dir/bbr.conf" 2>/dev/null || true
    fi

    if mkdir -p "$sysctl_dir" 2>/dev/null; then
        {
            printf 'net.core.default_qdisc = fq\n'
            printf 'net.ipv4.tcp_congestion_control = bbr\n'
        } > "$sysctl_dir/99-bbr.conf" 2>/dev/null || true
    fi

    if [[ "$apply" -eq 1 ]]; then
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")" == "bbr" ]]; then
            echo "已启用 BBR 拥塞控制（改善 VLESS 在丢包链路上的吞吐）" >&2
        else
            echo "提示：BBR 配置已写入，但当前未生效（重启后生效）" >&2
        fi
    fi
    return 0
}

# Raise Linux UDP socket buffers to 16MB for Hysteria 2 / QUIC throughput.
# Default ~212KB buffers bottleneck high-BDP QUIC links. Advisory only.
configure_udp_buffers() {
    local sysctl_dir="${SYSCTL_DIR:-/etc/sysctl.d}"
    local apply="${SYSCTL_APPLY:-1}"

    if mkdir -p "$sysctl_dir" 2>/dev/null; then
        {
            printf 'net.core.rmem_max = 16777216\n'
            printf 'net.core.wmem_max = 16777216\n'
            printf 'net.core.rmem_default = 262144\n'
            printf 'net.core.wmem_default = 262144\n'
        } > "$sysctl_dir/99-vps-vpn-udp.conf" 2>/dev/null || true
    fi

    if [[ "$apply" -eq 1 ]]; then
        sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
        sysctl -w net.core.rmem_default=262144 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_default=262144 >/dev/null 2>&1 || true
        echo "已优化 Linux UDP 内核缓冲区至 16MB（提升 Hysteria 2 吞吐）" >&2
    fi
    return 0
}

main() {
    parse_args "$@"
    check_environment
    ensure_dependencies
    detect_user_context

    if [[ -n "$IP" ]]; then
        PUBLIC_IP="$IP"
    elif ! detect_public_ip; then
        echo "错误：无法自动检测公网 IP，请使用 --ip 参数手动指定" >&2
        exit 1
    fi

    echo "使用公网 IP: $PUBLIC_IP"

    if [[ "${IPTEST:-0}" -eq 1 ]]; then
        return 0  # test seam: stop after env+deps+user+IP detection
    fi

    # sing-box must exist before we can generate keys or check configs.
    install_sing_box

    # Load or generate credentials BEFORE port checks so re-runs check the
    # persisted custom ports rather than defaults.
    generate_credentials
    check_port_available "$PORT" tcp

    if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
        generate_hy2_cert || exit 1
        save_state
        check_port_available "$HY2_PORT" udp
    fi

    local new_config
    new_config=$(generate_server_config)

    # Back up the currently installed config before touching it.
    backup_config "$SING_BOX_CONFIG_PATH"

    if ! validate_config "$new_config"; then
        echo "配置校验失败，保持现状不做改动" >&2
        exit 1
    fi

    if ! setup_service "$new_config"; then
        echo "服务启动失败，尝试恢复备份..." >&2
        if restore_config "$SING_BOX_CONFIG_PATH"; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
        exit 1
    fi

    check_listening "$PORT" tcp
    if [[ "${ENABLE_HY2:-1}" -eq 1 ]]; then
        check_listening "$HY2_PORT" udp
        if [[ "${ENABLE_PORT_HOP:-1}" -eq 1 ]]; then
            setup_port_hopping "$HY2_PORT" "$HY2_HOP_RANGE"
        else
            disable_port_hopping
        fi
    else
        disable_port_hopping
    fi

    enable_bbr
    configure_udp_buffers
    configure_firewall "$PORT" \
        "$([[ "${ENABLE_HY2:-1}" -eq 1 ]] && echo "$HY2_PORT")" \
        "$([[ "${ENABLE_HY2:-1}" -eq 1 && "${ENABLE_PORT_HOP:-1}" -eq 1 ]] && echo "$HY2_HOP_RANGE")"

    local client_config
    client_config=$(generate_client_config)

    if ! validate_client_config "$client_config"; then
        echo "警告：客户端配置未通过校验，请检查" >&2
    fi

    install_cli
    print_summary "$client_config"
}

# Only run when executed directly. When piped to `bash` BASH_SOURCE[0] is empty
# and $0 is "bash", so guard on emptiness too (otherwise `curl | bash` no-ops).
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
