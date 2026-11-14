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

main() {
    parse_args "$@"
    echo "IP: $IP, PORT: $PORT"
}

main "$@"
