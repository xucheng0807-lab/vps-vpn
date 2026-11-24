#!/usr/bin/env bats
#
# Tests for install.sh.
#
# Strategy: install.sh is sourced so its functions can be unit tested in
# isolation with test doubles for curl / id / sing-box / systemctl / openssl.
# Nothing here touches a real VPS, real sing-box, real systemd, or host paths.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PROJECT_ROOT
    TEST_SANDBOX="$(mktemp -d)"
    export TEST_SANDBOX
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/install.sh"

    # Sandbox all system paths & disable live probes / live sysctl / live NAT by default.
    SING_BOX_CONFIG_PATH="$TEST_SANDBOX/etc/sing-box/config.json"
    SING_BOX_CERT_DIR="$TEST_SANDBOX/etc/sing-box"
    CLI_INSTALL_PATH="$TEST_SANDBOX/usr/local/bin/vps-vpn"
    PORT_HOP_HELPER_PATH="$TEST_SANDBOX/usr/local/libexec/vps-vpn-port-hop"
    PORT_HOP_NFT_PATH="$TEST_SANDBOX/etc/vps-vpn/port-hop.nft"
    SYSTEMD_UNIT_DIR="$TEST_SANDBOX/etc/systemd/system"
    SYSCTL_DIR="$TEST_SANDBOX/etc/sysctl.d"
    MODULES_DIR="$TEST_SANDBOX/etc/modules-load.d"
    SKIP_SNI_CHECK=1
    PORT_HOP_APPLY=0
    SYSCTL_APPLY=0
}

teardown() {
    [[ -n "${TEST_SANDBOX:-}" && -d "$TEST_SANDBOX" ]] && rm -rf "$TEST_SANDBOX"
}

# --- Task 1: argument parsing ------------------------------------------------

@test "parse --ip and --port" {
    parse_args --ip 1.2.3.4 --port 8080
    [ "$IP" = "1.2.3.4" ]
    [ "$PORT" = "8080" ]
}

@test "default port is 443" {
    parse_args --ip 1.2.3.4
    [ "$IP" = "1.2.3.4" ]
    [ "$PORT" = "443" ]
}

@test "unknown argument prints usage and exits non-zero" {
    run parse_args --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知参数"* ]]
}

@test "--help prints usage and exits zero" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "--ip without value exits non-zero" {
    run parse_args --ip
    [ "$status" -ne 0 ]
}

@test "v2 args: --sni validates domain" {
    parse_args --sni www.apple.com
    [ "$REALITY_TARGET" = "www.apple.com" ]
    [ "$SNI_EXPLICIT" -eq 1 ]

    run parse_args --sni "not a domain"
    [ "$status" -ne 0 ]
    run parse_args --sni "localhost"
    [ "$status" -ne 0 ]
}

@test "v2 args: --hop-range and --no-port-hop validate cleanly" {
    parse_args --hop-range 25000-35000
    [ "$HY2_HOP_RANGE" = "25000-35000" ]
    [ "$ENABLE_PORT_HOP" -eq 1 ]
    [ "$HY2_HOP_RANGE_EXPLICIT" -eq 1 ]

    parse_args --no-port-hop
    [ "$ENABLE_PORT_HOP" -eq 0 ]
    [ "$PORT_HOP_EXPLICIT" -eq 1 ]

    run parse_args --hop-range 80-443
    [ "$status" -ne 0 ]
    run parse_args --hop-range 30000-20000
    [ "$status" -ne 0 ]
    run parse_args --hop-range bogus
    [ "$status" -ne 0 ]
}

@test "v2 args: --hy2-up and --hy2-down must be paired and numeric" {
    parse_args --hy2-up 50 --hy2-down 200
    [ "$HY2_UP" = "50" ]
    [ "$HY2_DOWN" = "200" ]
    [ "$HY2_BW_EXPLICIT" -eq 1 ]

    run parse_args --hy2-up 50
    [ "$status" -ne 0 ]
    run parse_args --hy2-down 200
    [ "$status" -ne 0 ]
    run parse_args --hy2-up 0 --hy2-down 200
    [ "$status" -ne 0 ]
}

@test "v2 args: --upgrade sets UPGRADE_SING_BOX=1" {
    parse_args --upgrade
    [ "$UPGRADE_SING_BOX" -eq 1 ]
}

# --- Task 2: public IPv4 detection ------------------------------------------

_fake_curl() {
    curl() {
        local url="" arg
        for arg in "$@"; do url="$arg"; done
        case "$url" in
            *api.ipify.org*)    printf '%s' "${FAKE_CURL_IPIFY:-}" ;;
            *icanhazip.com*)    printf '%s' "${FAKE_CURL_ICANHAZ:-}" ;;
            *ifconfig.me*)      printf '%s' "${FAKE_CURL_IFCONFIG:-}" ;;
        esac
        return 0
    }
    export -f curl
}

@test "detect_public_ip accepts two matching valid results" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ="1.2.3.4"; FAKE_CURL_IFCONFIG=""
    detect_public_ip
    [ $? -eq 0 ]
    [ "$PUBLIC_IP" = "1.2.3.4" ]
}

@test "detect_public_ip accepts single valid result with warning" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    detect_public_ip
    [ $? -eq 0 ]
    [ "$PUBLIC_IP" = "1.2.3.4" ]
}

@test "detect_public_ip rejects private address" {
    _fake_curl
    FAKE_CURL_IPIFY="192.168.1.1"; FAKE_CURL_ICANHAZ="192.168.1.1"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "${PUBLIC_IP:-}" ]
}

@test "detect_public_ip rejects reserved address" {
    _fake_curl
    FAKE_CURL_IPIFY="127.0.0.1"; FAKE_CURL_ICANHAZ="169.254.1.1"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "${PUBLIC_IP:-}" ]
}

@test "detect_public_ip rejects non-IPv4 text" {
    _fake_curl
    FAKE_CURL_IPIFY="not-an-ip"; FAKE_CURL_ICANHAZ="1.2.3.4.5"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "${PUBLIC_IP:-}" ]
}

@test "detect_public_ip fails on conflicting results" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ="5.6.7.8"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "${PUBLIC_IP:-}" ]
}

@test "detect_public_ip fails when all services fail" {
    _fake_curl
    FAKE_CURL_IPIFY=""; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "${PUBLIC_IP:-}" ]
}

# --- Task 3: user context detection -----------------------------------------

@test "detect_user_context resolves SUDO_USER via getent" {
    getent() { echo "ubuntu:x:1000:1000::/home/ubuntu:/bin/bash"; }
    SUDO_USER=ubuntu
    detect_user_context
    [ "$USER_NAME" = "ubuntu" ]
    [ "$USER_HOME" = "/home/ubuntu" ]
    [ "$USER_ID" = "1000" ]
    [ "$GROUP_ID" = "1000" ]
}

@test "detect_user_context falls back to root with no SUDO_USER" {
    unset SUDO_USER
    detect_user_context
    [ "$USER_NAME" = "root" ]
    [ "$USER_HOME" = "/root" ]
    [ "$USER_ID" = "0" ]
    [ "$GROUP_ID" = "0" ]
}

@test "detect_user_context treats SUDO_USER=root as root" {
    SUDO_USER=root
    detect_user_context
    [ "$USER_NAME" = "root" ]
    [ "$USER_HOME" = "/root" ]
}

@test "detect_user_context fails when user cannot be resolved" {
    getent() { return 2; }
    SUDO_USER=ghost
    run detect_user_context
    [ "$status" -ne 0 ]
    [[ "$output" == *"无法解析用户"* ]]
}

# --- Task 4: credential generation and state management ---------------------

_stub_crypto_tools() {
    sing-box() {
        if [[ "$1" == "generate" && "$2" == "reality-keypair" ]]; then
            echo "PrivateKey: test-private-key-AAAA"
            echo "PublicKey: test-public-key-BBBB"
            return 0
        fi
        return 0
    }
    openssl() {
        case "$*" in
            *"-hex 4"*) echo "deadbeef" ;;
            *) echo "deadbeefdeadbeefdeadbeefdeadbeef" ;;
        esac
    }
    export -f sing-box openssl
}

_fs_supports_perms() {
    local f; f=$(mktemp)
    chmod 600 "$f" 2>/dev/null
    local m; m=$(stat -c '%a' "$f" 2>/dev/null || echo x)
    rm -f "$f"
    [[ "$m" == "600" ]]
}

@test "generate_credentials creates a new state file with secure perms" {
    STATE_DIR="$(mktemp -d)/state"
    PORT=443; PUBLIC_IP=1.2.3.4
    _stub_crypto_tools
    CHMOD_LOG="$(mktemp)"
    export CHMOD_LOG
    chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null || true; }
    export -f chmod
    generate_credentials >/dev/null
    [ -f "$STATE_DIR/state.env" ]
    grep -q '^UUID=' "$STATE_DIR/state.env"
    grep -q '^REALITY_PRIVATE_KEY=test-private-key-AAAA' "$STATE_DIR/state.env"
    grep -q '^REALITY_PUBLIC_KEY=test-public-key-BBBB' "$STATE_DIR/state.env"
    grep -q '^SHORT_ID=' "$STATE_DIR/state.env"
    grep -q '^REALITY_TARGET=' "$STATE_DIR/state.env"
    grep -q "700 $STATE_DIR" "$CHMOD_LOG"
    grep -q "600 $STATE_DIR/state.env" "$CHMOD_LOG"
    if _fs_supports_perms; then
        [ "$(stat -c '%a' "$STATE_DIR/state.env")" = "600" ]
        [ "$(stat -c '%a' "$STATE_DIR")" = "700" ]
    fi
}

@test "generate_credentials reuses existing state without new keys" {
    STATE_DIR="$(mktemp -d)/state"
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=keep-private-key
REALITY_PUBLIC_KEY=keep-public-key
SHORT_ID=abcd1234
PORT=8443
PUBLIC_IP=9.9.9.9
REALITY_TARGET=www.apple.com
HY2_PORT=34567
HY2_PASSWORD=keephy2password123456
EOF
    chmod 600 "$STATE_DIR/state.env"
    sing-box() { return 99; }   # must NOT be called on reuse
    export -f sing-box
    generate_credentials >/dev/null
    [ "$UUID" = "11111111-2222-3333-4444-555555555555" ]
    [ "$REALITY_PRIVATE_KEY" = "keep-private-key" ]
    [ "$PORT" = "8443" ]
    [ "$REALITY_TARGET" = "www.apple.com" ]
    [ "$HY2_PORT" = "34567" ]
}

@test "bugfix 1: re-run with explicit --hy2-port overrides and persists new HY2_PORT" {
    STATE_DIR="$(mktemp -d)/state"
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=pk
REALITY_PUBLIC_KEY=pub
SHORT_ID=abcd1234
PORT=443
PUBLIC_IP=9.9.9.9
REALITY_TARGET=learn.microsoft.com
HY2_PORT=34567
HY2_PASSWORD=keephy2password123456
EOF
    chmod 600 "$STATE_DIR/state.env"
    parse_args --hy2-port 45678
    PUBLIC_IP=9.9.9.9
    generate_credentials >/dev/null
    [ "$HY2_PORT" = "45678" ]
    grep -q '^HY2_PORT=45678$' "$STATE_DIR/state.env"
}

@test "load_state rejects malformed UUID" {
    STATE_DIR="$(mktemp -d)/state"; mkdir -p "$STATE_DIR"
    printf 'UUID=not-a-uuid\nREALITY_PRIVATE_KEY=x\nSHORT_ID=\n' > "$STATE_DIR/state.env"
    run load_state
    [ "$status" -ne 0 ]
    [[ "$output" == *"格式无效"* ]]
}

@test "load_state rejects unknown keys silently" {
    STATE_DIR="$(mktemp -d)/state"; mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=pk
SHORT_ID=abcd1234
EVIL=$(touch /tmp/pwned)
EOF
    load_state
    [ "$UUID" = "11111111-2222-3333-4444-555555555555" ]
    [ ! -f /tmp/pwned ]
}

# --- Task 5: server configuration generation --------------------------------

_json_ok() { node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1"; }

@test "generate_server_config substitutes all placeholders" {
    STATE_DIR="$(mktemp -d)"
    PORT=443; UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="priv-key-XYZ"; SHORT_ID="abcd1234"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_server_config >/dev/null
    local f="$STATE_DIR/sing-box-server.json"
    [ -f "$f" ]
    run _json_ok "$f"
    [ "$status" -eq 0 ]
    ! grep -q '{{' "$f"
    grep -q '"private_key": "priv-key-XYZ"' "$f"
    grep -q '"short_id": \["abcd1234"\]' "$f"
    grep -q '"uuid": "11111111-2222-3333-4444-555555555555"' "$f"
    grep -q '"listen_port": 443' "$f"
    grep -q '"flow": "xtls-rprx-vision"' "$f"
}

@test "generate_server_config uses REALITY_TARGET and blocks private/IMDS outbound" {
    STATE_DIR="$(mktemp -d)"
    PORT=8443; UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="k"; SHORT_ID="abcd1234"
    REALITY_TARGET="www.apple.com"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_server_config >/dev/null
    local f="$STATE_DIR/sing-box-server.json"
    run _json_ok "$f"
    [ "$status" -eq 0 ]
    grep -q '"server": "www.apple.com"' "$f"
    grep -q '"server_port": 443' "$f"
    grep -q '"server_name": "www.apple.com"' "$f"
    grep -q '"ip_is_private": true' "$f"
    grep -q '"169.254.0.0/16"' "$f"
    grep -q '"strategy": "prefer_ipv4"' "$f"
}

@test "generate_server_config writes 0600" {
    STATE_DIR="$(mktemp -d)"
    PORT=443; UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="k"; SHORT_ID="abcd1234"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    CHMOD_LOG="$(mktemp)"; export CHMOD_LOG
    chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null || true; }
    export -f chmod
    generate_server_config >/dev/null
    grep -q "600 $STATE_DIR/sing-box-server.json" "$CHMOD_LOG"
}

@test "validate_config passes when sing-box check succeeds" {
    sing-box() { return 0; }; export -f sing-box
    local f; f=$(mktemp); echo '{}' > "$f"
    run validate_config "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "validate_config fails when sing-box check fails" {
    sing-box() { return 1; }; export -f sing-box
    local f; f=$(mktemp); echo '{}' > "$f"
    run validate_config "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"配置校验失败"* ]]
}

# --- Task 6: client YAML generation -----------------------------------------

@test "generate_client_config writes main and user copies without private key" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="ubuntu"; USER_HOME="$(mktemp -d)/home/ubuntu"; USER_ID=1000; GROUP_ID=1000
    PUBLIC_IP="1.2.3.4"; PORT=443
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub-key-ZZZ"; REALITY_PRIVATE_KEY="SECRET-PRIVATE-KEY"
    SHORT_ID="abcd1234"
    REALITY_TARGET="learn.microsoft.com"
    mkdir -p "$USER_HOME"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_client_config >/dev/null

    [ -f "$STATE_DIR/client.yaml" ]
    [ -f "$USER_HOME/vps-vpn/client.yaml" ]

    ! grep -q '{{' "$STATE_DIR/client.yaml"
    grep -q 'server: 1.2.3.4' "$STATE_DIR/client.yaml"
    grep -q 'port: 443' "$STATE_DIR/client.yaml"
    grep -q 'servername: learn.microsoft.com' "$STATE_DIR/client.yaml"
    grep -q 'public-key: pub-key-ZZZ' "$STATE_DIR/client.yaml"
    grep -q 'short-id: abcd1234' "$STATE_DIR/client.yaml"
    ! grep -q 'SECRET-PRIVATE-KEY' "$STATE_DIR/client.yaml"
    ! grep -q 'SECRET-PRIVATE-KEY' "$USER_HOME/vps-vpn/client.yaml"
    grep -q 'listen: 127.0.0.1:1053' "$STATE_DIR/client.yaml"
}

@test "v2 client config: whitelist .mrs split routing + Fake-IP DNS + store-selected" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="root"; USER_HOME="$(mktemp -d)"
    PUBLIC_IP="1.2.3.4"; PORT=443; HY2_PORT=34567; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    REALITY_TARGET="learn.microsoft.com"
    HY2_CERT_FINGERPRINT="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ENABLE_HY2=1; ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    generate_client_config >/dev/null
    local f="$STATE_DIR/client.yaml"

    grep -q '^mode: rule$' "$f"
    grep -q '^ipv6: false$' "$f"
    grep -q 'store-selected: true' "$f"
    grep -q 'store-fake-ip: true' "$f"
    grep -q 'enhanced-mode: fake-ip' "$f"
    grep -q 'respect-rules: true' "$f"
    grep -q 'https://223.5.5.5/dns-query#DIRECT' "$f"
    grep -q 'https://1.1.1.1/dns-query#Proxy' "$f"
    grep -q 'format: mrs' "$f"
    grep -q 'RULE-SET,cn_domain,DIRECT' "$f"
    grep -q 'RULE-SET,cn_ip,DIRECT,no-resolve' "$f"
    grep -q 'MATCH,Proxy' "$f"
    grep -q 'ports: 20000-30000' "$f"
    grep -q 'hop-interval: 30' "$f"
    grep -q 'skip-cert-verify: false' "$f"
    grep -q "fingerprint: $HY2_CERT_FINGERPRINT" "$f"
    # Removed in Mihomo 1.19
    ! grep -q 'global-client-fingerprint' "$f"
}

@test "generate_client_config skips user copy for root" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="root"; USER_HOME="$(mktemp -d)"
    PUBLIC_IP="1.2.3.4"; PORT=443
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_client_config >/dev/null
    [ -f "$STATE_DIR/client.yaml" ]
    [ ! -e "$USER_HOME/vps-vpn/client.yaml" ]
}

@test "generate_client_config writes 0600 on main and user copy" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="ubuntu"; USER_HOME="$(mktemp -d)"; USER_ID=1000; GROUP_ID=1000
    PUBLIC_IP="1.2.3.4"; PORT=443
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    CHMOD_LOG="$(mktemp)"; export CHMOD_LOG
    chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null || true; }
    export -f chmod
    generate_client_config >/dev/null
    grep -q "600 $STATE_DIR/client.yaml" "$CHMOD_LOG"
    grep -q "600 $USER_HOME/vps-vpn/client.yaml" "$CHMOD_LOG"
}

@test "generate_client_config makes the user-copy directory accessible to the user" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="ubuntu"; USER_HOME="$(mktemp -d)/home/ubuntu"; USER_ID=1000; GROUP_ID=1000
    PUBLIC_IP="1.2.3.4"; PORT=443
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    mkdir -p "$USER_HOME"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    CHOWN_LOG="$(mktemp)"; export CHOWN_LOG
    CHMOD_LOG="$(mktemp)"; export CHMOD_LOG
    chown() { printf '%s\n' "$*" >> "$CHOWN_LOG"; command chown "$@" 2>/dev/null || true; }
    chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null || true; }
    export -f chown chmod
    generate_client_config >/dev/null
    grep -q "1000:1000 $USER_HOME/vps-vpn\$" "$CHOWN_LOG"
    grep -q "700 $USER_HOME/vps-vpn\$" "$CHMOD_LOG"
}

@test "validate_client_config fails on malformed YAML" {
    local f; f=$(mktemp); printf 'proxies: [unclosed\n' > "$f"
    run validate_client_config "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"客户端配置校验失败"* ]]
}

# --- Task 7: sing-box install and systemd service ---------------------------

@test "setup_service copies config, chowns to sing-box user, and reports started" {
    local dir; dir=$(mktemp -d)
    SING_BOX_CONFIG_PATH="$dir/etc/sing-box/config.json"
    local cfg; cfg=$(mktemp); echo '{}' > "$cfg"
    CHOWN_LOG="$(mktemp)"; export CHOWN_LOG
    chown() { printf '%s\n' "$*" >> "$CHOWN_LOG"; command chown "$@" 2>/dev/null || true; }
    id() { [[ "$1" == "sing-box" ]] && return 0; builtin id "$@" 2>/dev/null; }
    systemctl() { return 0; }
    export -f chown id systemctl
    run setup_service "$cfg"
    [ "$status" -eq 0 ]
    [ -f "$SING_BOX_CONFIG_PATH" ]
    grep -q "sing-box:sing-box $SING_BOX_CONFIG_PATH" "$CHOWN_LOG"
    [[ "$output" == *"服务已启动"* ]]
}

@test "setup_service fails when service is not active" {
    local dir; dir=$(mktemp -d)
    SING_BOX_CONFIG_PATH="$dir/config.json"
    local cfg; cfg=$(mktemp); echo '{}' > "$cfg"
    systemctl() { if [[ "$1" == "is-active" ]]; then return 3; fi; return 0; }
    export -f systemctl
    run setup_service "$cfg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"服务启动失败"* ]]
}

@test "install_sing_box skips when installed version meets minimum (>= 1.11)" {
    sing-box() { echo "sing-box version 1.14.4"; return 0; }
    export -f sing-box
    run install_sing_box
    [ "$status" -eq 0 ]
    [[ "$output" == *"已安装"* ]]
}

@test "bugfix 5: install_sing_box upgrades when installed version is below 1.11 (e.g. 1.10.0)" {
    CAP="$(mktemp)"; export CAP
    sing-box() { echo "sing-box version 1.10.0"; return 0; }
    curl() { printf 'curl %s\n' "$*" >> "$CAP"; }
    bash() { printf 'bash %s\n' "$*" >> "$CAP"; cat >/dev/null; }
    export -f sing-box curl bash
    run install_sing_box
    [ "$status" -eq 0 ]
    [[ "$output" == *"低于最低安全版本"* ]]
    grep -q "bash .*--version $SING_BOX_VERSION" "$CAP"
}

@test "install_sing_box installs pinned version via official script" {
    CAP="$(mktemp)"; export CAP
    curl() { printf 'curl %s\n' "$*" >> "$CAP"; }
    bash() { printf 'bash %s\n' "$*" >> "$CAP"; cat >/dev/null; }
    command() { if [[ "$1" == "-v" && "$2" == "sing-box" ]]; then return 1; fi; builtin command "$@"; }
    export -f curl bash command
    run install_sing_box
    [ "$status" -eq 0 ]
    grep -q 'curl .*sing-box.app' "$CAP"
    grep -q "bash .*--version $SING_BOX_VERSION" "$CAP"
}

@test "install_sing_box upgrades even when healthy if --upgrade is set" {
    CAP="$(mktemp)"; export CAP
    UPGRADE_SING_BOX=1
    sing-box() { echo "sing-box version 1.14.4"; return 0; }
    curl() { printf 'curl %s\n' "$*" >> "$CAP"; }
    bash() { printf 'bash %s\n' "$*" >> "$CAP"; cat >/dev/null; }
    export -f sing-box curl bash
    run install_sing_box
    [ "$status" -eq 0 ]
    grep -q "bash .*--version $SING_BOX_VERSION" "$CAP"
}

# --- Task 8: backup and restore --------------------------------------------

@test "backup_config copies existing config into backups" {
    STATE_DIR="$(mktemp -d)"
    local cfg; cfg=$(mktemp); echo '{"a":1}' > "$cfg"
    backup_config "$cfg" >/dev/null
    ls "$STATE_DIR"/backups/config.json.* >/dev/null 2>&1
}

@test "backup_config is a no-op when the file is absent" {
    STATE_DIR="$(mktemp -d)"
    run backup_config "/nonexistent/config.json"
    [ "$status" -eq 0 ]
}

@test "restore_config restores the latest backup and fixes ownership" {
    STATE_DIR="$(mktemp -d)"
    local cfg; cfg=$(mktemp); echo '{"v":1}' > "$cfg"
    backup_config "$cfg" >/dev/null
    echo '{"v":2}' > "$cfg"
    CHOWN_LOG="$(mktemp)"; export CHOWN_LOG
    chown() { printf '%s\n' "$*" >> "$CHOWN_LOG"; command chown "$@" 2>/dev/null || true; }
    id() { [[ "$1" == "sing-box" ]] && return 0; builtin id "$@" 2>/dev/null; }
    export -f chown id
    restore_config "$cfg" >/dev/null
    grep -q '"v":1' "$cfg"
    grep -q "sing-box:sing-box $cfg" "$CHOWN_LOG"
}

@test "restore_config fails when no backup exists" {
    STATE_DIR="$(mktemp -d)"
    run restore_config "$STATE_DIR/missing.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"找不到可用的备份"* ]]
}

@test "main restores the previous config when the new service fails to start" {
    local root; root=$(mktemp -d)
    STATE_DIR="$root/state"; SING_BOX_CONFIG_PATH="$root/etc/sing-box/config.json"
    SING_BOX_CERT_DIR="$root/etc/sing-box"
    mkdir -p "$(dirname "$SING_BOX_CONFIG_PATH")"
    printf '{"old":true}\n' > "$SING_BOX_CONFIG_PATH"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$root/os-release"
    OS_RELEASE_FILE="$root/os-release"; ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0

    sing-box() {
        case "$1" in
            version) echo "sing-box version 1.14.4" ;;
            generate) printf 'PrivateKey: privKEY123\nPublicKey: pubKEY456\n' ;;
            check) return 0 ;;
        esac
        return 0
    }
    systemctl() { [[ "$1" == "is-active" ]] && return 3; return 0; }
    lsof() { return 1; }
    export -f sing-box systemctl lsof

    run main --ip 1.2.3.4 --skip-deps
    [ "$status" -ne 0 ]
    grep -q '"old":true' "$SING_BOX_CONFIG_PATH"
}

# --- Task 9: installation summary ------------------------------------------

@test "print_summary shows endpoint, paths, scp, and CLI commands for a sudo user" {
    USER_NAME="ubuntu"; PUBLIC_IP="1.2.3.4"; PORT=443; REALITY_TARGET="learn.microsoft.com"
    run print_summary "/root/vps-vpn/client.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"安装完成"* ]]
    [[ "$output" == *"公网地址: 1.2.3.4"* ]]
    [[ "$output" == *"scp ubuntu@1.2.3.4:/home/ubuntu/vps-vpn/client.yaml ."* ]]
    [[ "$output" == *"sudo vps-vpn share"* ]]
    [[ "$output" == *"sudo vps-vpn uri"* ]]
}

@test "print_summary uses root paths for the root user" {
    USER_NAME="root"; PUBLIC_IP="5.6.7.8"; PORT=8443
    run print_summary "/root/vps-vpn/client.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scp root@5.6.7.8:/root/vps-vpn/client.yaml ."* ]]
}

@test "print_summary never leaks the private key" {
    USER_NAME="ubuntu"; PUBLIC_IP="1.2.3.4"; PORT=443
    REALITY_PRIVATE_KEY="TOP-SECRET"
    run print_summary "/root/vps-vpn/client.yaml"
    [[ "$output" != *"TOP-SECRET"* ]]
}

@test "print_summary names Hysteria 2 port and hop range when HY2 is enabled" {
    USER_NAME="ubuntu"; PUBLIC_IP="1.2.3.4"; PORT=443
    HY2_PORT=34567; ENABLE_HY2=1; ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    run print_summary "/root/vps-vpn/client.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hysteria 2 端口: 34567/UDP"* ]]
    [[ "$output" == *"20000-30000"* ]]
}

@test "print_summary omits the Hysteria 2 port when --no-hy2 is used" {
    USER_NAME="ubuntu"; PUBLIC_IP="1.2.3.4"; PORT=443
    HY2_PORT=34567; ENABLE_HY2=0
    run print_summary "/root/vps-vpn/client.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != *"34567"* ]]
}

# ===========================================================================
# Final-review & E2E tests
# ===========================================================================

@test "C1: --help works when piped through bash" {
    run bash -c "cat '$PROJECT_ROOT/install.sh' | bash -s -- --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "C1: an unknown flag through a pipe prints usage and does not crash" {
    run bash -c "cat '$PROJECT_ROOT/install.sh' | bash -s -- --bogus"
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知参数"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "E2E: bash install.sh completes end-to-end with stub tooling and installs CLI" {
    local root; root=$(mktemp -d)
    local bin="$root/bin"; mkdir -p "$bin"
    cat > "$bin/curl" <<'S'
#!/bin/sh
case "$*" in
  *api.ipify.org*|*icanhazip.com*) printf '1.2.3.4' ;;
  *sing-box.app*) printf '#!/bin/sh\n' ;;
esac
S
    cat > "$bin/sing-box" <<'S'
#!/bin/sh
case "$1" in
  version) printf 'sing-box version 1.14.4\n' ;;
  generate) printf 'PrivateKey: PRIVKEYb64urlAAAAAAAAAAAAAAAAAAAAAAAA\nPublicKey: PUBKEYb64urlBBBBBBBBBBBBBBBBBBBBBBBBB\n' ;;
  check) exit 0 ;;
esac
exit 0
S
    cat > "$bin/systemctl" <<'S'
#!/bin/sh
exit 0
S
    cat > "$bin/lsof" <<'S'
#!/bin/sh
exit 1
S
    cat > "$bin/openssl" <<'S'
#!/bin/sh
case "$*" in
  *"-hex 16"*) printf '0123456789abcdef0123456789abcdef' ;;
  *"-hex 4"*)  printf 'deadbeef' ;;
  *x509*fingerprint*) printf 'SHA256 Fingerprint=01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF\n' ;;
  *req*)
    while [ $# -gt 0 ]; do
      if [ "$1" = "-keyout" ] || [ "$1" = "-out" ]; then
        printf 'DUMMY\n' > "$2"
        shift 2
      else
        shift
      fi
    done
    ;;
  *) printf 'deadbeef' ;;
esac
S
    chmod +x "$bin"/*
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$root/os-release"
    local real_bash; real_bash=$(command -v bash)
    run env -i PATH="$bin:/usr/bin:/bin" STATE_DIR="$root/state" \
        SING_BOX_CONFIG_PATH="$root/etc/sing-box/config.json" \
        SING_BOX_CERT_DIR="$root/etc/sing-box" \
        CLI_INSTALL_PATH="$root/usr/local/bin/vps-vpn" \
        PORT_HOP_HELPER_PATH="$root/usr/local/libexec/vps-vpn-port-hop" \
        PORT_HOP_NFT_PATH="$root/etc/vps-vpn/port-hop.nft" \
        SYSTEMD_UNIT_DIR="$root/etc/systemd/system" \
        SYSCTL_DIR="$root/etc/sysctl.d" \
        MODULES_DIR="$root/etc/modules-load.d" \
        SKIP_SNI_CHECK=1 PORT_HOP_APPLY=0 SYSCTL_APPLY=0 \
        OS_RELEASE_FILE="$root/os-release" EUID_OVERRIDE=0 ARCH_OVERRIDE=amd64 \
        "$real_bash" "$PROJECT_ROOT/install.sh" --ip 1.2.3.4 --skip-deps
    [ "$status" -eq 0 ]
    [ -f "$root/state/state.env" ]
    [ -f "$root/state/client.yaml" ]
    [ -f "$root/etc/sing-box/config.json" ]
    [ -x "$root/usr/local/bin/vps-vpn" ]
    [ -x "$root/usr/local/libexec/vps-vpn-port-hop" ]
    [ -f "$root/etc/systemd/system/vps-vpn-port-hop.service" ]
    [ -f "$root/etc/sysctl.d/99-vps-vpn-udp.conf" ]
    [[ "$output" == *"安装完成"* ]]
    run grep -l '{{' "$root/state/client.yaml" "$root/etc/sing-box/config.json"
    [ "$status" -ne 0 ]
}

# ===========================================================================
# Feature: environment bootstrap (Ubuntu 22.04+ & Debian 11+)
# ===========================================================================

_write_os_release() {  # $1=dir $2=id $3=ver
    printf 'ID=%s\nVERSION_ID="%s"\n' "$2" "$3" > "$1/os-release"
}

@test "env: accepts Ubuntu 22.04 amd64 as root" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 22.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -eq 0 ]
}

@test "env: accepts Ubuntu 24.04 arm64 as root" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 24.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=arm64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -eq 0 ]
}

@test "env: accepts Debian 11, 12, and 13" {
    local d; d=$(mktemp -d)
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    for v in 11 12 13; do
        _write_os_release "$d" debian "$v"
        OS_RELEASE_FILE="$d/os-release"
        run check_environment
        [ "$status" -eq 0 ]
    done
}

@test "env: rejects Debian 10" {
    local d; d=$(mktemp -d); _write_os_release "$d" debian 10
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
}

@test "env: rejects unsupported OS (alpine)" {
    local d; d=$(mktemp -d); _write_os_release "$d" alpine 3.19
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
    [[ "$output" == *"Ubuntu"* || "$output" == *"Debian"* ]]
}

@test "env: rejects unsupported Ubuntu version" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 20.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
    [[ "$output" == *"版本"* || "$output" == *"22.04"* ]]
}

@test "env: rejects unsupported architecture" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 22.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=i386; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
    [[ "$output" == *"架构"* || "$output" == *"amd64"* ]]
}

@test "env: rejects non-root" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 22.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=1000
    run check_environment
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
}

@test "env: accepts unknown future Ubuntu (>=22.04) with a warning" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 28.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -eq 0 ]
    [[ "$output" == *"兼容模式"* || "$output" == *"验证"* ]]
}

# --- ensure_dependencies ----------------------------------------------------

@test "deps: installs missing packages via apt-get" {
    APT_LOG="$(mktemp)"; export APT_LOG
    apt-get() { printf 'apt-get %s\n' "$*" >> "$APT_LOG"; return 0; }
    export -f apt-get
    command() {
        if [[ "$1" == "-v" ]]; then
            case "$2" in
                curl) return 1 ;;
                *) return 0 ;;
            esac
        fi
        builtin command "$@"
    }
    export -f command
    run ensure_dependencies
    [ "$status" -eq 0 ]
    grep -q 'install' "$APT_LOG"
    grep -q 'curl' "$APT_LOG"
}

@test "deps: does nothing when all tools including qrencode are present" {
    APT_LOG="$(mktemp)"; export APT_LOG
    apt-get() { printf 'apt-get %s\n' "$*" >> "$APT_LOG"; return 0; }
    command() { if [[ "$1" == "-v" ]]; then return 0; fi; builtin command "$@"; }
    export -f apt-get command
    run ensure_dependencies
    [ "$status" -eq 0 ]
    [ ! -s "$APT_LOG" ]
}

@test "deps: skips entirely when --skip-deps given" {
    APT_LOG="$(mktemp)"; export APT_LOG
    apt-get() { printf 'apt-get %s\n' "$*" >> "$APT_LOG"; return 0; }
    command() { if [[ "$1" == "-v" ]]; then return 1; fi; builtin command "$@"; }
    export -f apt-get command
    SKIP_DEPS=1
    run ensure_dependencies
    [ "$status" -eq 0 ]
    [ ! -s "$APT_LOG" ]
}

@test "deps: fails clearly when apt-get is unavailable for core tools" {
    command() {
        if [[ "$1" == "-v" && "$2" == "apt-get" ]]; then return 1; fi
        if [[ "$1" == "-v" && "$2" == "curl" ]]; then return 1; fi
        if [[ "$1" == "-v" ]]; then return 0; fi
        builtin command "$@"
    }
    export -f command
    SKIP_DEPS=0
    run ensure_dependencies
    [ "$status" -ne 0 ]
    [[ "$output" == *"apt"* || "$output" == *"手动"* ]]
}

# --- configure_firewall -----------------------------------------------------

@test "fw: allows TCP, UDP, and UDP hop range with vps-vpn comment when ufw active" {
    FW_LOG="$(mktemp)"; export FW_LOG
    command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 0; fi; builtin command "$@"; }
    ufw() {
        printf 'ufw %s\n' "$*" >> "$FW_LOG"
        if [[ "$1" == "status" ]]; then printf 'Status: active\n'; fi
        return 0
    }
    export -f command ufw
    run configure_firewall 443 34567 20000-30000
    [ "$status" -eq 0 ]
    grep -q 'allow 443/tcp comment vps-vpn' "$FW_LOG"
    grep -q 'allow 34567/udp comment vps-vpn' "$FW_LOG"
    grep -q 'allow 20000:30000/udp comment vps-vpn' "$FW_LOG"
}

@test "fw: does nothing when ufw is inactive" {
    FW_LOG="$(mktemp)"; export FW_LOG
    command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 0; fi; builtin command "$@"; }
    ufw() {
        printf 'ufw %s\n' "$*" >> "$FW_LOG"
        if [[ "$1" == "status" ]]; then printf 'Status: inactive\n'; fi
        return 0
    }
    export -f command ufw
    run configure_firewall 443
    [ "$status" -eq 0 ]
    ! grep -q 'allow 443/tcp' "$FW_LOG"
}

@test "fw: skips when ufw is not installed" {
    command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 1; fi; builtin command "$@"; }
    export -f command
    run configure_firewall 443
    [ "$status" -eq 0 ]
}

# --- version & ordering invariants -----------------------------------------

@test "version: pinned sing-box version is at least 1.11 (REALITY fix)" {
    run version_ge "$SING_BOX_VERSION" "1.11.0"
    [ "$status" -eq 0 ]
}

@test "C2: generate_server_config works from a lone copy of install.sh" {
    local dir; dir=$(mktemp -d)
    cp "$PROJECT_ROOT/install.sh" "$dir/install.sh"
    run bash -c "
        set -Eeuo pipefail
        source '$dir/install.sh'
        STATE_DIR='$dir/state'
        PORT=443; UUID='11111111-2222-3333-4444-555555555555'
        REALITY_PRIVATE_KEY='k'; SHORT_ID='abcd1234'; ENABLE_HY2=0
        f=\$(generate_server_config)
        [ -f \"\$f\" ] || { echo MISSING; exit 1; }
        if grep -q '{{' \"\$f\"; then echo PLACEHOLDER; exit 1; fi
        echo OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "C3 & bugfix 3: main runs install_sing_box -> generate_credentials -> check_port_available" {
    local install_line cred_line port_line
    install_line=$(grep -n '^[^#]*install_sing_box$' "$PROJECT_ROOT/install.sh" | head -1 | cut -d: -f1)
    cred_line=$(grep -n '^[^#]*generate_credentials$' "$PROJECT_ROOT/install.sh" | head -1 | cut -d: -f1)
    port_line=$(grep -n '^[^#]*check_port_available "\$PORT" tcp$' "$PROJECT_ROOT/install.sh" | head -1 | cut -d: -f1)
    [ -n "$install_line" ] && [ -n "$cred_line" ] && [ -n "$port_line" ]
    [ "$install_line" -lt "$cred_line" ]
    [ "$cred_line" -lt "$port_line" ]
}

@test "C4: parse_keypair handles both PrivateKey: and Private key: formats" {
    parse_keypair "PrivateKey: aB3dE9kLmN0PqRsTuVwXyZ1234567890_abcdEFGH
PublicKey: ZyXwVuTsRqPoNmLkJiHgFeDcBa0987654321-zyxwVUTS"
    [ "$REALITY_PRIVATE_KEY" = "aB3dE9kLmN0PqRsTuVwXyZ1234567890_abcdEFGH" ]
    [ "$REALITY_PUBLIC_KEY" = "ZyXwVuTsRqPoNmLkJiHgFeDcBa0987654321-zyxwVUTS" ]

    parse_keypair "Private key: priv-xyz
Public key: pub-xyz"
    [ "$REALITY_PRIVATE_KEY" = "priv-xyz" ]
    [ "$REALITY_PUBLIC_KEY" = "pub-xyz" ]
}

# --- I1: argument validation -----------------------------------------------

@test "I1: --ip rejects private and malformed addresses" {
    run parse_args --ip 192.168.1.1
    [ "$status" -ne 0 ]
    run parse_args --ip not_an_ip
    [ "$status" -ne 0 ]
}

@test "I1: --port rejects invalid values" {
    run parse_args --port abc
    [ "$status" -ne 0 ]
    run parse_args --port 99999
    [ "$status" -ne 0 ]
    run parse_args --port 0
    [ "$status" -ne 0 ]
}

# --- I2 & bugfix 2: TCP and UDP port occupancy checks ----------------------

@test "I2: check_port_available fails when TCP port is held by another process" {
    lsof() {
        if [[ "$*" == *"-iTCP:8443"* ]]; then
            printf 'COMMAND PID\nnginx 123\n'; return 0
        fi
        return 1
    }
    ss() { return 1; }
    export -f lsof ss
    run check_port_available 8443 tcp
    [ "$status" -ne 0 ]
    [[ "$output" == *"占用"* ]]
}

@test "bugfix 2: check_port_available checks UDP when proto=udp" {
    lsof() {
        if [[ "$*" == *"-iUDP:34567"* ]]; then
            printf 'COMMAND PID\notherudp 555\n'; return 0
        fi
        return 1
    }
    ss() { return 1; }
    export -f lsof ss
    run check_port_available 34567 udp
    [ "$status" -ne 0 ]
    [[ "$output" == *"UDP 端口 34567 已被占用"* ]]
}

@test "I2: check_port_available allows ports owned by sing-box (TCP and UDP)" {
    lsof() { printf 'COMMAND PID\nsing-box 999\n'; return 0; }
    export -f lsof
    run check_port_available 443 tcp
    [ "$status" -eq 0 ]
    run check_port_available 34567 udp
    [ "$status" -eq 0 ]
}

@test "I3: setup_service restarts the service after writing config" {
    local dir; dir=$(mktemp -d)
    SING_BOX_CONFIG_PATH="$dir/config.json"
    local cfg; cfg=$(mktemp); echo '{}' > "$cfg"
    SYSLOG="$(mktemp)"; export SYSLOG
    systemctl() { printf '%s\n' "$*" >> "$SYSLOG"; return 0; }
    export -f systemctl
    setup_service "$cfg" >/dev/null 2>&1
    grep -q '^restart sing-box' "$SYSLOG"
}

@test "I4: detect_public_ip sets IP_DETECT_SINGLE globally on single source" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    detect_public_ip >/dev/null
    [ "$IP_DETECT_SINGLE" -eq 1 ]
    [ "$PUBLIC_IP" = "1.2.3.4" ]
}

@test "M1: re-run with a different --port persists the new port" {
    STATE_DIR="$(mktemp -d)/state"
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=pk
REALITY_PUBLIC_KEY=pub
SHORT_ID=abcd1234
PORT=443
PUBLIC_IP=9.9.9.9
EOF
    chmod 600 "$STATE_DIR/state.env"
    PORT=8443; PORT_EXPLICIT=1; PUBLIC_IP=9.9.9.9
    generate_credentials >/dev/null
    grep -q '^PORT=8443' "$STATE_DIR/state.env"
}

# ===========================================================================
# Feature: REALITY SNI selection & TLS 1.3 + H2 probing
# ===========================================================================

@test "sni: select_reality_sni chooses lowest-latency TLS 1.3 + H2 candidate" {
    SKIP_SNI_CHECK=0
    SNI_EXPLICIT=0
    REALITY_TARGET=""
    probe_sni_target() {
        case "$1" in
            learn.microsoft.com) echo 120; return 0 ;;
            www.apple.com)       echo 25; return 0 ;;
            www.nvidia.com)      return 1 ;;
            www.amd.com)         echo 80; return 0 ;;
            *)                   return 1 ;;
        esac
    }
    export -f probe_sni_target
    select_reality_sni 2>/dev/null
    [ "$REALITY_TARGET" = "www.apple.com" ]
}

@test "sni: explicit --sni fails if TLS 1.3 + H2 check fails" {
    SKIP_SNI_CHECK=0
    SNI_EXPLICIT=1
    REALITY_TARGET="broken.example.com"
    probe_sni_target() { return 1; }
    export -f probe_sni_target
    run select_reality_sni
    [ "$status" -ne 0 ]
    [[ "$output" == *"TLS 1.3 + H2"* ]]
}

@test "sni: upgrading legacy v1 state.env preserves www.microsoft.com" {
    STATE_DIR="$(mktemp -d)/state"; mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=legacy-private
REALITY_PUBLIC_KEY=legacy-public
SHORT_ID=abcd1234
PORT=443
PUBLIC_IP=9.9.9.9
EOF
    chmod 600 "$STATE_DIR/state.env"
    PORT=443; PUBLIC_IP=9.9.9.9; ENABLE_HY2=1; SNI_EXPLICIT=0; REALITY_TARGET=""
    unset HY2_PORT HY2_PASSWORD
    sing-box() { return 0; }
    export -f sing-box
    generate_credentials >/dev/null 2>&1
    [ "$REALITY_TARGET" = "www.microsoft.com" ]
    grep -q '^REALITY_TARGET=www.microsoft.com$' "$STATE_DIR/state.env"
}

# ===========================================================================
# Feature: Hysteria 2 (cert pinning, masquerade, port hopping, optional Brutal)
# ===========================================================================

@test "hy2: state round-trips HY2_PORT, HY2_PASSWORD, hop range, and fingerprint" {
    STATE_DIR="$(mktemp -d)"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="pk"; REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    PORT=443; PUBLIC_IP="1.2.3.4"; REALITY_TARGET="www.apple.com"
    HY2_PORT=34567; HY2_PASSWORD="hy2secret"
    ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    HY2_CERT_FINGERPRINT="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    save_state
    UUID=""; SHORT_ID=""; HY2_PORT=""; HY2_PASSWORD=""; HY2_CERT_FINGERPRINT=""
    HY2_PORT_EXPLICIT=0
    load_state
    [ "$HY2_PORT" = "34567" ]
    [ "$HY2_PASSWORD" = "hy2secret" ]
    [ "$STATE_HY2_HOP_RANGE" = "20000-30000" ]
    [ "$HY2_CERT_FINGERPRINT" = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" ]
}

@test "bugfix 7: generate_hy2_cert uses REALITY_TARGET CN (never vps-vpn) and computes SHA-256 fingerprint" {
    STATE_DIR="$(mktemp -d)"
    SING_BOX_CERT_DIR="$(mktemp -d)"
    REALITY_TARGET="www.apple.com"
    generate_hy2_cert
    [ -s "$SING_BOX_CERT_DIR/hy2.crt" ]
    [ -s "$SING_BOX_CERT_DIR/hy2.key" ]
    local subj
    subj=$(openssl x509 -noout -subject -in "$SING_BOX_CERT_DIR/hy2.crt")
    [[ "$subj" == *"www.apple.com"* ]]
    [[ "$subj" != *"vps-vpn"* ]]
    [[ "$HY2_CERT_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]

    # Idempotency: second call reuses cert
    local before; before=$(cat "$SING_BOX_CERT_DIR/hy2.crt")
    generate_hy2_cert
    [ "$(cat "$SING_BOX_CERT_DIR/hy2.crt")" = "$before" ]
}

@test "hy2: server config includes masquerade, hysteria2 inbound, and optional Brutal" {
    STATE_DIR="$(mktemp -d)"
    SING_BOX_CERT_DIR="$(mktemp -d)"
    PORT=443; HY2_PORT=34567; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="priv"; SHORT_ID="abcd1234"
    REALITY_TARGET="www.apple.com"
    ENABLE_HY2=1; HY2_UP=""; HY2_DOWN=""
    generate_hy2_cert
    generate_server_config >/dev/null
    local f="$STATE_DIR/sing-box-server.json"
    run _json_ok "$f"
    [ "$status" -eq 0 ]
    grep -q '"type": "hysteria2"' "$f"
    grep -q '"masquerade": "https://www.apple.com"' "$f"
    ! grep -q 'up_mbps' "$f"

    # With optional Brutal bandwidth (server up = client down, server down = client up)
    HY2_UP=50; HY2_DOWN=200
    generate_server_config >/dev/null
    run _json_ok "$f"
    [ "$status" -eq 0 ]
    grep -q '"up_mbps": 200' "$f"
    grep -q '"down_mbps": 50' "$f"
}

@test "hy2: every node enables UDP relay, Proxy is manual select (no auto failover)" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="root"; USER_HOME="$(mktemp -d)"
    PUBLIC_IP="1.2.3.4"; PORT=443; HY2_PORT=34567; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    ENABLE_HY2=1; HY2_UP=""; HY2_DOWN=""
    generate_client_config >/dev/null
    local f="$STATE_DIR/client.yaml"
    [ "$(grep -c '^    udp: true$' "$f")" -eq 2 ]
    ! grep -q 'type: fallback' "$f"
    ! grep -q 'type: url-test' "$f"
    ! grep -q 'generate_204' "$f"
    ! grep -q '^    up:' "$f"
    ! grep -q '^    down:' "$f"
    grep -q 'name: "Proxy"' "$f"
    grep -q '\- "vps-vpn-hy2"' "$f"
    grep -q '\- "vps-vpn-vless"' "$f"
}

@test "hy2: --no-port-hop omits ports/hop-interval and --hy2-up/down emits Brutal" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="root"; USER_HOME="$(mktemp -d)"
    PUBLIC_IP="1.2.3.4"; PORT=443; HY2_PORT=34567; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    ENABLE_HY2=1; ENABLE_PORT_HOP=0; HY2_UP=50; HY2_DOWN=200
    generate_client_config >/dev/null
    local f="$STATE_DIR/client.yaml"
    ! grep -q '^    ports:' "$f"
    ! grep -q '^    hop-interval:' "$f"
    grep -q '^    up: 50 Mbps$' "$f"
    grep -q '^    down: 200 Mbps$' "$f"
}

@test "bugfix 4: choose_hy2_port picks safe high port outside hop range and != 8443 / PORT" {
    PORT=35000; ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    local p
    p=$(choose_hy2_port)
    [[ "$p" =~ ^[0-9]+$ ]]
    [ "$p" -ge 30001 ]
    [ "$p" -le 60000 ]
    [ "$p" -ne 8443 ]
    [ "$p" -ne "$PORT" ]
}

@test "port-hop: setup_port_hopping creates nft file, helper, and systemd unit; disable removes them" {
    ENABLE_HY2=1; ENABLE_PORT_HOP=1; PORT_HOP_APPLY=0
    setup_port_hopping 34567 20000-30000
    [ -f "$PORT_HOP_NFT_PATH" ]
    [ -x "$PORT_HOP_HELPER_PATH" ]
    [ -f "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service" ]
    grep -q 'udp dport 20000-30000 redirect to :34567' "$PORT_HOP_NFT_PATH"
    grep -q 'vps-vpn-port-hop apply' "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service"

    disable_port_hopping
    [ ! -f "$PORT_HOP_NFT_PATH" ]
    [ ! -f "$PORT_HOP_HELPER_PATH" ]
    [ ! -f "$SYSTEMD_UNIT_DIR/vps-vpn-port-hop.service" ]
}

# --- BBR, UDP buffers & listening checks -----------------------------------

_bbr_stub_sysctl() {
    sysctl() {
        case "$*" in
            *"-n net.ipv4.tcp_available_congestion_control"*) printf 'reno cubic bbr\n' ;;
            *"-n net.ipv4.tcp_congestion_control"*) printf 'bbr\n' ;;
            *) return 0 ;;
        esac
    }
    modprobe() { return 0; }
    export -f sysctl modprobe
}

@test "bbr: writes sysctl drop-in + modules-load.d idempotently" {
    _bbr_stub_sysctl
    SYSCTL_DIR="$(mktemp -d)"
    MODULES_DIR="$(mktemp -d)"
    SYSCTL_APPLY=0
    enable_bbr >/dev/null 2>&1
    enable_bbr >/dev/null 2>&1
    grep -q '^net.core.default_qdisc = fq$' "$SYSCTL_DIR/99-bbr.conf"
    [ "$(grep -c 'tcp_congestion_control = bbr' "$SYSCTL_DIR/99-bbr.conf")" -eq 1 ]
    grep -q '^tcp_bbr$' "$MODULES_DIR/bbr.conf"
}

@test "bbr: skips gracefully when kernel lacks bbr" {
    SYSCTL_DIR="$(mktemp -d)"; MODULES_DIR="$(mktemp -d)"; SYSCTL_APPLY=0
    sysctl() { printf 'reno cubic\n'; }
    modprobe() { return 0; }
    export -f sysctl modprobe
    run enable_bbr
    [ "$status" -eq 0 ]
    [ ! -f "$SYSCTL_DIR/99-bbr.conf" ]
}

@test "udp buffers: configure_udp_buffers writes 16MB rmem_max and wmem_max" {
    SYSCTL_DIR="$(mktemp -d)"; SYSCTL_APPLY=0
    run configure_udp_buffers
    [ "$status" -eq 0 ]
    [ -f "$SYSCTL_DIR/99-vps-vpn-udp.conf" ]
    grep -q '^net.core.rmem_max = 16777216$' "$SYSCTL_DIR/99-vps-vpn-udp.conf"
    grep -q '^net.core.wmem_max = 16777216$' "$SYSCTL_DIR/99-vps-vpn-udp.conf"
}

@test "check_listening checks TCP and UDP sockets cleanly" {
    ss() {
        if [[ "$1" == "-lun" ]]; then
            printf 'UNCONN 0 0 *:34567 *:*\n'
        else
            printf 'LISTEN 0 4096 *:443 *:*\n'
        fi
    }
    export -f ss
    LISTEN_CHECK_ATTEMPTS=2; LISTEN_CHECK_DELAY=0
    run check_listening 443 tcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"TCP 443 正在监听"* ]]

    run check_listening 34567 udp
    [ "$status" -eq 0 ]
    [[ "$output" == *"UDP 34567 正在监听"* ]]
}

# --- Standard URIs & Installed CLI -----------------------------------------

@test "uri: build_vless_uri and build_hy2_uri emit standard links with pinSHA256 and mport" {
    UUID="11111111-2222-3333-4444-555555555555"
    PUBLIC_IP="1.2.3.4"; PORT=443; REALITY_TARGET="www.apple.com"
    REALITY_PUBLIC_KEY="pubXYZ"; SHORT_ID="abcd1234"
    HY2_PORT=34567; HY2_PASSWORD="pw123"; ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    HY2_CERT_FINGERPRINT="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    local v h
    v=$(build_vless_uri)
    [[ "$v" == "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?"* ]]
    [[ "$v" == *"security=reality"* && "$v" == *"sni=www.apple.com"* && "$v" == *"pbk=pubXYZ"* ]]

    h=$(build_hy2_uri)
    [[ "$h" == "hysteria2://pw123@1.2.3.4:34567/?"* ]]
    [[ "$h" == *"pinSHA256=$HY2_CERT_FINGERPRINT"* && "$h" == *"mport=20000-30000"* && "$h" == *"insecure=0"* ]]
}

@test "cli: installed vps-vpn supports help, info, uri, status, and uninstall --yes" {
    STATE_DIR="$TEST_SANDBOX/state"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="priv-key-SECRET"; REALITY_PUBLIC_KEY="pub-key-OK"; SHORT_ID="abcd1234"
    PORT=443; PUBLIC_IP="1.2.3.4"; REALITY_TARGET="www.apple.com"
    HY2_PORT=34567; HY2_PASSWORD="hy2pw1234567890"
    ENABLE_PORT_HOP=1; HY2_HOP_RANGE="20000-30000"
    HY2_CERT_FINGERPRINT="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    save_state
    USER_NAME="root"; USER_HOME="$TEST_SANDBOX/root"
    generate_client_config >/dev/null
    install_cli >/dev/null 2>&1
    [ -x "$CLI_INSTALL_PATH" ]

    run env EUID_OVERRIDE=0 STATE_DIR="$STATE_DIR" "$CLI_INSTALL_PATH" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"share"* && "$output" == *"uninstall"* ]]

    run env EUID_OVERRIDE=0 STATE_DIR="$STATE_DIR" "$CLI_INSTALL_PATH" info
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.2.3.4"* && "$output" == *"20000-30000"* ]]
    [[ "$output" != *"priv-key-SECRET"* ]]

    run env EUID_OVERRIDE=0 STATE_DIR="$STATE_DIR" "$CLI_INSTALL_PATH" uri
    [ "$status" -eq 0 ]
    [[ "$output" == *"vless://"* && "$output" == *"hysteria2://"* ]]

    run env EUID_OVERRIDE=0 STATE_DIR="$STATE_DIR" \
        SING_BOX_CONFIG_PATH="$SING_BOX_CONFIG_PATH" \
        SING_BOX_CERT_DIR="$SING_BOX_CERT_DIR" \
        PORT_HOP_HELPER_PATH="$PORT_HOP_HELPER_PATH" \
        PORT_HOP_NFT_PATH="$PORT_HOP_NFT_PATH" \
        SYSTEMD_UNIT_DIR="$SYSTEMD_UNIT_DIR" \
        SYSCTL_DIR="$SYSCTL_DIR" MODULES_DIR="$MODULES_DIR" \
        "$CLI_INSTALL_PATH" uninstall --yes
    [ "$status" -eq 0 ]
    [ ! -d "$STATE_DIR" ]
    [ ! -f "$CLI_INSTALL_PATH" ]
}
