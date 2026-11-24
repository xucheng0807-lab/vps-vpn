# VPS VPN 一键部署

在 **Ubuntu / Debian** VPS 上一键部署 **VLESS + REALITY (TCP)** 与 **Hysteria 2 (UDP + 端口跳跃)** 双协议代理，自动生成兼容 **Clash Verge（电脑）** 与 **CMFA（Android）** 的 Mihomo YAML 配置（国内直连白名单分流 + Fake-IP 分流 DNS + 证书指纹固定），并自带轻量管理命令 `vps-vpn`。

## 功能特性

- **一条命令开箱即用**：自动校验系统版本/架构/权限，自动用 `apt` 补齐缺失依赖（`curl`、`openssl`、`iproute2`、`lsof` 与可选 `qrencode`）
- **双协议协同，兼顾抗封锁与晚高峰速度**：
  - **VLESS + REALITY（TCP 443）**：安装前自动探测精选无跳转大站（TLS 1.3 + HTTP/2）择低延迟 SNI 写入状态，支持 `--sni` 自定义
  - **Hysteria 2（UDP 随机高端口 + 默认端口跳跃 `20000-30000`）**：自动通过独立 `nftables`（回退 `iptables`）规则链 + systemd 服务持久化端口跳跃，规避运营商晚高峰单端口 UDP QoS 限速；带 `masquerade` 伪装、正常域名外观自签证书与 SHA-256 `fingerprint` 证书固定（不再裸奔 `skip-cert-verify`）
- **不影响国内网速，海外与 AI 流量绝不漏直连**：
  - 客户端采用 MetaCubeX `meta-rules-dat`（`.mrs` 二进制规则集）**白名单分流**：仅大陆域名/IP 与局域网走 `DIRECT`，其余所有海外与新 AI 域名默认兜底走 `Proxy`
  - **Fake-IP 分流 DNS**：国内走阿里/腾讯 DoH 直连解析，海外走代理侧解析，避免国内直连 Google/Cloudflare DoH 导致的超时卡顿
  - 默认 **QUIC BBR 自适应**（电脑宽带与手机 4G/5G/Wi-Fi 共用同一份 YAML 不卡顿），并开放 `--hy2-up` / `--hy2-down` 按需开启 Brutal
  - 节点在 `Proxy` 策略组内**纯手动切换**（零后台探测流量），开启 `profile.store-selected: true` 保证客户端重启不重置选择
- **电脑 & 手机多种便捷导入**：
  - 保留 `scp` 本地拉取（零额外端口，适合 AWS/GCP 强安全组）
  - 内置 `sudo vps-vpn share`：按需开启一次性随机 256-bit Token 下载链接 + 终端二维码（下载达限或 5 分钟自动销毁，UFW 活跃时自动临时放行并在退出时回收）
  - 内置 `sudo vps-vpn uri`：输出标准 `vless://` 与 `hysteria2://` 链接与二维码，兼顾 Shadowrocket / v2rayN / sing-box
- **内核网络与安全加固**：
  - 自动开启 **BBR + FQ**（TCP 加速）与 **16MB Linux UDP 缓冲区**（`net.core.rmem_max` / `wmem_max`，释放 Hysteria 2 吞吐）
  - 服务端 `route.rules` 默认拦截通过代理访问内网私网与云元数据（`169.254.0.0/16`、`100.64.0.0/10`、`ip_is_private`），并优先 IPv4 解析
  - 自动校验已装 `sing-box` 版本（`< 1.11` 自动升级）并修复 `/etc/sing-box/config.json` 属主为 `sing-box` 用户
  - 凭据持久保存，重复执行复用而非轮换；配置变更前备份，校验或启动失败自动回滚

## 系统要求

- **Ubuntu 22.04 及以上 LTS**（22.04 / 24.04 已验证）或 **Debian 11 / 12 / 13**（amd64 / arm64）
- 具有公网 IPv4 地址的 VPS
- root 权限或 sudo 权限
- 可访问系统软件源（离线或已自备环境时加 `--skip-deps`）

## 快速开始

### 一键安装

登录你的 VPS（SSH），复制粘贴执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash
```

> **非 root 用户登录（如 AWS 的 `ubuntu` / Debian 的 `admin`）也可直接使用**，`sudo` 已包含在命令里。
> 若 `sudo` 需要输入密码，请先执行 `sudo -v` 预授权，再运行上面的命令。

### 自定义参数（可选）

在命令末尾加 `-s -- 参数`：

```bash
# 手动指定公网 IPv4（自动检测失败时使用）
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --ip 1.2.3.4

# 自定义 VLESS TCP 端口与 REALITY 伪装域名
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --port 8443 --sni www.apple.com

# 自定义 Hysteria 2 监听端口或端口跳跃范围（默认 20000-30000）
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --hy2-port 35678 --hop-range 25000-35000

# 关闭端口跳跃（云安全组只想开单个 UDP 端口时）
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --no-port-hop

# 按需为 Hysteria 2 启用 Brutal 拥塞控制（必须同时指定上下行 Mbps，按本地真实带宽保守填写）
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --hy2-up 50 --hy2-down 200

# 只部署 VLESS + REALITY，不部署 Hysteria 2
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --no-hy2

# 强制升级 sing-box 到目标版本
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | sudo bash -s -- --upgrade

# 查看全部参数
curl -fsSL https://raw.githubusercontent.com/xucheng0807-lab/vps-vpn/main/install.sh | bash -s -- --help
```

### 关于 `bash <(...)` 写法

`sudo` 默认关闭除 stdin/stdout/stderr 以外的文件描述符，因此 `sudo bash <(curl ...)` 会报 `/dev/fd/63: No such file or directory`。本项目统一推荐 `curl -fsSL ... | sudo bash`，在 root 和普通用户 `sudo` 环境下均稳定成立。

## 电脑与手机便捷导入

安装完成后，主客户端配置文件位于 `/root/vps-vpn/client.yaml`（通过 `sudo` 安装时同时在 `/home/<你的用户名>/vps-vpn/client.yaml` 生成可读副本）。该文件**绝不包含 REALITY 私钥**，但仍含节点密码与 UUID，请勿公开分享。

### 方式一：一次性临时分享（最便捷，手机 CMFA 扫码直导）

在 VPS 上按需运行：

```bash
sudo vps-vpn share
```

- 自动启动带 **256-bit 随机 Token** 的临时下载链接，并在终端打印 **二维码**；
- 手机打开 **CMFA** →「配置」→「新建」→「URL」扫码或粘贴链接即可；电脑 **Clash Verge** 同理；
- 默认下载 **2 次**（电脑 + 手机各一次）或 **5 分钟**后自动关闭并回收临时 UFW 规则，平时零 HTTP 端口暴露。

> **AWS / Lightsail / GCP 提示**：如果你的云厂商控制台安全组没有放行临时分享的随机 TCP 端口，手机将无法直连临时链接。你可以用 `sudo vps-vpn share --port <已放行端口>`，或直接使用下方**方式二**（零额外云安全组端口）。

### 方式二：电脑 `scp` 拉取（任何云安全组下通用）

安装结束或运行 `sudo vps-vpn info` 会打印可直接复制的 `scp` 命令：

```bash
# 普通用户登录（如 AWS 的 ubuntu）
scp <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .

# 使用 SSH 密钥
scp -i /path/to/key.pem <用户名>@<VPS_IP>:/home/<用户名>/vps-vpn/client.yaml .
```

- **导入 Clash Verge（电脑）**：「配置」→「新建」→ 选择「Local（本地）」导入 `client.yaml` → 启用该配置并开启 TUN 模式（或系统代理）。
- **导入 CMFA（Android）**：若不便使用 `vps-vpn share`，可在同一局域网下把 `client.yaml` 安全传到手机后选择「配置」→「导入」→「本地文件」，启用 Android VPN 即可。

### 方式三：标准单节点 URI 与二维码（辅助客户端）

```bash
sudo vps-vpn uri
```

输出标准 `vless://` 与 `hysteria2://`（含 `pinSHA256` 证书固定与 `mport` 端口跳跃参数）及终端二维码，适合临时导入 Shadowrocket / v2rayN / sing-box 客户端。

### 节点切换说明

`Proxy` 是普通的 `select` 策略组（无自动测速/无后台探测流量），重启后自动记住上次选择：

| 节点 | 协议 | 传输 | 适用场景 |
| --- | --- | --- | --- |
| `vps-vpn-hy2` | Hysteria 2 | UDP（默认 `20000-30000` 端口跳跃） | 晚高峰/跨海丢包环境下吞吐更快，日常优先 |
| `vps-vpn-vless` | VLESS + REALITY | TCP 443 | 公司/公共 Wi-Fi 封锁 UDP 时手动切到它 |
| `DIRECT` | 直连 | — | 临时全局直连排障 |

## 装后运维管理（`vps-vpn` 命令）

安装脚本会自动部署 `/usr/local/bin/vps-vpn`：

```bash
sudo vps-vpn            # 打开交互式中文数字管理菜单
sudo vps-vpn status     # 查看服务、TCP/UDP 监听、端口跳跃 NAT、BBR、UDP 缓冲与 UFW 状态
sudo vps-vpn info       # 查看公网地址、端口、HY2 证书指纹与 scp 命令
sudo vps-vpn share      # 启动一次性临时分享（--port / --timeout / --downloads 可选）
sudo vps-vpn uri        # 输出 vless:// 与 hysteria2:// 单节点链接及二维码
sudo vps-vpn update     # 更新 sing-box 内核并校验重启
sudo vps-vpn rotate     # 备份并轮换 UUID、REALITY 密钥、HY2 密码与自签证书
sudo vps-vpn uninstall  # 停止服务并彻底清理配置、NAT 规则、含 vps-vpn 备注的 UFW 规则与状态
```

## 防火墙与云厂商安全组

- **本机 UFW**：若检测到 UFW 已启用，脚本自动放行 VLESS TCP、HY2 UDP 及端口跳跃 UDP 范围（均打上 `vps-vpn` 备注，绝不改动 SSH 或其他规则；卸载时仅删除带 `vps-vpn` 备注的规则）。
- **云厂商安全组**（AWS / Lightsail / GCP / 阿里云国际等必须在控制台放行）：
  - **SSH**：TCP 22（建议仅放行你自己的可信来源）
  - **VLESS + REALITY**：TCP `443`（或 `--port` 指定的端口）
  - **Hysteria 2**：UDP `20000-30000`（默认端口跳跃范围，只需 1 条范围规则）；若加了 `--no-port-hop`，则放行安装完成时打印的单个 HY2 UDP 端口

## 文件与权限

```text
/root/vps-vpn/
  ├─ state.env               # 凭据与配置状态（0600，目录 0700）
  ├─ client.yaml             # 主客户端配置（0600）
  └─ backups/                # 配置与凭据变更前备份（0700）

/etc/sing-box/
  ├─ config.json             # 服务端配置（0600，属主 sing-box）
  ├─ hy2.crt                 # HY2 自签证书（0644，属主 sing-box，CN 为真实伪装域名）
  └─ hy2.key                 # HY2 私钥（0600，属主 sing-box）

/etc/vps-vpn/port-hop.nft                  # nftables 独立端口跳跃表定义
/usr/local/libexec/vps-vpn-port-hop        # 端口跳跃 apply/clear 辅助脚本
/etc/systemd/system/vps-vpn-port-hop.service  # 端口跳跃开机持久化单元
/etc/sysctl.d/99-bbr.conf                  # BBR + FQ 配置
/etc/sysctl.d/99-vps-vpn-udp.conf          # 16MB UDP 缓冲区配置
/usr/local/bin/vps-vpn                     # 装后管理 CLI 与交互菜单
```

## 版本说明

脚本默认固定安装 **sing-box 1.14.4**，并在安装阶段校验已装版本必须 **≥ 1.11.0**（低于 1.11 的旧版如 1.10.0 存在 REALITY 拒绝全部合法连接的缺陷，脚本会自动升级）。

## 验证状态

- ✅ 静态语法检查（ShellCheck：覆盖 `install.sh`、内置 `vps-vpn` CLI 及 `vps-vpn-port-hop` 辅助脚本）
- ✅ 自动化单元与端到端测试（BATS）
- ✅ 真实二进制配置校验（`sing-box 1.14.4 check` 与 `mihomo 1.19.34 -t`，零警告零错误）
- ⏳ v2 真实 VPS（Ubuntu / Debian）部署及 Clash Verge / CMFA 实网验收（待你在 VPS 上实测确认）

## 许可证

MIT License
