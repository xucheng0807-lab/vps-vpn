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

# --- server config ----------------------------------------------------------

readonly REALITY_TARGET="www.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Render the server JSON from the template. Dynamic values are already format-
# validated upstream (UUID, hex short id, numeric port); they contain no chars
# that sed's replacement or JSON would misinterpret. Prints the file path.
generate_server_config() {
    local config_file="$STATE_DIR/sing-box-server.json"
    local template="$TEMPLATE_DIR/server.json.template"

    [[ -f "$template" ]] || { echo "错误：缺少模板 $template" >&2; return 1; }

    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.server.json.XXXXXX")
    sed -e "s/{{PORT}}/$PORT/g" \
        -e "s/{{UUID}}/$UUID/g" \
        -e "s/{{REALITY_TARGET}}/$REALITY_TARGET/g" \
        -e "s/{{REALITY_PRIVATE_KEY}}/$REALITY_PRIVATE_KEY/g" \
        -e "s/{{SHORT_ID}}/$SHORT_ID/g" \
        "$template" > "$tmp"
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

# Render the Mihomo YAML from the template and, when running as a non-root
# user, drop a 0600 copy into that user's home. Never emits the REALITY
# private key. Prints the main config path.
generate_client_config() {
    local template="$TEMPLATE_DIR/client.yaml.template"
    local main_config="$STATE_DIR/client.yaml"
    local user_config="$USER_HOME/vps-vpn/client.yaml"

    [[ -f "$template" ]] || { echo "错误：缺少模板 $template" >&2; return 1; }

    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.client.yaml.XXXXXX")
    sed -e "s/{{PUBLIC_IP}}/$PUBLIC_IP/g" \
        -e "s/{{PORT}}/$PORT/g" \
        -e "s/{{UUID}}/$UUID/g" \
        -e "s/{{REALITY_TARGET}}/$REALITY_TARGET/g" \
        -e "s/{{REALITY_PUBLIC_KEY}}/$REALITY_PUBLIC_KEY/g" \
        -e "s/{{SHORT_ID}}/$SHORT_ID/g" \
        "$template" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$main_config"
    chmod 600 "$main_config"

    if [[ "$USER_NAME" != "root" ]]; then
        mkdir -p "$USER_HOME/vps-vpn"
        chmod 700 "$USER_HOME/vps-vpn"
        cp "$main_config" "$user_config"
        chown "$USER_ID:$GROUP_ID" "$user_config" 2>/dev/null || true
        chmod 600 "$user_config"
    fi

    echo "$main_config"
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
    if [[ ${#missing[@]} -gt 0 ]] || grep -q '{{' "$config_file"; then
        echo "错误：客户端配置校验失败（缺少: ${missing[*]:-占位符未替换}）" >&2
        return 1
    fi
    echo "提示：未找到 mihomo，已用结构检查替代真实兼容性校验" >&2
    return 0
}

# --- install & service ------------------------------------------------------

readonly SING_BOX_VERSION="1.10.0"
# System config path; overridable for tests, real path used on a VPS.
SING_BOX_CONFIG_PATH="${SING_BOX_CONFIG_PATH:-/etc/sing-box/config.json}"

install_sing_box() {
    if command -v sing-box >/dev/null 2>&1; then
        echo "sing-box 已安装，跳过安装步骤" >&2
        return 0
    fi
    echo "安装 sing-box v$SING_BOX_VERSION..." >&2
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SING_BOX_VERSION"
}

# Install the vetted config and (re)start the systemd unit. Non-zero when the
# unit does not become active; prints status for diagnosis.
setup_service() {
    local config_file="$1"
    mkdir -p "$(dirname "$SING_BOX_CONFIG_PATH")"
    cp "$config_file" "$SING_BOX_CONFIG_PATH"
    chmod 600 "$SING_BOX_CONFIG_PATH"

    systemctl enable --now sing-box >/dev/null 2>&1 || true

    if ! systemctl is-active --quiet sing-box; then
        echo "错误：sing-box 服务启动失败" >&2
        systemctl status sing-box --no-pager >&2 || true
        return 1
    fi
    echo "sing-box 服务已启动" >&2
}

# Best-effort listening-port check. Advisory only: proves the unit bound the
# port locally, never claims public reachability.
check_listening() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    if ss -ltn 2>/dev/null | grep -q ":$port "; then
        echo "TCP $port 正在监听" >&2
    else
        echo "警告：未检测到 TCP $port 监听，请检查服务日志" >&2
    fi
    return 0
}

# --- backup & restore -------------------------------------------------------

# Snapshot the config into STATE_DIR/backups (0700 dir, 0600 file). No-op when
# the file does not exist (first install). Prints the backup path when made.
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
    # Names carry a sortable timestamp, so the greatest name is the newest.
    for f in "$backup_dir"/config.json.*; do
        [[ -f "$f" ]] || continue
        [[ "$f" > "$latest_backup" ]] && latest_backup="$f"
    done

    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$config_file"
        chmod 600 "$config_file"
        echo "已从备份恢复配置: $latest_backup" >&2
        return 0
    fi
    echo "错误：找不到可用的备份文件" >&2
    return 1
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

    if [[ "${IPTEST:-0}" -eq 1 ]]; then
        return 0  # test seam: stop after IP+user+credentials
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

    check_listening "$PORT"
}

# Only run when executed directly; sourcing the file (tests) must not install.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
