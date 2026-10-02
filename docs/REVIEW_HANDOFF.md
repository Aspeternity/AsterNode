# Stage A 审查交接

## 当前工作区

- 项目：Relay Manager
- 版本：0.1.0-dev
- 分支：`dev/stage-a-foundation`
- 远端：当前本地仓库未配置 remote
- 最终提交 SHA：以交付时 `git rev-parse HEAD` 为准（文件不自嵌 HEAD，避免提交 SHA 自引用）

## 本阶段目标

完成开发规格第 17 节的 A 基础：检测、状态模型、模块接口、修改/恢复框架和安装入口；门槛为只读检测、幂等、权限、锁和中断恢复测试通过。

## 关键入口

1. `lib/common.sh`：安全路径、临时文件、输入/IP/CIDR、TTY、退出码。
2. `lib/system.sh`：ENV-01/02 为主的只读体检，并提供 SSH/防火墙/外部进程上下文。
3. `lib/state.sh`：schema v1、root-only 目录、状态锁、原子状态更新与稳定 ID 唯一性。
4. `lib/transaction.sh`：事务状态机、flock、快照、staged SHA、应用前重检、原子替换、保守回滚和恢复。
5. `install.sh`：开发 source-tree 安装入口，重复安装幂等，post-install status 只读。
6. `tests/`：所有 Stage-A 隔离测试。

## 建议审查顺序

```text
common.sh
  -> system.sh
  -> state.sh
  -> transaction.sh
  -> install.sh / relay-manager.sh
  -> tests/
  -> docs/IMPLEMENTATION_MATRIX.md
```

重点审查：

- `tx_validate_destination` 对 RM_ROOT 逃逸、`..`、符号链接和受管路径 allowlist 的处理。
- kill-window：文件已替换但 `applied_sha256` 尚未写回时，恢复通过 `staged_sha256` 判断是否属于本事务。
- 外部漂移：回滚只覆盖 old/staged/applied 三种已知摘要，第三方内容保留并进入 `NEEDS_RECOVERY`。
- `state_update_filter` 在独立 state lock 下完成 schema/唯一性验证后原子替换。
- `env` / `status` 不创建状态目录；无 TTY 修改在进入业务逻辑前停止。

## 复现命令

```bash
./tests/run.sh
./relay-manager.sh env | jq .
./relay-manager.sh status | jq .
```

当前本地测试结果：`passed=11 failed=0 skipped=1`；skip 为本地 ShellCheck 不可用。远端 CI 配置会安装 ShellCheck 后执行同一 runner。

## 不应当验收为完成的内容

- `lib/node.sh`、`lib/core-xray.sh`、`lib/firewall.sh`、`lib/ssh.sh`、`lib/fail2ban.sh`、`lib/update.sh`、`lib/backup.sh` 等存在早期草稿代码，但 Stage B/C/D 尚未正式开发/验收完成。
- 没有真实 VPS 的 systemd/SSH/UFW/重启证据。
- 没有真实 3x-ui 线路端 T25 证据。
- 没有完整发行包/签名/回退 T27/T28 证据。

因此本次审查结论应只针对 Stage A 基础框架。
