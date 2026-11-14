# VPS 一键部署 VLESS REALITY 设计规格

- 日期：2026-11-14
- 状态：待用户审阅
- 项目阶段：新仓库，设计阶段；不包含部署功能实现

## 1. 目标与使用场景

为个人用户提供面向 Ubuntu VPS 的一键部署工具：通过一条 SSH 会话中的命令安装并启动 VLESS + REALITY 代理，自动生成可由 Clash Verge（电脑）与 CMFA（Android）导入的本地 YAML 配置。

主要用途包括 Claude、Codex、其他模型服务、Google、YouTube、在线素材下载及视频/PPT 制作相关的联网访问。默认采用全局代理，使普通应用流量使用同一 VPS 出口，减少分流规则遗漏导致的直连。

项目首次实现不包含真实 VPS 验收。开发完成后由用户购买新的 VPS，再按照文档安装并测试；实际网络或客户端问题依据真实日志和环境修复。不得把尚未执行的 VPS、Clash Verge 或 CMFA 测试标为通过。

## 2. 已确认需求与约束

- 新 VPS 使用 Ubuntu 22.04 或 24.04，普通公网 IPv4 KVM VPS；支持 amd64 与 arm64。
- 无自有域名；服务地址为自动识别的 VPS 公网 IPv4。
- 用户不要求也不能依赖现有 AWS 实例进行协议或 UDP 测试。
- 首版只部署 VLESS + REALITY，不部署 Hysteria 2。后者仅在实际速度或连通性问题证明有必要时另行设计和测试。
- 客户端为 Clash Verge 与 CMFA，均使用同一份 Mihomo 兼容 YAML。
- 默认全局代理，局域网直连；电脑使用 Clash Verge TUN 模式，手机使用 CMFA 的 Android VPN 模式。
- 不自动切换节点或出口。单 VPS 单节点，不支持多用户或设备独立凭据。
- 一条命令运行安装程序，公网 IP 默认自动识别，无须填写参数。
- 支持 root 执行，也支持 AWS 默认的 `ubuntu` 用户通过 `sudo` 执行。不要求 root 密码，不开启 root 密码 SSH 登录，不修改 SSH 配置。
- 部署完成后立即启动服务，不自动或强制重启 VPS。
- 项目可上传 GitHub；任何真实凭据、客户端配置及 VPS 地址不得进入仓库。

## 3. 非目标

首版不实现以下功能：

- Hysteria 2、UDP 性能探测、双协议或自动协议选择；
- Web 管理面板、用户管理、流量统计、计费或费用限制；
- 域名注册、DNS 配置、ACME 证书申请或续期；
- 公网 HTTP/HTTPS 订阅服务、二维码服务；
- 云厂商 API 集成、自动购买 VPS 或修改安全组；
- 自动迁移旧 VPS 数据、固定云平台公网 IP 或多 VPS 负载均衡；
- 承诺绕过平台风控、保证账号安全、保证流媒体或模型平台可用；
- 自动更新系统、内核升级或自动重启服务器。

## 4. 方案比较与决定

### 4.1 选定：Bash + sing-box + VLESS REALITY

一个 Bash 入口脚本安装指定版本的官方 sing-box 包，通过其 systemd 服务运行 VLESS + REALITY。REALITY 不需要用户拥有域名或申请站点证书；Mihomo 客户端具有 `reality-opts` 配置接口。

选择原因：无需域名；TCP 线路不依赖 UDP/QUIC 的中间网络支持；适合网页、模型 API 与通用 HTTPS 流量；实现和排错范围最小。

### 4.2 暂缓：Hysteria 2 或双协议

Hysteria 2 基于 UDP/QUIC，可能在高延迟、丢包链路上提供更好吞吐，但实际结果依赖用户本地网络至新 VPS 的链路。无域名部署还需要自签名证书与指纹管理。当前没有可测试的新 VPS，故不在首版增加该复杂度。

如果未来实测需要，双协议应固定在同一 VPS 出口 IP 并允许手动选择，不自动切换；届时另行设计证书、端口及测试方案。

### 4.3 排除：Docker Compose、多服务管理、传统 VPN 客户端

单服务不需要 Docker 或 Compose。WireGuard/OpenVPN 虽然可提供传统 VPN，但不能直接满足既定 Clash Verge/CMFA YAML 导入方式。

## 5. 系统架构

```text
GitHub 仓库
  └─ install.sh
       ├─ 验证执行环境、参数、架构与端口
       ├─ 自动识别公网 IPv4
       ├─ 获取指定版本的官方 sing-box 包
       ├─ 生成或复用 UUID、REALITY 密钥对、short ID
       ├─ 安全写入服务端配置
       ├─ sing-box check 校验后启动 systemd 服务
       ├─ 生成并校验 Mihomo 客户端 YAML
       └─ 输出实际可用的下载与导入说明

VPS：VLESS REALITY over TCP（默认 443）
  └─ sing-box systemd service

客户端：同一 client.yaml
  ├─ Windows：Clash Verge + TUN
  └─ Android：CMFA + VPN
```

不运行公网配置下载服务。服务端 REALITY 私钥仅用于服务端配置，不进入客户端 YAML。

## 6. 安装与执行接口

安装命令的最终仓库地址在 GitHub 仓库确定后写入 README，格式为：

```bash
curl -fsSL https://raw.githubusercontent.com/<账号>/<仓库>/main/install.sh | sudo bash
```

首版安装命令默认无参数。可选参数只包括：

- `--ip <IPv4>`：公网 IP 自动识别失败或特殊网络环境的人工修正；正常部署不需要。
- `--port <TCP端口>`：默认 443 已被占用或需要变更时显式指定；正常部署不需要。
- `--help`：显示用法，不修改系统。

不设计凭据、端口或 REALITY 目标的一长串环境变量接口；避免无需求的配置面。

### 6.1 权限与普通用户支持

脚本可以由 root 直接运行，也可由具有免密或交互式 sudo 权限的用户通过 `sudo` 运行。脚本需要记录 `SUDO_USER` 对应的实际用户、用户 ID、组 ID 和 home 目录，并用系统工具校验，而不是拼接不可信路径。

AWS Ubuntu 的典型登录方式为：

```bash
ssh -i /path/to/key.pem ubuntu@<VPS公网IPv4>
```

安装不要求改变该方式。由于 `curl | sudo bash` 的标准输入被脚本占用，需要 sudo 交互输入密码时应在执行前先完成 `sudo -v`，或在 README 中给出对应的明确用法；不能宣称所有 sudo 配置都能无交互执行。

### 6.2 公网 IPv4 识别

1. 使用 HTTPS 查询至少两个不同的公网 IP 服务，设置连接与总超时。
2. 响应必须严格为合法的全局单播 IPv4；拒绝私网、回环、链路本地、保留地址及包含额外文本的响应。
3. 两个结果一致时采用；只有一个成功时，可以采用该值并在安装总结中提示核验。
4. 结果不一致或全部失败时，退出并提示使用 `--ip` 显式指定；不能猜测地址。
5. 自动识别表示 VPS 出口地址，不证明该地址可从公网入站访问。NAT、端口转发或特殊 VPC 环境不在自动支持范围内。

## 7. 软件安装与供应完整性

- 使用 sing-box 官方包安装入口的指定版本能力，版本在脚本中固定并经实现阶段验证，不默认安装最新版本或 beta。
- 安装依赖只包含运行所需的系统工具，例如 `curl`、`ca-certificates`；不安装无关开发环境。
- 下载及执行前检查失败必须中止；使用 `set -Eeuo pipefail`、安全临时目录与退出清理。
- 不将来自网上的第三方辅助脚本未经审阅直接引入项目。官方安装方式与来源写入 README。
- 如果官方安装包自带 systemd 单元满足权限与配置要求，复用它；仅当不能满足时提供最小单元调整，不维护重复的服务框架。
- 端口被占用时停止，不终止现有进程，不覆盖与本项目无关的服务配置。

## 8. 配置、凭据与文件布局

私密状态和主客户端文件：

```text
/root/vps-vpn/
  ├─ state.env
  ├─ client.yaml
  └─ backups/
```

- `/root/vps-vpn` 权限为 `0700`；`state.env` 与主 `client.yaml` 权限为 `0600`。
- `state.env` 仅保存脚本可安全读取的受控键值，包括 UUID、REALITY 私钥、公钥、short ID、端口、公网 IPv4 和配置格式版本。读取时校验键名、值格式和重复键，不能 `source` 不可信内容或执行其中代码。
- 客户端 YAML 包含 UUID、REALITY 公钥和 short ID，属于敏感文件；绝不包含 REALITY 私钥。
- 首次执行生成凭据。再次执行必须验证并复用已有凭据与端口；如果用户显式更改地址或端口，只更新对应配置。
- 首版不提供自动轮换命令。凭据泄漏时，文档提供维护窗口内的手工轮换步骤：备份后删除本项目的 `state.env`，重新运行安装以生成新凭据，并替换所有客户端配置；脚本不得因普通重复执行而删除状态或轮换凭据。

通用用户下载副本（自动检测当前用户）：

```text
/home/<SUDO_USER>/vps-vpn/client.yaml
```

脚本通过 `SUDO_USER` 环境变量自动识别执行安装的实际用户（如 `ubuntu`、`debian`、`root` 等），并将客户端 YAML 复制到该用户的 home 目录。如果直接以 `root` 登录运行，则不生成非 root 副本，只保留 `/root/vps-vpn/` 下的主文件。

下载示例（根据检测到的用户名动态生成）：

```bash
scp <SUDO_USER>@<VPS公网IPv4>:/home/<SUDO_USER>/vps-vpn/client.yaml .
```

或任何允许 sudo 的用户（通用形式）：

```bash
ssh <SUDO_USER>@<VPS公网IPv4> \
  'sudo cat /root/vps-vpn/client.yaml' > client.yaml
```

文档提示通过安全、可信的本地文件传输将该文件提供给 Android 手机；不创建公开下载链接。

## 9. 服务端与客户端配置

### 9.1 服务端

- 一个 VLESS 入站，监听 TCP 443 或显式指定端口。
- 一个用户 UUID；启用 `xtls-rprx-vision` 与 REALITY。
- REALITY 的 `private_key`、`short_id` 和握手目标由受控状态或明确常量生成。
- 仅配置实际需要的默认出口；不开放额外 HTTP/SOCKS 入站、公网 API 或订阅端口。
- 使用固定、文档列出的公开 TLS 握手目标，不自动扫描或遍历第三方站点。安装前验证目标的 TLS 连通性；失败时给出配置或网络诊断，不盲目启动无效配置。
- 所选 sing-box 版本的实际字段、输出格式和 Mihomo 互操作性必须在实现阶段用固定版本验证，不能仅复制未经验证的示例。

### 9.2 客户端

同一 YAML 适用于 Clash Verge 与 CMFA 的 Mihomo 核心：

- 节点地址使用自动识别或显式指定的 IPv4。
- `type: vless`、`network: tcp`、`flow: xtls-rprx-vision`、`tls: true`、REALITY 公钥和 short ID。
- 使用服务端 REALITY 握手目标对应的 `servername`，不是 VPS 自有域名。
- 仅使用 Mihomo 已验证支持的字段；不设置 `skip-cert-verify: true` 来代替 REALITY 配置。
- 本地 mixed 端口仅绑定回环地址，避免向局域网暴露无认证代理。
- 使用 `Global` 策略组及单一固定节点；默认规则全局走代理，局域网与必要的本地地址保持直连。
- 配置 DNS 代理解析，目标是避免普通域名 DNS 请求绕过代理；客户端配置校验与真实验收分别验证配置语法和实际行为。
- YAML 由受控模板生成，所有动态值经过严格验证，防止错误引号、YAML 注入或格式错误。

## 10. 防火墙与云厂商边界

- 首版不自动修改 UFW、nftables、云安全组或其他已有防火墙配置，以免切断 SSH 或现有服务。
- README 明确说明：用户需在云厂商控制台允许来自可信来源的 SSH，以及代理所用的 TCP 端口；其他无关公网端口保持关闭。
- 若检测到本机防火墙可能导致端口不可达，安装程序给出警告和检查方法，不擅自开放全部流量。
- 脚本无法证明云安全组已放行端口，因此服务端启动与客户端公网可达性分开报告。
- 对 AWS 的建议包括按需使用 Elastic IP、注意公网 IP 变化及出站流量费用，但项目不管理 AWS 资源或费用。

## 11. 原子性、错误处理与日志

1. 修改现有文件前完成环境、权限、参数、IP、端口和下载检查。
2. 新建文件使用安全临时文件，设置权限后再原子替换；中断时不留下可执行但内容不完整的配置。
3. 已存在本项目服务时，更新前备份原服务端配置与状态；备份同样只允许 root 读取。
4. 候选配置通过 `sing-box check` 后才能重启服务。失败时保留现有运行服务与旧客户端配置。
5. 新服务启动失败时恢复备份，并输出 `systemctl status sing-box` 与 `journalctl -u sing-box` 的排错提示。
6. 成功时检查 systemd active 状态及实际 TCP 监听。监听成功只代表服务就绪，不宣称公网或客户端已连通。
7. 正常输出不包含 UUID、私钥、公钥、完整 YAML 或密钥下载 URL。输出公网 IP、端口、文件路径、服务状态和下载模板。
8. 不自动重启 VPS，不升级内核，不执行全系统更新。
9. `systemctl enable --now sing-box` 实现立即启动及未来开机启动；重启后验证是可选手工验收，不是部署步骤。

## 12. 测试策略与验证边界

### 12.1 开发阶段可执行

- 使用测试替身隔离网络、软件包安装、systemd 与密钥生成，测试 Bash 的控制流和文件行为；测试不接触真实 VPS 或用户现有服务器。
- ShellCheck 静态检查。
- 无效输入：错误 IP/端口、非全局 IPv4、重复参数、缺失权限、不支持的系统或架构。
- 公网 IP 查询：两个成功且一致、单个成功、全部失败、结果冲突、超时、非法响应。
- 状态处理：首次生成、重复执行复用、损坏状态拒绝执行、私钥不进入客户端 YAML。
- 端口占用、安装下载失败、配置校验失败、服务启动失败与备份恢复。
- root 与 sudo 普通用户下的文件所有者、权限、home 路径处理。
- 重复执行不产生不必要的凭据变化或重复服务配置。
- 使用固定版本 sing-box 对生成的服务端配置执行 `check`。
- 在实现阶段获取指定 Mihomo 版本，使用其真实配置检查能力验证生成的客户端 YAML；不依赖自写 YAML 文本检查代替真实兼容性验证。
- 仓库扫描确保不含真实私钥、UUID、客户端配置、VPS 地址或 SSH 私钥。
- CI 执行可自动化检查。涉及 systemd 的逻辑可使用隔离测试环境，但不能据此声称完整 VPS 部署成功。

### 12.2 用户购买 VPS 后验收

- 在新 Ubuntu VPS 上通过 `ubuntu` 用户与 SSH 私钥执行免参数命令。
- 确认自动识别 IP、配置生成、systemd 启动与文件权限。
- 下载 YAML 并导入实际 Clash Verge，启用 TUN，验证出口 IP、DNS、Google、YouTube 与一般 HTTPS 网站。
- 将同一 YAML 导入实际 CMFA，验证 Android VPN、出口 IP 与网站访问。
- 验证重连、再次执行安装后的配置可用性，以及敏感信息未泄漏到公开仓库。
- 可选地手工重启 VPS，确认开机自启；此项不属于安装必须步骤。
- 记录 VPS 地区、Ubuntu 版本、sing-box 版本、Mihomo/客户端版本与真实结果，出现问题时依据日志修复。

## 13. 项目文件与文档

```text
install.sh
README.md
LICENSE
.gitignore
.github/workflows/ci.yml
tests/
docs/superpowers/specs/2026-11-14-vps-vpn-design.md
docs/superpowers/plans/
```

README 使用中文，至少包含：

- 支持范围与限制；
- VPS 选购、网络流量与安全组提示；
- 无参数一键安装与可选参数；
- AWS `ubuntu + sudo` 使用方式；
- 电脑与手机导入步骤；
- 服务管理、日志、重复安装、文件权限与敏感信息保管；
- 已自动验证项目与仍需真实 VPS 验证项目的明确区分。

代码、标识符和提交信息遵循仓库的英文惯例；需求、设计、计划与使用文档使用中文。公开仓库采用 MIT License，实际版权人名称在实现阶段按 GitHub 账号信息填写。

## 14. 完成定义

开发阶段完成要求：实现脚本与文档；所有可离线自动测试通过；固定版本服务端和客户端配置经过真实二进制校验；最终 diff 经审查；未宣称真实 VPS、Clash Verge 或 CMFA 已验证。

整个功能验收完成还要求用户购买 VPS 后成功完成第 12.2 节的真实部署与客户端测试。首版不提前加入 Hysteria 2、订阅服务、管理面板或自动云资源配置。

## 15. 官方技术参考

- sing-box 包安装：https://sing-box.sagernet.org/installation/package-manager/
- sing-box VLESS 入站：https://sing-box.sagernet.org/configuration/inbound/vless/
- sing-box TLS / REALITY：https://sing-box.sagernet.org/configuration/shared/tls/
- Mihomo VLESS：https://wiki.metacubex.one/config/proxies/vless/
- Mihomo TLS / REALITY：https://wiki.metacubex.one/config/proxies/tls/
- REALITY 说明：https://xtls.github.io/en/config/transports/reality.html
- Hysteria 2 拥塞控制（仅用于未来比较）：https://v2.hysteria.network/docs/advanced/Full-Server-Config/#congestion
- AWS 安全组：https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
