# VPS VPN 一键部署

在 Ubuntu VPS 上一键部署 VLESS + REALITY 与 Hysteria 2 双协议代理，生成可由 Clash Verge（电脑）与 CMFA（Android）导入的 YAML 配置。两个节点在客户端里手动切换。使用官方 sing-box 包与 systemd 服务。

## 功能特性

- 一条命令完成安装，自动装好系统依赖与环境，开箱即用
- 自动校验系统版本/架构/权限，自动用 apt 补齐缺失命令（`curl`、`openssl`、`iproute2`、`ca-certificates`、`lsof` 等）
- 同时部署 VLESS + REALITY（TCP 443）与 Hysteria 2（UDP 8443）两个协议
- 客户端节点名直接标明协议（`vps-vpn-vless` / `vps-vpn-hy2`），在 Global 策略组里手动切换
- 检测到本机 ufw 已启用时自动放行代理 TCP/UDP 端口
- 自动检测公网 IP 与当前登录用户
- 自动生成或复用 UUID、REALITY 密钥对、short ID、HY2 密码与自签证书
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

# 使用自定义 VLESS 端口（默认 443）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --port 8443

# 使用自定义 Hysteria 2 端口（默认 8443/UDP）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --hy2-port 9443

# 只部署 VLESS + REALITY，不部署 Hysteria 2
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --no-hy2

# 跳过自动安装依赖（已自行备好 curl/openssl 等环境时）
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/vps-vpn/main/install.sh | sudo bash -s -- --skip-deps
```

### 使用 sudo 时的注意

`curl | sudo bash` 会占用标准输入，若 sudo 需要交互式密码，请先执行 `sudo -v` 预授权，或在已提升的 shell 中运行脚本。

## 客户端配置

安装完成后，客户端配置文件位于：

- 主配置文件（root 拥有）：`/root/vps-vpn/client.yaml`
- 普通用户副本（若通过 sudo 以普通用户安装）：`/home/<用户名>/vps-vpn/client.yaml`

客户端 YAML 包含 UUID、REALITY 公钥与 short ID、HY2 密码，**不包含 REALITY 私钥**。请妥善保管，不要上传到公开仓库。

### 协议与节点

默认部署两个节点，节点名直接标明协议：

| 节点 | 协议 | 传输 | 适用场景 |
| --- | --- | --- | --- |
| `vps-vpn-hy2` | Hysteria 2 | UDP 8443 | 弱网/丢包环境下更快 |
| `vps-vpn-vless` | VLESS + REALITY | TCP 443 | UDP 被运营商封锁时用它 |

`Global` 是普通的 `select` 策略组，两个节点都是它的直接成员，**没有自动故障切换**：流量走哪个协议完全由你在客户端里选，不会在你不知情时被换到另一条链路。

切换方式：Clash Verge / CMFA 的「代理 → Global」里点 `vps-vpn-hy2` 或 `vps-vpn-vless`。

> Hysteria 2 走自签证书，客户端配置里带 `skip-cert-verify: true`；这是 HY2 的常规做法，不影响 REALITY 那一路的 TLS 校验。

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

/etc/sing-box/
  ├─ config.json      # 服务端配置
  ├─ hy2.crt          # HY2 自签证书（0644，属主 sing-box）
  └─ hy2.key          # HY2 私钥（0600，属主 sing-box）
```

HY2 证书刻意放在 `/etc/sing-box` 而不是 `/root/vps-vpn`：服务以非特权用户 `sing-box` 运行，读不到 `/root` 下的文件，放错位置会导致 HY2 端口不监听且日志报权限错误。

`state.env` 仅保存受控键值，脚本读取时逐行解析并校验格式，不会 `source` 或执行其中内容。

## 重复安装

脚本支持重复执行：会复用已有的凭据与端口，不会无故轮换。如确需重新生成凭据，请在维护窗口内备份后删除 `/root/vps-vpn/state.env`，再重新运行安装，并替换所有客户端配置。

## 防火墙与云厂商安全组

本机防火墙：**若检测到 ufw 已启用**，脚本会自动执行 `ufw allow <端口>/tcp`（VLESS）与 `ufw allow <端口>/udp`（Hysteria 2）放行代理端口（绝不删除规则、绝不动 SSH、不改动其他端口）；ufw 未启用或未安装则跳过，不擅自开启。

云厂商安全组：脚本**无法**修改，必须由你在控制台手动放行：

- 来自可信来源的 SSH（通常 22）
- 代理使用的 **TCP** 端口（VLESS，默认 443）
- 代理使用的 **UDP** 端口（Hysteria 2，默认 8443）

> UDP 8443 最容易漏。AWS / Lightsail / GCP 的安全组（防火墙）默认只放行 TCP，若只开了 TCP 443，客户端里 `vps-vpn-hy2` 节点会一直连不上，表现为选了 HY2 却没网——此时切到 `vps-vpn-vless` 立刻正常。HY2 调通后建议在 Clash 里看连接详情确认走的是 UDP。

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

## 协议性能对比

同一台 VPS（AWS us-west-2）、同一目标 `https://cachefly.cachefly.net/50mb.test`、各跑 3 次的实测下载速度：

| 场景 | VLESS + REALITY | Hysteria 2 | 差异 |
| --- | --- | --- | --- |
| 本地直连、无延迟注入 | 1221.9 Mbps | 728.2 Mbps | VLESS 略快（无线损时 TCP 更吃满带宽） |
| 注入 60 ms 延迟 | 156.1 Mbps | 162.1 Mbps | 基本持平 |
| 60 ms 延迟 + 3% 丢包 | 97.3 Mbps | 121.3 Mbps | **HY2 快 25%** |

真实 YouTube 播放（4K）测得 `Connection Speed`：VLESS 3561 Kbps，HY2 8003 Kbps（**+125%**）。

结论：带宽充裕、线路干净时两者都能跑满；一旦有丢包，HY2 基于 QUIC 的优势明显，所以默认选 HY2、VLESS 兜底。

## 验证状态

- ✅ 脚本语法检查（ShellCheck）
- ✅ 单元测试（BATS）
- ✅ 配置生成测试
- ✅ 错误处理与备份恢复测试
- ✅ 真实 VPS 部署测试（Ubuntu 24.04.5 LTS / AWS，sing-box 1.14.4）
- ✅ 服务端链路验证（公网 443 可达、REALITY 伪装证书正常、回环隧道出口 IP 正确）
- ✅ Hysteria 2 链路验证（UDP 8443 可达、自签证书被服务用户正常读取、客户端握手成功）
- ✅ 双协议对齐测速（见上方「协议性能对比」）
- ⏳ Clash Verge 客户端测试（待用户测试）
- ⏳ CMFA 客户端测试（待用户测试）
- ⚠️ 已知现象：YouTube 播 AV1（`av01`）编码时，若本机显卡不支持 AV1 硬解则 CPU 软解会掉帧（`Dropped Frames` 可达 ~50%）。这与代理协议无关，属解码能力问题；可在 YouTube 设置里选 h264 播放或安装 h264ify 缓解。

## 版本说明

脚本固定安装 **sing-box 1.14.4**。请勿降级到 1.10.0 或更低版本：1.10.0 存在 REALITY 缺陷，即使 UUID、公钥、short ID 全部匹配，服务端仍会拒绝所有客户端连接并记录 `REALITY: processed invalid connection`（已在真实 VPS 上复现并确认：同一份配置在 1.10.0 上必然失败，在 1.14.4 上正常工作）。

## 许可证

MIT License
