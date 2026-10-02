# Relay Manager

Relay Manager 是面向 Debian / Ubuntu 落地 VPS 的轻量 Bash 管理器。目标是不安装网页面板、不引入数据库或自有常驻守护进程，通过可审计状态、事务和模块边界管理 Xray 节点、安全组件、线路机凭据与维护操作。

> 当前版本：`0.2.0-dev`，**阶段 B（节点）开发中**。阶段 A 基础门槛已通过；阶段 B 已具备自动化/配置级证据，但真实 systemd VPS、IPv4/IPv6 网络形态和 3x-ui 线路端 T24/T25 尚未完成，因此当前仍不是生产发布版。

## 当前进展

阶段 A 已建立只读环境体检、root 专有状态、事务/回滚/恢复、非 TTY 修改保护、协议接口和隔离测试框架。

阶段 B 当前已经加入：

- 固定兼容矩阵的 Xray 核心下载、SHA-256/大小校验和受管版本目录。
- 专用 `rm-xray` 无登录用户、独立 `relay-manager-xray.service` 和维护 timer。
- VLESS + RAW/TCP + REALITY，默认 `xtls-rprx-vision`；UUID、X25519 与 Short ID 本机生成。
- 多节点/多线路机状态、独立 UUID、共享来源引用、启停/删除与限时并行 UUID 轮换。
- 受管配置生成前校验、真实固定 Xray `run -test` CI 检查、运行用户权限检查和端口冲突保护。
- 外部手工修改运行配置的摘要漂移检测：发现漂移后拒绝静默覆盖。
- 参数表、分享 URI、单个 outbound JSON 与 3x-ui 字段/路由合并说明；服务端 privateKey 不导出。
- Target 候选与受控探测，以及 D1-D4 分层诊断框架。
- 线路来源地址采用 `source-add → 实际验证 → source-remove` 的迁移模型，避免直接整组替换。
- 纯元数据/来源状态更新不再无意义重启 Xray，同时将受管配置摘要纳入事务观察，发现外部漂移立即停止。

`dev/stage-b-node-continuation` 当前稳定基线的 CI 同时运行隔离单元/静态检查和固定 Xray v26.3.27 的服务端、客户端配置测试。CI #59 在提交 `0a5be45a` 上得到 `18 passed / 0 failed / 0 skipped`，ShellCheck 与真实 Xray 配置解析均通过。配置测试通过不等于线路 VPS 的真实认证和代理请求已经通过。

## 只读使用

在源码目录直接运行：

```bash
./relay-manager.sh env
./relay-manager.sh status
./relay-manager.sh doctor
./relay-manager.sh help
```

Target 候选列表本身不联网；主动探测才会联网：

```bash
./relay-manager.sh target candidates
./relay-manager.sh target probe TARGET SNI
```

## 开发安装入口

当前仅用于开发/专用测试 VPS：

```bash
sudo ./install.sh --install-source
```

正式远程 bootstrap、发行包签名、公钥轮换、完整更新回退与生产发布属于阶段 D。在这些门槛完成前，不应把当前 source-tree 安装入口当作正式分发方式。

## 测试

```bash
./tests/run.sh
```

测试通过 `RM_ROOT` 将受管绝对路径重定向到临时目录，避免对开发机的 `/etc`、`/run`、`/var/lib`、SSH、防火墙或 systemd 服务执行集成修改。CI 另用固定摘要下载 Xray v26.3.27 并对生成的服务端/客户端配置执行真实核心解析测试。

仍必须在可恢复 VM / 专用 VPS 完成：真实 systemd 服务生命周期、IPv4/双栈/IPv6-only、NAT、外部 Xray 冲突、来源限制，以及至少一台真实 3x-ui 线路 VPS 的 REALITY 认证、代理请求和落地出口确认。

## 目录

```text
install.sh                 安装入口
relay-manager.sh           菜单与 CLI 路由
lib/common.sh              公共安全/输入/文件辅助
lib/system.sh              只读环境检测
lib/state.sh               受管状态与 schema
lib/transaction.sh         锁、快照、应用、回滚、恢复
lib/core-xray.sh           固定版本核心与受管 systemd 服务
lib/node.sh                节点/线路机生命周期
lib/export.sh              线路机参数与配置导出
lib/target.sh              REALITY Target 探测
protocols/                 协议模块
compat/                    版本/Target 兼容数据
templates/                 systemd 等版本化模板
tests/                     隔离单元测试
docs/                      需求矩阵、测试报告和审查交接
```

## 安全边界

- 不 `eval` 用户输入，不 `source` JSON。
- 事务只允许写入明确受管路径，并拒绝路径穿越、危险符号链接和非常规目标文件。
- 状态、事务、快照、导出与秘密使用受限权限。
- 不接管已运行的外部 Xray；不通过杀进程解决端口冲突。
- 节点没有启用线路机凭据时拒绝形成无认证/开放代理。
- 默认诊断和列表不打印完整 UUID、REALITY 密钥或分享 URI。
- Target 探测不会自动选择目标、修改节点或开放额外端口。
- 阶段 B 的自动化通过不能替代真实线路 VPS T24/T25 证据。

## 开发顺序

1. **A 基础**：检测、状态模型、模块接口、事务与恢复、安装入口。
2. **B 节点**：Xray、VLESS + RAW/TCP + REALITY、线路机、导出、Target、基础诊断。**当前阶段**
3. **C 安全**：UFW、SSH 公钥/迁移/保护、Fail2ban。
4. **D 维护**：更新回退、备份恢复、卸载、发行包与完整兼容矩阵。

需求逐项状态与未验证边界见 `docs/IMPLEMENTATION_MATRIX.md` 和 `docs/TEST_REPORT.md`。
