# AsterNode 测试报告

- 报告日期：2026-10-03
- 管理器版本：0.2.0-dev
- 当前阶段：Stage A-D 功能代码与隔离自动化收尾完成；进入统一真实 VPS Gate 前的冻结基线
- 分支：`dev/stage-d-maintenance`
- Stage D 稳定功能基线：`489fb8ac94f8847d68ad4f46a27f9be04deb6ef0`
- GitHub Actions：#103，`success`
- 自动化：`27 passed / 0 failed / 0 skipped`
- Bash syntax：PASS
- ShellCheck：PASS
- 固定 Xray v26.3.27 服务端/客户端真实核心配置解析：PASS
- 生产凭据：未使用

## CI #103 结果

`dev/stage-d-maintenance` 的 GitHub Actions #103：

```text
unit-and-static     success
stage-b-real-xray   success

Summary: passed=27 failed=0 skipped=0
bash -n: PASS
shellcheck: PASS
Xray v26.3.27 server/client config parse: PASS
```

这说明当前仓库的隔离逻辑、静态检查和固定 Xray 配置解析形成了稳定自动化基线，但**不等于真实 VPS Gate 已通过**。真实 systemd 生命周期、远程 SSH、UFW 规则实际顺序、Fail2ban 日志消费、线路代理链、远程 bootstrap、更新/回退、磁盘与重启故障仍必须实测。

## Stage D 自动化证据

| case_id | 需求 | 自动化内容 | 结果 |
|---|---|---|---|
| D01 | UPDATE-01/03 | 签名发行 manifest、SHA256SUMS、公钥验证、文件集合/权限/大小/哈希、信任锚固定与不同密钥拒绝 | 通过（隔离/发行级） |
| D02 | UPDATE-02 | 固定版本 bootstrap、包/公钥 URL 与 SHA-256 固定、危险归档路径/类型拒绝 | 通过（隔离） |
| D03 | UPDATE-04/05 | 管理器发行包安装、同版本幂等、release smoke、current 链接切换与上一版本回退 | 通过（隔离） |
| D04 | UPDATE-06/07/08 | Xray 候选先验证后切换、服务状态保留、失败恢复、显式 rollback-core、本地离线 status/verify | 通过（隔离/配置级） |
| D05 | BACKUP-01/02/03 | 备份 ID/路径/权限/哈希/schema 校验、同机 machine-id 绑定、安全状态保留、跨机禁用导入 | 通过（隔离） |
| D06 | REMOVE-01/02/03 | 卸载前所有权/漂移预检、默认恢复点、受管对象精确删除、未知内容与系统安全设置保留 | 通过（隔离） |
| D07 | PERF-01/02/03 | 无常驻 manager daemon、受管增长统计、事务/备份/导出/证据/旧版本保守回收 | 通过（隔离） |
| D08 | TEST-01 | 全部 unit、Bash syntax、ShellCheck、固定 Xray 真实配置解析 | 通过 |

对应主要测试：

- `tests/test_stage_d_release.sh`
- `tests/test_stage_d_bootstrap.sh`
- `tests/test_stage_d_core_update.sh`
- `tests/test_stage_d_backup.sh`
- `tests/test_stage_d_remove.sh`
- `tests/test_stage_d_maintenance.sh`

## Stage B / C 真实 Gate 仍未替代

Stage D 收尾不会降低 Stage B/C 的真实门槛。

Stage B 仍需执行 `docs/STAGE_B_REAL_VPS_CHECKLIST.md`，包括真实 systemd、IPv4/双栈/IPv6-only/NAT、外部服务不接管、T24 客户端、T25 真实 3x-ui 完整代理链、UUID/REALITY 轮换与来源迁移。

Stage C 仍需执行 `docs/STAGE_C_REAL_VPS_CHECKLIST.md`，包括 SSH service/socket 与故障注入、Root/密码收紧、UFW 来源白名单真实对照、复杂防火墙边界、临时开放/重启以及 Fail2ban 实际封禁/解封。

## Stage D 真实 Gate

执行 `docs/STAGE_D_REAL_VPS_CHECKLIST.md`，重点验证：

1. 固定版本 bootstrap 在真实 HTTPS 发行链上的首次安装与首次信任记录。
2. 管理器升级、失败回滚、上一版本回退、离线 status/verify。
3. Xray 核心升级/失败恢复/显式回退，以及真实线路机兼容性。
4. 同机备份恢复不会覆盖当前 SSH/UFW/Fail2ban 与服务启停状态。
5. 跨机器恢复只导入禁用节点/线路机，必须人工复核后再启用。
6. 卸载不会误删外来文件或安全策略，重装不继承已删除节点的陈旧状态。
7. 低配 VPS 长时间运行的磁盘增长、oneshot 维护、重启 reconcile 与资源占用。
8. 包损坏、签名错误、空间不足、断电/kill 等故障注入后的恢复边界。

## 当前结论

**Stage A-D 的功能代码与隔离自动化开发已经收尾。** 当前稳定基线为 `489fb8a` / CI #103。下一步按照项目既定计划执行 B/C/D 三份 checklist 的统一真实 VPS 验收；在真实 Gate 全部通过之前，当前版本仍保持开发/预发布状态，不标记为生产稳定。

真实 Gate 完成后，再基于验收结果决定是否进入首个 `v1.0.0-rc` 发布候选流程。
