#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="vps-vpn"
# shellcheck disable=SC2034  # consumed by state/config functions added in later tasks
STATE_DIR="/root/vps-vpn"
DEFAULT_PORT=443

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --ip IP       手动指定公网 IPv4 地址（默认自动检测）
  --port PORT   指定 VLESS 端口（默认 443）
  --help        显示此帮助信息
EOF
    exit "${1:-0}"
}

parse_args() {
    IP=""
    PORT="$DEFAULT_PORT"
    PORT_EXPLICIT=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)
                [[ $# -ge 2 ]] || { echo "错误：--ip 需要一个参数" >&2; usage 2; }
                IP="$2"
                shift 2
                ;;
            --port)
                [[ $# -ge 2 ]] || { echo "错误：--port 需要一个参数" >&2; usage 2; }
                PORT="$2"
                PORT_EXPLICIT=1
                shift 2
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

# Detect the public IPv4 address. Prints the chosen address on stdout.
# Sets IP_DETECT_SINGLE=1 when only one service answered (caller should
# surface a verification hint). Returns non-zero when undetectable/ambiguous.
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
            echo "${uniq[0]}"
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

# --- credentials & state ----------------------------------------------------

readonly UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly HEX_RE='^[0-9a-fA-F]+$'

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

# Parse `sing-box generate reality-keypair` output (accepts "PrivateKey: x",
# "Private key: x", or bare base64 lines) into REALITY_PRIVATE_KEY/PUBLIC_KEY.
parse_keypair() {
    local out="$1" priv="" pub="" line
    while IFS= read -r line; do
        case "$line" in
            *[Pp]rivate*"key"*) priv="${line##*: }"; priv="${priv// /}" ;;
            *[Pp]ublic*"key"*)  pub="${line##*: }";  pub="${pub// /}" ;;
        esac
    done <<<"$out"
    if [[ -z "$priv" || -z "$pub" ]]; then
        local -a lines=()
        mapfile -t lines <<<"$out"
        priv="${lines[0]:-}"; pub="${lines[1]:-}"
        priv="${priv// /}"; pub="${pub// /}"
    fi
    [[ -n "$priv" && -n "$pub" ]] || return 1
    REALITY_PRIVATE_KEY="$priv"
    REALITY_PUBLIC_KEY="$pub"
}

generate_credentials() {
    if [[ -f "$STATE_DIR/state.env" ]]; then
        echo "加载已有凭据..." >&2
        load_state || return 1
        # Reuse the stored port unless the operator explicitly overrode it.
        if [[ "${PORT_EXPLICIT:-0}" -eq 0 && -n "${STATE_PORT:-}" ]]; then
            PORT="$STATE_PORT"
        fi
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
    save_state
}

# Read state.env without sourcing it. Rejects bad value formats; ignores any
# key outside the known set. Exposes STATE_PORT for the reuse rule.
load_state() {
    local file="$STATE_DIR/state.env" key value n=0
    STATE_PORT=""

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            UUID)
                [[ "$value" =~ $UUID_RE ]] || { echo "错误：state.env 中 UUID 格式无效" >&2; return 1; }
                UUID="$value" ;;
            REALITY_PRIVATE_KEY) REALITY_PRIVATE_KEY="$value" ;;
            REALITY_PUBLIC_KEY)  REALITY_PUBLIC_KEY="$value" ;;
            SHORT_ID)
                [[ "$value" =~ $HEX_RE ]] || { echo "错误：state.env 中 SHORT_ID 格式无效" >&2; return 1; }
                SHORT_ID="$value" ;;
            PORT)
                [[ "$value" =~ ^[0-9]+$ ]] || { echo "错误：state.env 中 PORT 格式无效" >&2; return 1; }
                STATE_PORT="$value" ;;
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
        printf 'REALITY_PUBLIC_KEY=%s\n' "$REALITY_PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$SHORT_ID"
        printf 'PORT=%s\n' "$PORT"
        printf 'PUBLIC_IP=%s\n' "${PUBLIC_IP:-}"
    } > "$tmp"
    mv -f "$tmp" "$STATE_DIR/state.env"
    chmod 600 "$STATE_DIR/state.env"
}

main() {
    parse_args "$@"
    detect_user_context

    if [[ -n "$IP" ]]; then
        PUBLIC_IP="$IP"
    elif ! PUBLIC_IP=$(detect_public_ip); then
        echo "错误：无法自动检测公网 IP，请使用 --ip 参数手动指定" >&2
        exit 1
    fi

    echo "使用公网 IP: $PUBLIC_IP"

    generate_credentials
}

# Only run when executed directly; sourcing the file (tests) must not install.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
