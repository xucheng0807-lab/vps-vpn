# VPS VPN 一键部署实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 实现一个 Bash 脚本，在 Ubuntu 22.04/24.04 VPS 上一键部署 VLESS + REALITY 代理，生成可由 Clash Verge 和 CMFA 导入的 YAML 配置。

**架构：** 单个 `install.sh` 脚本完成所有安装、配置和服务管理；使用 sing-box 官方包；通过 `SUDO_USER` 动态检测当前用户；自动生成或复用凭据。

**技术栈：** Bash、systemd、sing-box（指定版本）、Mihomo（配置校验）、ShellCheck、GitHub Actions CI。

**规格：** [2026-11-14-vps-vpn-design.md](../specs/2026-11-14-vps-vpn-design.md)

## 全局约束

- 支持 Ubuntu 22.04 和 24.04；amd64 和 arm64 架构。
- 使用 sing-box 官方包安装脚本的指定版本，不自动追最新版。
- 安装命令格式：`curl -fsSL <URL> | sudo bash`（支持可选 `--ip` 和 `--port`）。
- 通过 `SUDO_USER` 环境变量检测实际用户，生成 `/home/<SUDO_USER>/vps-vpn/client.yaml` 下载副本。
- 服务端配置包含 UUID、REALITY 私钥/公钥、short ID；客户端 YAML 不包含私钥。
- 使用 `systemctl enable --now sing-box` 启动服务，不自动重启 VPS。
- 敏感信息（UUID、私钥、IP）不写入 Git 仓库，不输出到终端日志。

## 审查重点

1. **公网 IP 识别失败或返回非法值**：脚本应正确拒绝并提示使用 `--ip` 参数，不生成错误配置。
2. **重复执行安装**：应复用已有凭据和配置，不无故轮换，不破坏现有服务。
3. **不同云服务商用户名**：必须正确识别 `SUDO_USER`，生成正确的文件路径和下载命令。
4. **防火墙或端口占用**：检测到端口被占用时停止并提示，不终止现有进程。
5. **配置验证失败**：sing-box 或 Mihomo 配置校验失败时，保留备份并恢复，不启动无效服务。

---

### 任务 1：基础脚本框架与参数解析

**文件：**
- 创建：`install.sh`
- 测试：`tests/install.bats`（使用 BATS 或简单 bash 测试）

**接口：**
- 消费：无（入口点）
- 产生：`parse_args()`、`main()` 函数框架；`--ip`、`--port`、`--help` 参数支持。

- [ ] **步骤 1：创建脚本基础框架**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="vps-vpn"
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
    exit 0
}

parse_args() {
    IP=""
    PORT="$DEFAULT_PORT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)
                IP="$2"
                shift 2
                ;;
            --port)
                PORT="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                echo "未知参数: $1" >&2
                usage
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    echo "IP: $IP, PORT: $PORT"
}

main "$@"
```

- [ ] **步骤 2：编写参数解析测试**

```bash
#!/usr/bin/env bats

@test "parse --ip and --port" {
    run ./install.sh --ip 1.2.3.4 --port 8080
    [ "$status" -eq 0 ]
    [[ "$output" =~ "IP: 1.2.3.4, PORT: 8080" ]]
}

@test "default port is 443" {
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PORT: 443" ]]
}
```

- [ ] **步骤 3：运行测试并确保通过**

```bash
bats tests/install.bats
```

- [ ] **步骤 4：提交**

```bash
git add install.sh tests/install.bats
git commit -m "feat: add basic script framework with argument parsing"
```

---

### 任务 2：公网 IPv4 自动检测

**文件：**
- 修改：`install.sh`（添加 `detect_public_ip()`）
- 测试：`tests/install.bats`（添加检测逻辑测试）

**接口：**
- 消费：`IP` 变量（来自参数解析）
- 产生：`PUBLIC_IP` 变量（有效 IPv4 或空字符串）

- [ ] **步骤 1：实现 IP 检测函数**

```bash
detect_public_ip() {
    local ip=""
    local services=("https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip")
    
    for service in "${services[@]}"; do
        ip=$(curl -fsSL --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # 简单验证不是私网/保留地址
            if [[ ! "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.) ]]; then
                echo "$ip"
                return 0
            fi
        fi
    done
    
    echo ""
    return 1
}
```

- [ ] **步骤 2：集成到 main 函数**

```bash
main() {
    parse_args "$@"
    
    if [[ -z "$IP" ]]; then
        PUBLIC_IP=$(detect_public_ip)
        if [[ -z "$PUBLIC_IP" ]]; then
            echo "错误：无法自动检测公网 IP，请使用 --ip 参数手动指定" >&2
            exit 1
        fi
    else
        PUBLIC_IP="$IP"
    fi
    
    echo "使用公网 IP: $PUBLIC_IP"
}
```

- [ ] **步骤 3：编写测试（模拟 curl 响应）**

```bash
@test "detect_public_ip returns valid IPv4" {
    # 模拟 curl 返回有效 IP
    function curl() { echo "1.2.3.4"; }
    export -f curl
    run ./install.sh
    [ "$status" -eq 0 ]
    [[ "$output" =~ "使用公网 IP: 1.2.3.4" ]]
    unset -f curl
}

@test "detect_public_ip fails with private IP" {
    function curl() { echo "192.168.1.1"; }
    export -f curl
    run ./install.sh
    [ "$status" -eq 1 ]
    [[ "$output" =~ "无法自动检测公网 IP" ]]
    unset -f curl
}
```

- [ ] **步骤 4：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add public IPv4 auto-detection"
```

---

### 任务 3：用户与权限检测

**文件：**
- 修改：`install.sh`（添加 `detect_user_context()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：`SUDO_USER` 环境变量
- 产生：`USER_NAME`、`USER_HOME`、`USER_ID`、`GROUP_ID` 变量

- [ ] **步骤 1：实现用户检测**

```bash
detect_user_context() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        USER_NAME="$SUDO_USER"
        USER_HOME="/home/$USER_NAME"
        USER_ID=$(id -u "$USER_NAME")
        GROUP_ID=$(id -g "$USER_NAME")
    else
        USER_NAME="root"
        USER_HOME="/root"
        USER_ID=0
        GROUP_ID=0
    fi
    
    echo "检测到用户: $USER_NAME (home: $USER_HOME)"
}
```

- [ ] **步骤 2：集成到 main**

```bash
main() {
    parse_args "$@"
    detect_user_context
    # ... 后续逻辑
}
```

- [ ] **步骤 3：编写测试**

```bash
@test "detect_user_context with SUDO_USER=ubuntu" {
    export SUDO_USER="ubuntu"
    # 模拟 id 命令
    function id() {
        if [[ "$1" == "-u" ]]; then echo "1000";
        elif [[ "$1" == "-g" ]]; then echo "1000"; fi
    }
    export -f id
    
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [[ "$output" =~ "检测到用户: ubuntu" ]]
    
    unset SUDO_USER
    unset -f id
}
```

- [ ] **步骤 4：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add user context detection"
```

---

### 任务 4：凭据生成与状态管理

**文件：**
- 修改：`install.sh`（添加 `generate_credentials()`、`load_state()`、`save_state()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：`STATE_DIR`
- 产生：`UUID`、`REALITY_PRIVATE_KEY`、`REALITY_PUBLIC_KEY`、`SHORT_ID` 变量

- [ ] **步骤 1：实现凭据生成（使用 sing-box 生成）**

```bash
generate_credentials() {
    if [[ -f "$STATE_DIR/state.env" ]]; then
        echo "加载已有凭据..."
        load_state
    else
        echo "生成新凭据..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        
        # 使用 sing-box 生成 REALITY 密钥对
        local keypair
        keypair=$(sing-box generate reality-keypair)
        REALITY_PRIVATE_KEY=$(echo "$keypair" | grep "Private key" | awk '{print $3}')
        REALITY_PUBLIC_KEY=$(echo "$keypair" | grep "Public key" | awk '{print $3}')
        
        # 生成随机 short ID (8位十六进制)
        SHORT_ID=$(openssl rand -hex 4)
        
        save_state
    fi
}

load_state() {
    # 安全地读取 state.env（不 source，避免代码执行）
    while IFS='=' read -r key value; do
        case "$key" in
            UUID) UUID="$value" ;;
            REALITY_PRIVATE_KEY) REALITY_PRIVATE_KEY="$value" ;;
            REALITY_PUBLIC_KEY) REALITY_PUBLIC_KEY="$value" ;;
            SHORT_ID) SHORT_ID="$value" ;;
        esac
    done < "$STATE_DIR/state.env"
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    
    cat > "$STATE_DIR/state.env" <<EOF
UUID=$UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID
PORT=$PORT
PUBLIC_IP=$PUBLIC_IP
EOF
    chmod 600 "$STATE_DIR/state.env"
}
```

- [ ] **步骤 2：编写测试（模拟 sing-box）**

```bash
@test "generate_credentials creates new state" {
    export STATE_DIR="$(mktemp -d)"
    
    # 模拟 sing-box 和 openssl
    function sing-box() { 
        if [[ "$1" == "generate" && "$2" == "reality-keypair" ]]; then
            echo "Private key: test-private-key"
            echo "Public key: test-public-key"
        fi
    }
    function openssl() { echo "abcd1234"; }
    export -f sing-box openssl
    
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [ -f "$STATE_DIR/state.env" ]
    
    rm -rf "$STATE_DIR"
    unset -f sing-box openssl
}
```

- [ ] **步骤 3：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add credential generation and state management"
```

---

### 任务 5：服务端配置生成

**文件：**
- 创建：`templates/server.json.template`
- 修改：`install.sh`（添加 `generate_server_config()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：所有凭据变量、`PORT`、`PUBLIC_IP`
- 产生：服务端 JSON 配置文件路径

- [ ] **步骤 1：创建服务端配置模板**

```json
{
  "log": {
    "level": "warn"
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
      "type": "direct"
    }
  ]
}
```

- [ ] **步骤 2：实现配置生成函数**

```bash
generate_server_config() {
    local config_file="$STATE_DIR/sing-box-server.json"
    local reality_target="www.microsoft.com"  # 固定握手目标
    
    sed -e "s/{{PORT}}/$PORT/g" \
        -e "s/{{UUID}}/$UUID/g" \
        -e "s/{{REALITY_TARGET}}/$reality_target/g" \
        -e "s/{{REALITY_PRIVATE_KEY}}/$REALITY_PRIVATE_KEY/g" \
        -e "s/{{SHORT_ID}}/$SHORT_ID/g" \
        templates/server.json.template > "$config_file"
    
    chmod 600 "$config_file"
    echo "$config_file"
}
```

- [ ] **步骤 3：验证配置**

```bash
validate_config() {
    local config_file="$1"
    if ! sing-box check -c "$config_file" 2>/dev/null; then
        echo "错误：sing-box 配置校验失败" >&2
        return 1
    fi
}
```

- [ ] **步骤 4：编写测试**

```bash
@test "generate_server_config creates valid JSON" {
    export STATE_DIR="$(mktemp -d)"
    export UUID="test-uuid"
    export REALITY_PRIVATE_KEY="test-private"
    export SHORT_ID="abcd1234"
    export PORT="443"
    
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [ -f "$STATE_DIR/sing-box-server.json" ]
    
    rm -rf "$STATE_DIR"
}
```

- [ ] **步骤 5：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats templates/server.json.template
git commit -m "feat: add server configuration generation"
```

---

### 任务 6：客户端 YAML 生成

**文件：**
- 创建：`templates/client.yaml.template`
- 修改：`install.sh`（添加 `generate_client_config()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：`PUBLIC_IP`、`PORT`、`UUID`、`REALITY_PUBLIC_KEY`、`SHORT_ID`、`USER_HOME`
- 产生：客户端 YAML 文件路径（主文件和用户副本）

- [ ] **步骤 1：创建客户端配置模板**

```yaml
proxies:
  - name: "vps-vpn"
    type: vless
    server: {{PUBLIC_IP}}
    port: {{PORT}}
    uuid: {{UUID}}
    flow: xtls-rprx-vision
    network: tcp
    tls: true
    servername: {{REALITY_TARGET}}
    client-fingerprint: chrome
    reality-opts:
      public-key: {{REALITY_PUBLIC_KEY}}
      short-id: {{SHORT_ID}}

proxy-groups:
  - name: "Global"
    type: select
    proxies:
      - "vps-vpn"

rules:
  - "IP-CIDR,127.0.0.0/8,DIRECT"
  - "IP-CIDR,192.168.0.0/16,DIRECT"
  - "IP-CIDR,10.0.0.0/8,DIRECT"
  - "IP-CIDR,172.16.0.0/12,DIRECT"
  - "MATCH,Global"

dns:
  enable: true
  listen: 127.0.0.1:1053
  default-nameserver:
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
```

- [ ] **步骤 2：实现客户端配置生成**

```bash
generate_client_config() {
    local reality_target="www.microsoft.com"
    local main_config="$STATE_DIR/client.yaml"
    local user_config="$USER_HOME/vps-vpn/client.yaml"
    
    # 生成主配置文件（root 拥有）
    sed -e "s/{{PUBLIC_IP}}/$PUBLIC_IP/g" \
        -e "s/{{PORT}}/$PORT/g" \
        -e "s/{{UUID}}/$UUID/g" \
        -e "s/{{REALITY_TARGET}}/$reality_target/g" \
        -e "s/{{REALITY_PUBLIC_KEY}}/$REALITY_PUBLIC_KEY/g" \
        -e "s/{{SHORT_ID}}/$SHORT_ID/g" \
        templates/client.yaml.template > "$main_config"
    chmod 600 "$main_config"
    
    # 如果不是 root 用户，生成用户副本
    if [[ "$USER_NAME" != "root" ]]; then
        mkdir -p "$USER_HOME/vps-vpn"
        chmod 700 "$USER_HOME/vps-vpn"
        cp "$main_config" "$user_config"
        chown "$USER_ID:$GROUP_ID" "$user_config"
        chmod 600 "$user_config"
    fi
    
    echo "$main_config"
}
```

- [ ] **步骤 3：验证客户端配置（使用 Mihomo）**

```bash
validate_client_config() {
    local config_file="$1"
    # 使用 Mihomo 验证 YAML 语法和配置
    if ! mihomo -f "$config_file" -test 2>/dev/null; then
        echo "错误：客户端配置校验失败" >&2
        return 1
    fi
}
```

- [ ] **步骤 4：编写测试**

```bash
@test "generate_client_config creates YAML files" {
    export STATE_DIR="$(mktemp -d)"
    export USER_NAME="ubuntu"
    export USER_HOME="/tmp/test-home"
    export USER_ID=1000
    export GROUP_ID=1000
    export PUBLIC_IP="1.2.3.4"
    export PORT="443"
    export UUID="test-uuid"
    export REALITY_PUBLIC_KEY="test-public"
    export SHORT_ID="abcd1234"
    
    mkdir -p "$USER_HOME"
    
    run ./install.sh
    [ "$status" -eq 0 ]
    [ -f "$STATE_DIR/client.yaml" ]
    [ -f "$USER_HOME/vps-vpn/client.yaml" ]
    
    rm -rf "$STATE_DIR" "$USER_HOME"
}
```

- [ ] **步骤 5：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats templates/client.yaml.template
git commit -m "feat: add client configuration generation"
```

---

### 任务 7：sing-box 安装与 systemd 服务

**文件：**
- 修改：`install.sh`（添加 `install_sing_box()`、`setup_service()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：服务端配置文件路径
- 产生：运行中的 sing-box 服务

- [ ] **步骤 1：实现 sing-box 安装（使用官方脚本指定版本）**

```bash
install_sing_box() {
    local sing_box_version="1.10.0"  # 固定版本
    
    if command -v sing-box &>/dev/null; then
        echo "sing-box 已安装，跳过安装步骤"
        return 0
    fi
    
    echo "安装 sing-box v$sing_box_version..."
    
    # 使用官方安装脚本指定版本
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$sing_box_version"
}
```

- [ ] **步骤 2：配置 systemd 服务**

```bash
setup_service() {
    local config_file="$1"
    
    # 复制配置到系统位置
    cp "$config_file" /etc/sing-box/config.json
    chmod 600 /etc/sing-box/config.json
    
    # 启用并启动服务
    systemctl enable --now sing-box
    
    # 验证服务状态
    if ! systemctl is-active --quiet sing-box; then
        echo "错误：sing-box 服务启动失败" >&2
        systemctl status sing-box --no-pager >&2
        return 1
    fi
    
    echo "sing-box 服务已启动"
}
```

- [ ] **步骤 3：编写测试（模拟 systemctl）**

```bash
@test "setup_service enables and starts sing-box" {
    export STATE_DIR="$(mktemp -d)"
    
    # 模拟 systemctl
    function systemctl() {
        if [[ "$1" == "is-active" ]]; then
            return 0
        fi
        return 0
    }
    export -f systemctl
    
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    
    unset -f systemctl
    rm -rf "$STATE_DIR"
}
```

- [ ] **步骤 4：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add sing-box installation and service setup"
```

---

### 任务 8：错误处理与备份恢复

**文件：**
- 修改：`install.sh`（添加 `backup_config()`、`restore_config()`、错误处理）
- 测试：`tests/install.bats`

**接口：**
- 消费：配置文件路径
- 产生：备份文件和恢复机制

- [ ] **步骤 1：实现备份功能**

```bash
backup_config() {
    local config_file="$1"
    local backup_dir="$STATE_DIR/backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/config.json.$timestamp"
    
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "$backup_file"
        chmod 600 "$backup_file"
        echo "配置已备份到: $backup_file"
    fi
}
```

- [ ] **步骤 2：实现恢复功能**

```bash
restore_config() {
    local config_file="$1"
    local backup_dir="$STATE_DIR/backups"
    local latest_backup
    
    latest_backup=$(ls -t "$backup_dir"/config.json.* 2>/dev/null | head -1)
    
    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$config_file"
        chmod 600 "$config_file"
        echo "已从备份恢复配置: $latest_backup"
        return 0
    else
        echo "错误：找不到可用的备份文件" >&2
        return 1
    fi
}
```

- [ ] **步骤 3：集成错误处理**

```bash
main() {
    # ... 前面的步骤
    
    # 备份现有配置
    backup_config "/etc/sing-box/config.json"
    
    # 生成并验证新配置
    local new_config
    new_config=$(generate_server_config)
    
    if ! validate_config "$new_config"; then
        echo "恢复备份配置..."
        restore_config "/etc/sing-box/config.json"
        exit 1
    fi
    
    # 启动服务，如果失败则恢复
    if ! setup_service "$new_config"; then
        echo "服务启动失败，恢复备份..."
        restore_config "/etc/sing-box/config.json"
        systemctl restart sing-box || true
        exit 1
    fi
    
    # ... 后续步骤
}
```

- [ ] **步骤 4：编写测试**

```bash
@test "backup and restore config" {
    export STATE_DIR="$(mktemp -d)"
    local test_config="$STATE_DIR/test.json"
    echo '{"test": true}' > "$test_config"
    
    backup_config "$test_config"
    [ -n "$(ls -A "$STATE_DIR/backups")" ]
    
    rm "$test_config"
    restore_config "$test_config"
    [ -f "$test_config" ]
    
    rm -rf "$STATE_DIR"
}
```

- [ ] **步骤 5：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add error handling and backup/restore"
```

---

### 任务 9：安装总结与输出

**文件：**
- 修改：`install.sh`（添加 `print_summary()`）
- 测试：`tests/install.bats`

**接口：**
- 消费：所有配置信息
- 产生：用户可读的安装总结

- [ ] **步骤 1：实现输出函数**

```bash
print_summary() {
    local client_config="$1"
    
    cat <<EOF

========================================
安装完成！
========================================

公网地址: $PUBLIC_IP
端口: $PORT
服务端配置: /etc/sing-box/config.json
客户端配置: $client_config

下载客户端配置到本地电脑：
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

导入到 Clash Verge 或 CMFA 即可使用。

服务管理命令：
  启动: sudo systemctl start sing-box
  停止: sudo systemctl stop sing-box
  重启: sudo systemctl restart sing-box
  查看日志: sudo journalctl -u sing-box -f

========================================
EOF
}
```

- [ ] **步骤 2：集成到 main**

```bash
main() {
    # ... 所有安装步骤
    
    local client_config
    client_config=$(generate_client_config)
    
    print_summary "$client_config"
}
```

- [ ] **步骤 3：编写测试**

```bash
@test "print_summary outputs correct format" {
    export USER_NAME="ubuntu"
    export PUBLIC_IP="1.2.3.4"
    export PORT="443"
    
    run ./install.sh --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [[ "$output" =~ "安装完成" ]]
    [[ "$output" =~ "scp ubuntu@1.2.3.4" ]]
}
```

- [ ] **步骤 4：运行测试并提交**

```bash
bats tests/install.bats
git add install.sh tests/install.bats
git commit -m "feat: add installation summary output"
```

---

### 任务 10：README 文档编写

**文件：**
- 创建：`README.md`
- 测试：无（文档审查）

**接口：**
- 消费：所有功能和使用方法
- 产生：完整的中文使用文档

- [ ] **步骤 1：编写 README**

```markdown
# VPS VPN 一键部署

在 Ubuntu VPS 上一键部署 VLESS + REALITY 代理，支持 Clash Verge 和 CMFA 客户端。

## 功能特性

- 一条命令完成安装，无需手动配置
- 自动检测公网 IP 和当前用户
- 生成可用于 Clash Verge 和 CMFA 的 YAML 配置
- 支持 root 和普通用户（通过 sudo）安装
- 凭据自动保存和复用，支持重复执行

## 系统要求

- Ubuntu 22.04 或 24.04
- 具有公网 IPv4 地址的 VPS
- root 权限或 sudo 权限

## 快速开始

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash
```

### 自定义参数（可选）

```bash
# 手动指定公网 IP（如果自动检测失败）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --ip 1.2.3.4

# 使用自定义端口
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --port 8443
```

## 客户端配置

安装完成后，客户端配置文件位于：

- 主配置文件：`/root/vps-vpn/client.yaml`
- 用户副本：`/home/<用户名>/vps-vpn/client.yaml`

### 下载到本地电脑

```bash
# 使用 scp 下载（替换 <用户名> 和 <VPS_IP>）
scp <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .

# 或使用 SSH 密钥
scp -i /path/to/key.pem <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .
```

### 导入 Clash Verge（电脑）

1. 打开 Clash Verge
2. 点击「配置」→「导入」→「本地文件」
3. 选择下载的 `client.yaml`
4. 启用配置并开启 TUN 模式

### 导入 CMFA（Android 手机）

1. 将 `client.yaml` 文件传输到手机
2. 打开 CMFA
3. 点击「配置」→「导入」→「本地文件」
4. 选择 `client.yaml` 文件
5. 启用配置

## 服务管理

```bash
# 启动服务
sudo systemctl start sing-box

# 停止服务
sudo systemctl stop sing-box

# 重启服务
sudo systemctl restart sing-box

# 查看服务状态
sudo systemctl status sing-box

# 查看日志
sudo journalctl -u sing-box -f
```

## 重复安装

脚本支持重复执行，会复用已有的凭据和配置。如需重新生成凭据，请删除 `/root/vps-vpn/state.env` 后重新运行安装。

## 故障排除

### 无法自动检测公网 IP

如果自动检测失败，请使用 `--ip` 参数手动指定：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --ip <你的IP>
```

### 端口被占用

如果 443 端口被占用，可以使用其他端口：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --port 8443
```

### 服务启动失败

查看日志获取详细信息：

```bash
sudo journalctl -u sing-box -n 50
```

## 安全注意事项

- 客户端配置文件包含敏感信息（UUID、公钥等），请妥善保管
- 不要将配置文件上传到公共仓库或分享给他人
- 定期更新系统和 sing-box 到最新版本

## 许可证

MIT License
```

- [ ] **步骤 2：提交 README**

```bash
git add README.md
git commit -m "docs: add comprehensive README"
```

---

### 任务 11：CI/CD 配置

**文件：**
- 创建：`.github/workflows/ci.yml`
- 测试：通过 GitHub Actions 验证

**接口：**
- 消费：测试脚本和源代码
- 产生：自动化测试和代码质量检查

- [ ] **步骤 1：创建 CI 配置**

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y bats shellcheck
      
      - name: Run ShellCheck
        run: shellcheck install.sh
      
      - name: Run tests
        run: bats tests/
```

- [ ] **步骤 2：提交 CI 配置**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow"
```

---

### 任务 12：最终验证与文档更新

**文件：**
- 修改：`README.md`（添加验证状态说明）
- 创建：`.gitignore`
- 测试：运行完整测试套件

**接口：**
- 消费：所有任务完成状态
- 产生：可发布的完整项目

- [ ] **步骤 1：创建 .gitignore**

```gitignore
# 敏感文件
*.env
state.env
client.yaml
*.pem
*.key

# 临时文件
*.tmp
*.log
tmp/

# 系统文件
.DS_Store
Thumbs.db

# 测试输出
tests/tmp/
```

- [ ] **步骤 2：运行完整测试**

```bash
# 运行所有测试
bats tests/

# 运行 ShellCheck
shellcheck install.sh

# 检查 Git 状态
git status
```

- [ ] **步骤 3：更新 README 验证状态**

在 README 中添加：

```markdown
## 验证状态

- ✅ 脚本语法检查（ShellCheck）
- ✅ 单元测试（BATS）
- ✅ 配置生成测试
- ✅ 错误处理测试
- ⏳ 真实 VPS 部署测试（待用户购买 VPS 后进行）
- ⏳ Clash Verge 客户端测试（待用户测试）
- ⏳ CMFA 客户端测试（待用户测试）
```

- [ ] **步骤 4：最终提交**

```bash
git add .gitignore README.md
git commit -m "chore: add .gitignore and update verification status"
```

---

## 实施完成标准

- [ ] 所有 12 个任务按顺序完成
- [ ] 所有测试通过（`bats tests/` 和 `shellcheck install.sh`）
- [ ] CI/CD 流水线配置完成并可运行
- [ ] README 包含完整的使用说明和故障排除
- [ ] 敏感信息不进入 Git 仓库
- [ ] 代码遵循项目规范（英文代码、中文文档）

## 后续工作（用户购买 VPS 后）

1. 在新 VPS 上执行一键安装命令
2. 验证自动 IP 检测和用户识别
3. 下载客户端配置并导入 Clash Verge/CMFA
4. 测试 Google、YouTube、Claude、Codex 等服务
5. 如有问题，根据日志进行修复和优化
6. （可选）根据实际需求添加 Hysteria 2 支持