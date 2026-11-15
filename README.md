# VPS VPN 一键部署

在 Ubuntu VPS 上一键部署 VLESS + REALITY 代理，生成可由 Clash Verge（电脑）与 CMFA（Android）导入的 YAML 配置。使用官方 sing-box 包与 systemd 服务。

## 功能特性

- 一条命令完成安装，自动装好系统依赖与环境，开箱即用
- 自动校验系统版本/架构/权限，自动用 apt 补齐缺失命令（`curl`、`openssl`、`iproute2`、`ca-certificates`、`lsof` 等）
- 检测到本机 ufw 已启用时自动放行代理 TCP 端口
- 自动检测公网 IP 与当前登录用户
- 自动生成或复用 UUID、REALITY 密钥对、short ID
- 生成兼容 Mihomo 的客户端 YAML（Clash Verge / CMFA 通用）
- 支持 root 直接运行，也支持普通用户通过 `sudo` 运行
- 凭据持久保存，重复执行复用而非轮换
- 配置改动前备份，校验失败或启动失败时保留/恢复旧配置

## 系统要求

- Ubuntu 22.04 及以上 LTS（amd64 / arm64）。22.04、24.04 已实测验证；26.04 及更新的 LTS 会以兼容模式运行（脚本会提示未实测验证，不会阻断）。
- 具有公网 IPv4 地址的 VPS
- root 权限或 sudo 权限
- 可访问 Ubuntu 软件源（用于自动安装依赖）；离线或已自备环境时加 `--skip-deps`

## 快速开始

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash
```

脚本会自动检查环境并安装缺失依赖，无需你手动 `apt install`。

### 自定义参数（可选）

```bash
# 手动指定公网 IPv4（自动检测失败时使用）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --ip 1.2.3.4

# 使用自定义端口（默认 443）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --port 8443

# 跳过自动安装依赖（已自行备好 curl/openssl 等环境时）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --skip-deps
```

### 使用 sudo 时的注意

`curl | sudo bash` 会占用标准输入，若 sudo 需要交互式密码，请先执行 `sudo -v` 预授权，或在已提升的 shell 中运行脚本。

## 客户端配置

安装完成后，客户端配置文件位于：

- 主配置文件（root 拥有）：`/root/vps-vpn/client.yaml`
- 普通用户副本（若通过 sudo 以普通用户安装）：`/home/<用户名>/vps-vpn/client.yaml`

客户端 YAML 包含 UUID、REALITY 公钥与 short ID，**不包含 REALITY 私钥**。请妥善保管，不要上传到公开仓库。

### 下载到本地电脑

```bash
# 使用 scp（替换 <用户名> 与 <VPS_IP>）
scp <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .

# 或使用 SSH 密钥
scp -i /path/to/key.pem <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .
```

若以 root 安装，则路径为 `/root/vps-vpn/client.yaml`，下载示例：

```bash
scp root@<VPS_IP>:/root/vps-vpn/client.yaml .
```

### 导入 Clash Verge（电脑）

1. 打开 Clash Verge
2. 「配置」→「导入」→「本地文件」
3. 选择下载的 `client.yaml`
4. 启用配置并开启 TUN 模式

### 导入 CMFA（Android）

1. 将 `client.yaml` 通过安全方式传输到手机
2. 打开 CMFA
3. 「配置」→「导入」→「本地文件」
4. 选择 `client.yaml`
5. 启用配置（Android VPN 模式）

## 服务管理

```bash
sudo systemctl start sing-box     # 启动
sudo systemctl stop sing-box      # 停止
sudo systemctl restart sing-box   # 重启
sudo systemctl status sing-box    # 状态
sudo journalctl -u sing-box -f    # 查看日志
```

## 文件与权限

```text
/root/vps-vpn/
  ├─ state.env        # 凭据状态（0600，目录 0700）
  ├─ client.yaml      # 主客户端配置（0600）
  └─ backups/         # 配置变更前备份（0700）
```

`state.env` 仅保存受控键值，脚本读取时逐行解析并校验格式，不会 `source` 或执行其中内容。

## 重复安装

脚本支持重复执行：会复用已有的凭据与端口，不会无故轮换。如确需重新生成凭据，请在维护窗口内备份后删除 `/root/vps-vpn/state.env`，再重新运行安装，并替换所有客户端配置。

## 防火墙与云厂商安全组

本机防火墙：**若检测到 ufw 已启用**，脚本会自动执行 `ufw allow <端口>/tcp` 放行代理端口（绝不删除规则、绝不动 SSH、不改动其他端口）；ufw 未启用或未安装则跳过，不擅自开启。

云厂商安全组：脚本**无法**修改，必须由你在控制台手动放行：

- 来自可信来源的 SSH（通常 22）
- 代理使用的 TCP 端口（默认 443）

服务启动成功仅表示 sing-box 已在本机就绪，不代表云安全组已放行或客户端可公网连通，请分别核验。

## 故障排除

### 无法自动检测公网 IP

使用 `--ip` 手动指定：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --ip <你的IP>
```

### 端口被占用

换用其他端口：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --port 8443
```

### 服务启动失败

查看日志：

```bash
sudo journalctl -u sing-box -n 50
```

脚本在配置校验失败时会保留现有配置不变；在服务启动失败时会尝试恢复备份并提示排查。

## 安全注意事项

- 客户端配置含敏感信息（UUID、公钥等），请妥善保管，勿公开分享
- 真实凭据、客户端配置、VPS 地址不应进入 Git 仓库
- 定期更新系统与 sing-box 到最新稳定版本

## 验证状态

- ✅ 脚本语法检查（ShellCheck）
- ✅ 单元测试（BATS）
- ✅ 配置生成测试
- ✅ 错误处理与备份恢复测试
- ⏳ 真实 VPS 部署测试（待用户购买 VPS 后进行）
- ⏳ Clash Verge 客户端测试（待用户测试）
- ⏳ CMFA 客户端测试（待用户测试）

## 许可证

MIT License
