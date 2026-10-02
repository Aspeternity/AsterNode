# Relay Manager

Relay Manager 是面向 Debian / Ubuntu 落地 VPS 的轻量 Bash 管理器。项目目标是：不安装网页面板、不引入数据库或自有常驻守护进程，通过可审计的状态、事务和模块边界管理 Xray 节点、安全组件、线路机凭据与维护操作。

> 当前版本：`0.1.0-dev`，**阶段 A（基础）开发版**。阶段 B/C/D 的源码中存在早期草稿，但在对应阶段完成测试与实机证据之前，一律不视为已实现或可用于生产。

## 当前阶段 A 已完成

- 启动环境只读体检：发行版、架构、systemd、权限、CPU、内存、磁盘、inode、包管理锁、地址、默认路由、监听端口、SSH 上下文、防火墙痕迹与外部进程。
- root 专有状态模型：节点、线路机、来源地址、所有权和临时状态分离；状态文件具备 schema 与唯一性检查。
- 公共事务框架：锁、快照、候选文件、应用前重检、原子替换、提交、回滚、外部漂移保护和未完成事务恢复。
- 非 TTY 修改保护、统一退出码和协议模块接口契约。
- 开发安装入口及隔离测试模式 `RM_ROOT` / `RM_TEST_MODE`。
- 自动化单元测试、Bash 语法检查和 GitHub Actions ShellCheck 入口。

阶段 A 的门槛与测试证据见 `docs/TEST_REPORT.md`；需求逐项状态见 `docs/IMPLEMENTATION_MATRIX.md`。

## 只读使用

在源码目录直接运行，不会安装依赖或修改系统：

```bash
./relay-manager.sh env
./relay-manager.sh status
./relay-manager.sh help
```

`env` 可选指定 SSH 有效配置上下文：

```bash
./relay-manager.sh env root 198.51.100.10
```

这里的 SSH 检测会明确区分“允许公钥认证”“发现授权密钥文件”和“登录已验证”。没有可靠证据时保持 `unverified` / `false`，不会把文件存在当成实际登录成功。

## 开发安装入口

当前阶段仅用于开发和隔离验证：

```bash
sudo ./install.sh --install-source
```

重复运行同一版本不会创建第二份版本目录，也不会因为 post-install `status` 创建运行状态。正式远程 bootstrap、发行包签名、公钥轮换和版本回退属于阶段 D，在完成前不要将当前开发安装入口当作生产发布方式。

## 测试

```bash
./tests/run.sh
```

测试通过 `RM_ROOT` 将受管绝对路径重定向到临时目录，避免对开发机的 `/etc`、`/run`、`/var/lib`、SSH、防火墙或 systemd 服务执行集成修改。真实 systemd、SSH socket、UFW、IPv6-only、重启和 3x-ui 线路测试必须在可恢复 VM 或专用测试 VPS 上完成。

## 目录

```text
install.sh                 安装入口
relay-manager.sh           菜单与 CLI 路由
lib/common.sh              公共安全/输入/文件辅助
lib/system.sh              只读环境检测
lib/state.sh               受管状态与 schema
lib/transaction.sh         锁、快照、应用、回滚、恢复
protocols/                 协议模块
compat/                    版本/Target 兼容数据
templates/                 systemd 等版本化模板
tests/                     隔离单元测试
docs/                      需求矩阵、测试报告和审查交接
```

## 安全边界

- 不 `eval` 用户输入，不 `source` JSON。
- 事务只允许写入明确受管路径，并拒绝路径穿越、危险符号链接和非常规目标文件。
- 状态、事务、快照和秘密默认放在 root 专有目录中。
- 环境体检不安装包、不启动服务、不修改配置。
- 对外地址探测是单独联网操作；快速本机检测不会因为联网失败把系统判为不支持。
- 阶段 A **没有**完成真实 VPS 的 SSH/UFW/Xray/3x-ui 端到端验收。

## 开发顺序

1. **A 基础**：检测、状态模型、模块接口、事务与恢复、安装入口。
2. **B 节点**：Xray、VLESS + RAW/TCP + REALITY、线路机、导出、Target、基础诊断。
3. **C 安全**：UFW、SSH 公钥/迁移/保护、Fail2ban。
4. **D 维护**：更新回退、备份恢复、卸载、发行包与完整兼容矩阵。

当前只对阶段 A 给出通过结论。后续阶段必须继续遵循开发规格的真实环境证据要求。
