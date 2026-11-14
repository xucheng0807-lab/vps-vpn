#!/usr/bin/env bats
#
# Tests for install.sh.
#
# Strategy (see ledger): install.sh is sourced so its functions can be unit
# tested in isolation with test doubles for curl / id / sing-box / systemctl.
# Nothing here touches a real VPS, real sing-box, or real systemd.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PROJECT_ROOT
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/install.sh"
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

# --- Task 2: public IPv4 detection ------------------------------------------

# Fake curl: answers per-service from $FAKE_CURL. Unknown service -> empty.
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
    run detect_public_ip
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3.4" ]
}

@test "detect_public_ip accepts single valid result with warning" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3.4" ]
}

@test "detect_public_ip rejects private address" {
    _fake_curl
    FAKE_CURL_IPIFY="192.168.1.1"; FAKE_CURL_ICANHAZ="192.168.1.1"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "detect_public_ip rejects reserved address" {
    _fake_curl
    FAKE_CURL_IPIFY="127.0.0.1"; FAKE_CURL_ICANHAZ="169.254.1.1"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "detect_public_ip rejects non-IPv4 text" {
    _fake_curl
    FAKE_CURL_IPIFY="not-an-ip"; FAKE_CURL_ICANHAZ="1.2.3.4.5"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "detect_public_ip fails on conflicting results" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ="5.6.7.8"; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "detect_public_ip fails when all services fail" {
    _fake_curl
    FAKE_CURL_IPIFY=""; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    run detect_public_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
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
    openssl() { echo "deadbeefdeadbeefdeadbeefdeadbeef"; }
    export -f sing-box openssl
}

# True only where chmod actually round-trips (Linux). MSYS/NTFS discards bits.
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
    # Our code must request 0700 on the dir and 0600 on the file.
    grep -q "700 $STATE_DIR" "$CHMOD_LOG"
    grep -q "600 $STATE_DIR/state.env" "$CHMOD_LOG"
    # Where the filesystem honors bits, verify they really stuck.
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
EOF
    chmod 600 "$STATE_DIR/state.env"
    sing-box() { return 99; }   # must NOT be called on reuse
    export -f sing-box
    generate_credentials >/dev/null
    [ "$UUID" = "11111111-2222-3333-4444-555555555555" ]
    [ "$REALITY_PRIVATE_KEY" = "keep-private-key" ]
    [ "$PORT" = "8443" ]
    grep -q '^UUID=11111111-2222-3333-4444-555555555555' "$STATE_DIR/state.env"
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



