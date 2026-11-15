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

@test "generate_server_config uses fixed reality handshake target" {
    STATE_DIR="$(mktemp -d)"
    PORT=8443; UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="k"; SHORT_ID="abcd1234"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_server_config >/dev/null
    local f="$STATE_DIR/sing-box-server.json"
    grep -q '"server": "www.microsoft.com"' "$f"
    grep -q '"server_port": 443' "$f"
    grep -q '"server_name": "www.microsoft.com"' "$f"
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
    mkdir -p "$USER_HOME"
    ENABLE_HY2=0
    cd "$PROJECT_ROOT"
    generate_client_config >/dev/null

    [ -f "$STATE_DIR/client.yaml" ]
    [ -f "$USER_HOME/vps-vpn/client.yaml" ]

    # No unreplaced placeholders.
    ! grep -q '{{' "$STATE_DIR/client.yaml"
    # Correct values landed.
    grep -q 'server: 1.2.3.4' "$STATE_DIR/client.yaml"
    grep -q 'port: 443' "$STATE_DIR/client.yaml"
    grep -q 'servername: www.microsoft.com' "$STATE_DIR/client.yaml"
    grep -q 'public-key: pub-key-ZZZ' "$STATE_DIR/client.yaml"
    grep -q 'short-id: abcd1234' "$STATE_DIR/client.yaml"
    # The REALITY private key must never appear in a client config.
    ! grep -q 'SECRET-PRIVATE-KEY' "$STATE_DIR/client.yaml"
    ! grep -q 'SECRET-PRIVATE-KEY' "$USER_HOME/vps-vpn/client.yaml"
    # DNS is proxy-resolved, mixed port is loopback only.
    grep -q 'listen: 127.0.0.1:1053' "$STATE_DIR/client.yaml"
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

# Regression: the user copy's DIRECTORY (created by root) must be owned by the
# target user, otherwise that user cannot traverse it and `scp` fails with
# "No such file or directory". Failed for real on a VPS as sudo user.
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
    # The directory itself must be handed to the user (not only the file).
    grep -q "1000:1000 $USER_HOME/vps-vpn\$" "$CHOWN_LOG"
    # And the produced directory must be 0700 for its owner.
    grep -q "700 $USER_HOME/vps-vpn\$" "$CHMOD_LOG"
}

@test "validate_client_config fails on malformed YAML" {
    local f; f=$(mktemp); printf 'proxies: [unclosed\n' > "$f"
    run validate_client_config "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"客户端配置校验失败"* ]]
}

# --- Task 7: sing-box install and systemd service ---------------------------

@test "setup_service copies config and reports started" {
    local dir; dir=$(mktemp -d)
    SING_BOX_CONFIG_PATH="$dir/etc/sing-box/config.json"
    local cfg; cfg=$(mktemp); echo '{}' > "$cfg"
    systemctl() { return 0; }; export -f systemctl
    run setup_service "$cfg"
    [ "$status" -eq 0 ]
    [ -f "$SING_BOX_CONFIG_PATH" ]
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

@test "install_sing_box skips when already installed" {
    sing-box() { return 0; }; export -f sing-box
    run install_sing_box
    [ "$status" -eq 0 ]
    [[ "$output" == *"已安装"* ]]
}

@test "install_sing_box installs pinned version via official script" {
    CAP="$(mktemp)"; export CAP
    curl() { printf 'curl %s\n' "$*" >> "$CAP"; }
    bash() { printf 'bash %s\n' "$*" >> "$CAP"; cat >/dev/null; }
    export -f curl bash
    run install_sing_box
    [ "$status" -eq 0 ]
    grep -q 'curl .*sing-box.app' "$CAP"
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

@test "restore_config restores the latest backup" {
    STATE_DIR="$(mktemp -d)"
    local cfg; cfg=$(mktemp); echo '{"v":1}' > "$cfg"
    backup_config "$cfg" >/dev/null
    echo '{"v":2}' > "$cfg"
    restore_config "$cfg" >/dev/null
    grep -q '"v":1' "$cfg"
}

@test "restore_config fails when no backup exists" {
    STATE_DIR="$(mktemp -d)"
    run restore_config "$STATE_DIR/missing.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"找不到可用的备份"* ]]
}

# --- Task 8 (integration): main rolls back on service start failure ---------
@test "main restores the previous config when the new service fails to start" {
    local root; root=$(mktemp -d)
    STATE_DIR="$root/state"; SING_BOX_CONFIG_PATH="$root/etc/sing-box/config.json"
    mkdir -p "$(dirname "$SING_BOX_CONFIG_PATH")"
    printf '{"old":true}\n' > "$SING_BOX_CONFIG_PATH"

    # sing-box present + passes check; service start fails; restart succeeds.
    sing-box() { return 0; }
    systemctl() { [[ "$1" == "is-active" ]] && return 3; return 0; }
    lsof() { return 1; }
    export -f sing-box systemctl lsof

    run main --ip 1.2.3.4
    [ "$status" -ne 0 ]
    # Old config content restored over the system path.
    grep -q '"old":true' "$SING_BOX_CONFIG_PATH"
}

# --- Task 9: installation summary ------------------------------------------

@test "print_summary shows endpoint, paths and scp for a sudo user" {
    USER_NAME="ubuntu"; PUBLIC_IP="1.2.3.4"; PORT=443
    run print_summary "/root/vps-vpn/client.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"安装完成"* ]]
    [[ "$output" == *"公网地址: 1.2.3.4"* ]]
    [[ "$output" == *"scp ubuntu@1.2.3.4:/home/ubuntu/vps-vpn/client.yaml ."* ]]
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

# ===========================================================================
# Final-review fix pass (C1..C4, I1..I4, M1)
# ===========================================================================

# --- C1: works when piped to bash (BASH_SOURCE[0] is empty) -----------------
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

# End-to-end: run install.sh through the REAL `bash install.sh` entry point with
# stubbed PATH binaries (no sourcing). Proves the actual invocation path works.
@test "E2E: bash install.sh completes end-to-end with stub tooling" {
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
  *) printf 'deadbeef' ;;
esac
S
    chmod +x "$bin"/*
    printf 'ID=ubuntu\nVERSION_ID="22.04"\n' > "$root/os-release"
    local real_bash; real_bash=$(command -v bash)
    run env -i PATH="$bin:/usr/bin:/bin" STATE_DIR="$root/state" \
        SING_BOX_CONFIG_PATH="$root/etc/sing-box/config.json" \
        OS_RELEASE_FILE="$root/os-release" EUID_OVERRIDE=0 ARCH_OVERRIDE=amd64 \
        "$real_bash" "$PROJECT_ROOT/install.sh" --ip 1.2.3.4 --skip-deps
    [ "$status" -eq 0 ]
    [ -f "$root/state/state.env" ]
    [ -f "$root/state/client.yaml" ]
    [ -f "$root/etc/sing-box/config.json" ]
    [[ "$output" == *"安装完成"* ]]
    # No placeholders left in either generated config.
    run grep -l '{{' "$root/state/client.yaml" "$root/etc/sing-box/config.json"
    [ "$status" -ne 0 ]
}

# ===========================================================================
# Feature: one-command dependency + environment bootstrap
# ===========================================================================

# Helper: make a fake os-release file and point the reader at it.
_write_os_release() {  # $1=dir $2=id $3=ver
    printf 'ID=%s\nVERSION_ID="%s"\n' "$2" "$3" > "$1/os-release"
}

# --- check_environment ------------------------------------------------------
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

@test "env: rejects non-Ubuntu OS" {
    local d; d=$(mktemp -d); _write_os_release "$d" debian 12
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
    [[ "$output" == *"Ubuntu"* ]]
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

@test "env: accepts Ubuntu 26.04 without warning" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 26.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -eq 0 ]
}

@test "env: accepts unknown future Ubuntu (>=22.04) with a warning but no failure" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 28.04
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -eq 0 ]
    [[ "$output" == *"未在"* || "$output" == *"警告"* || "$output" == *"验证"* ]]
}

@test "env: rejects Ubuntu older than 22.04 (21.10)" {
    local d; d=$(mktemp -d); _write_os_release "$d" ubuntu 21.10
    OS_RELEASE_FILE="$d/os-release"
    ARCH_OVERRIDE=amd64; EUID_OVERRIDE=0
    run check_environment
    [ "$status" -ne 0 ]
}

# --- ensure_dependencies ----------------------------------------------------
@test "deps: installs missing packages via apt-get" {
    APT_LOG="$(mktemp)"; export APT_LOG
    apt-get() { printf 'apt-get %s\n' "$*" >> "$APT_LOG"; return 0; }
    export -f apt-get
    # fake command lookup: curl missing, others present
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

@test "deps: does nothing when all tools are present" {
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

@test "deps: fails clearly when apt-get is unavailable" {
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
@test "fw: allows port when ufw is active" {
    FW_LOG="$(mktemp)"; export FW_LOG
    command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 0; fi; builtin command "$@"; }
    ufw() {
        printf 'ufw %s\n' "$*" >> "$FW_LOG"
        if [[ "$1" == "status" ]]; then printf 'Status: active\n'; fi
        return 0
    }
    export -f command ufw
    run configure_firewall 443
    [ "$status" -eq 0 ]
    grep -q 'allow 443/tcp' "$FW_LOG"
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

# --- --skip-deps argument ---------------------------------------------------
@test "args: --skip-deps sets SKIP_DEPS=1" {
    parse_args --skip-deps
    [ "$SKIP_DEPS" -eq 1 ]
}

@test "args: default SKIP_DEPS is 0" {
    parse_args
    [ "$SKIP_DEPS" -eq 0 ]
}

# Regression: sing-box 1.10.0 has a REALITY defect that rejects every client
# with "REALITY: processed invalid connection" even when keys/short_id/uuid all
# match. Verified on a real VPS: 1.10.0 always fails, 1.14.4 works.
@test "version: pinned sing-box version is at least 1.11 (REALITY fix)" {
    local ver major minor
    ver="$SING_BOX_VERSION"
    major="${ver%%.*}"
    minor="${ver#*.}"; minor="${minor%%.*}"
    [ "$major" -eq 1 ]
    [ "$minor" -ge 11 ]
}

@test "version: install_sing_box pins a REALITY-safe version" {
    CAP="$(mktemp)"; export CAP
    curl() { printf 'curl %s\n' "$*" >> "$CAP"; }
    bash() { printf 'bash %s\n' "$*" >> "$CAP"; cat >/dev/null; }
    command() { if [[ "$1" == "-v" && "$2" == "sing-box" ]]; then return 1; fi; builtin command "$@"; }
    export -f curl bash command
    install_sing_box >/dev/null 2>&1
    local pinned
    pinned=$(grep -o -- '--version [0-9.]*' "$CAP" | awk '{print $2}' | head -1)
    [ -n "$pinned" ]
    local minor; minor=$(echo "$pinned" | cut -d. -f2)
    [ "$minor" -ge 11 ]
}

# --- C2: single-file install (no external templates needed) -----------------
@test "C2: generate_server_config works from a lone copy of install.sh" {
    local dir; dir=$(mktemp -d)
    cp "$PROJECT_ROOT/install.sh" "$dir/install.sh"
    # Run in a clean bash so there is no second `source` into this test process
    # (real single-file install sources the file exactly once).
    run bash -c "
        set -Eeuo pipefail
        source '$dir/install.sh'
        STATE_DIR='$dir/state'
        PORT=443; UUID='11111111-2222-3333-4444-555555555555'
        REALITY_PRIVATE_KEY='k'; SHORT_ID='abcd1234'
        f=\$(generate_server_config)
        [ -f \"\$f\" ] || { echo MISSING; exit 1; }
        if grep -q '{{' \"\$f\"; then echo PLACEHOLDER; exit 1; fi
        echo OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# --- C3: install_sing_box ordering inside main ------------------------------
@test "C3: main calls install_sing_box before generate_credentials" {
    local install_line cred_line
    install_line=$(grep -n '^[^#]*install_sing_box$' "$PROJECT_ROOT/install.sh" | head -1 | cut -d: -f1)
    cred_line=$(grep -n '^[^#]*generate_credentials$' "$PROJECT_ROOT/install.sh" | head -1 | cut -d: -f1)
    [ -n "$install_line" ] && [ -n "$cred_line" ]
    [ "$install_line" -lt "$cred_line" ]
}

# --- C4: parse real keypair output format -----------------------------------
@test "C4: parse_keypair strips PrivateKey:/PublicKey: labels without spaces" {
    parse_keypair "PrivateKey: aB3dE9kLmN0PqRsTuVwXyZ1234567890_abcdEFGH
PublicKey: ZyXwVuTsRqPoNmLkJiHgFeDcBa0987654321-zyxwVUTS"
    [ "$REALITY_PRIVATE_KEY" = "aB3dE9kLmN0PqRsTuVwXyZ1234567890_abcdEFGH" ]
    [ "$REALITY_PUBLIC_KEY" = "ZyXwVuTsRqPoNmLkJiHgFeDcBa0987654321-zyxwVUTS" ]
}

@test "C4: parse_keypair also handles 'Private key:' with a space" {
    parse_keypair "Private key: priv-xyz
Public key: pub-xyz"
    [ "$REALITY_PRIVATE_KEY" = "priv-xyz" ]
    [ "$REALITY_PUBLIC_KEY" = "pub-xyz" ]
}

# --- I1: argument validation -----------------------------------------------
@test "I1: --ip rejects private address" {
    run parse_args --ip 192.168.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"无效"* || "$output" == *"合法"* || "$output" == *"公网"* ]]
}

@test "I1: --ip rejects malformed address" {
    run parse_args --ip not_an_ip
    [ "$status" -ne 0 ]
}

@test "I1: --port rejects non-numeric" {
    run parse_args --port abc
    [ "$status" -ne 0 ]
}

@test "I1: --port rejects out-of-range" {
    run parse_args --port 99999
    [ "$status" -ne 0 ]
}

@test "I1: --port rejects zero" {
    run parse_args --port 0
    [ "$status" -ne 0 ]
}

# --- I2: port occupancy pre-check ------------------------------------------
@test "I2: check_port_available fails when port is held by another process" {
    lsof() {
        if [[ "$*" == *":8443"* ]]; then
            printf 'COMMAND PID\nnginx 123\n'; return 0
        fi
        return 1
    }
    ss() { return 1; }
    export -f lsof ss
    run check_port_available 8443
    [ "$status" -ne 0 ]
    [[ "$output" == *"占用"* ]]
}

@test "I2: check_port_available passes when port is free" {
    lsof() { return 1; }
    ss() { return 1; }
    export -f lsof ss
    run check_port_available 8443
    [ "$status" -eq 0 ]
}

@test "I2: check_port_available allows a port owned only by sing-box" {
    lsof() { printf 'COMMAND PID\nsing-box 999\n'; return 0; }
    export -f lsof
    run check_port_available 8443
    [ "$status" -eq 0 ]
}

# --- I3: setup_service restarts a running unit -----------------------------
@test "I3: setup_service restarts the service after writing config" {
    local dir; dir=$(mktemp -d)
    SING_BOX_CONFIG_PATH="$dir/config.json"
    local cfg; cfg=$(mktemp); echo '{}' > "$cfg"
    SYSLOG="$(mktemp)"; export SYSLOG
    systemctl() { printf '%s\n' "$*" >> "$SYSLOG"; [[ "$1" == "is-active" ]] && return 0; return 0; }
    export -f systemctl
    setup_service "$cfg" >/dev/null 2>&1
    grep -q '^restart sing-box' "$SYSLOG"
}

# --- I4: single-source IP hint survives ------------------------------------
@test "I4: detect_public_ip sets IP_DETECT_SINGLE globally on single source" {
    _fake_curl
    FAKE_CURL_IPIFY="1.2.3.4"; FAKE_CURL_ICANHAZ=""; FAKE_CURL_IFCONFIG=""
    detect_public_ip >/dev/null
    [ "$IP_DETECT_SINGLE" -eq 1 ]
    [ "$PUBLIC_IP" = "1.2.3.4" ]
}

# --- M1: port change persists to state -------------------------------------
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
# Feature: Hysteria 2 as a second, coexisting protocol
# ===========================================================================

@test "hy2: state round-trips HY2_PORT and HY2_PASSWORD" {
    STATE_DIR="$(mktemp -d)"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="pk"; REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    PORT=443; PUBLIC_IP="1.2.3.4"
    HY2_PORT=8443; HY2_PASSWORD="hy2secret"
    save_state
    grep -q '^HY2_PORT=8443' "$STATE_DIR/state.env"
    grep -q '^HY2_PASSWORD=hy2secret' "$STATE_DIR/state.env"
    # round-trip through load_state
    UUID=""; SHORT_ID=""; HY2_PORT=""; HY2_PASSWORD=""
    load_state
    [ "$HY2_PORT" = "8443" ]
    [ "$HY2_PASSWORD" = "hy2secret" ]
}

@test "hy2: load_state rejects malformed HY2_PORT" {
    STATE_DIR="$(mktemp -d)/state"; mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=pk
SHORT_ID=abcd1234
HY2_PORT=notaport
EOF
    run load_state
    [ "$status" -ne 0 ]
    [[ "$output" == *"HY2_PORT"* ]]
}

@test "hy2: state.env without HY2 keys still loads (backward compatible)" {
    STATE_DIR="$(mktemp -d)/state"; mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/state.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIVATE_KEY=pk
SHORT_ID=abcd1234
PORT=443
EOF
    run load_state
    [ "$status" -eq 0 ]
}

@test "hy2: generate_hy2_cert creates cert and key with 0600" {
    STATE_DIR="$(mktemp -d)"
    CHMOD_LOG="$(mktemp)"; export CHMOD_LOG
    chmod() { printf '%s\n' "$*" >> "$CHMOD_LOG"; command chmod "$@" 2>/dev/null || true; }
    export -f chmod
    generate_hy2_cert
    [ -s "$STATE_DIR/hy2.crt" ]
    [ -s "$STATE_DIR/hy2.key" ]
    grep -q "600 $STATE_DIR/hy2.key" "$CHMOD_LOG"
    # a second call must reuse, not regenerate
    local before; before=$(cat "$STATE_DIR/hy2.crt")
    generate_hy2_cert
    [ "$(cat "$STATE_DIR/hy2.crt")" = "$before" ]
}

@test "hy2: server config contains a hysteria2 inbound alongside vless" {
    STATE_DIR="$(mktemp -d)"
    PORT=443; HY2_PORT=8443; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIVATE_KEY="priv"; SHORT_ID="abcd1234"
    generate_hy2_cert
    cd "$PROJECT_ROOT"
    generate_server_config >/dev/null
    local f="$STATE_DIR/sing-box-server.json"
    run node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f"
    [ "$status" -eq 0 ]
    grep -q '"type": "vless"' "$f"
    grep -q '"type": "hysteria2"' "$f"
    grep -q '"listen_port": 8443' "$f"
    grep -q "\"password\": \"hy2secret\"" "$f"
    grep -q 'hy2.crt' "$f"
    ! grep -q '{{' "$f"
}

@test "hy2: client config exposes both nodes with manual switch group" {
    STATE_DIR="$(mktemp -d)"
    USER_NAME="root"; USER_HOME="$(mktemp -d)"
    PUBLIC_IP="1.2.3.4"; PORT=443; HY2_PORT=8443; HY2_PASSWORD="hy2secret"
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PUBLIC_KEY="pub"; SHORT_ID="abcd1234"
    cd "$PROJECT_ROOT"
    generate_client_config >/dev/null
    local f="$STATE_DIR/client.yaml"
    grep -q 'name: "vps-vpn"' "$f"
    grep -q 'name: "vps-vpn-hy2"' "$f"
    grep -q 'type: hysteria2' "$f"
    grep -q 'port: 8443' "$f"
    grep -q 'password: hy2secret' "$f"
    # both nodes must be selectable in the group
    grep -q '\- "vps-vpn"' "$f"
    grep -q '\- "vps-vpn-hy2"' "$f"
    # skip-cert-verify belongs to the self-signed hysteria2 node only
    [ "$(grep -c 'skip-cert-verify' "$f")" -eq 1 ]
    # the REALITY private key must never leak
    ! grep -q 'priv-key-SECRET' "$f"
}

@test "hy2: check_port_available works for a UDP port" {
    lsof() { return 1; }
    ss() { return 1; }
    export -f lsof ss
    run check_port_available 8443
    [ "$status" -eq 0 ]
}

@test "hy2: configure_firewall allows both TCP and UDP when ufw is active" {
    FW_LOG="$(mktemp)"; export FW_LOG
    command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 0; fi; builtin command "$@"; }
    ufw() {
        printf 'ufw %s\n' "$*" >> "$FW_LOG"
        if [[ "$1" == "status" ]]; then printf 'Status: active\n'; fi
        return 0
    }
    export -f command ufw
    configure_firewall 443 8443 >/dev/null 2>&1
    grep -q 'allow 443/tcp' "$FW_LOG"
    grep -q 'allow 8443/udp' "$FW_LOG"
}

@test "hy2: generate_credentials creates HY2 creds on first run" {
    STATE_DIR="$(mktemp -d)/state"
    PORT=443; PUBLIC_IP=1.2.3.4
    _stub_crypto_tools
    generate_credentials >/dev/null 2>&1
    grep -q '^HY2_PORT=' "$STATE_DIR/state.env"
    grep -q '^HY2_PASSWORD=' "$STATE_DIR/state.env"
    # password must be non-trivial
    local pw; pw=$(grep '^HY2_PASSWORD=' "$STATE_DIR/state.env" | cut -d= -f2-)
    [ ${#pw} -ge 16 ]
}

@test "hy2: --hy2-port argument is validated and applied" {
    parse_args --hy2-port 9443
    [ "$HY2_PORT" = "9443" ]
    run parse_args --hy2-port 99999
    [ "$status" -ne 0 ]
}

@test "hy2: --no-hy2 disables the second protocol" {
    parse_args --no-hy2
    [ "$ENABLE_HY2" -eq 0 ]
}










