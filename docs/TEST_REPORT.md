# AsterNode 测试报告

- 报告日期：2026-10-06
- 管理器版本：0.2.0-dev
- 当前阶段：Stage A-D 功能代码与隔离自动化收尾；关键真实 VPS 路径已部分通过，进入 release-prep 与剩余 Gate 收口
- 分支：`dev/stage-d-maintenance`
- 当前冻结基线：`e532bb0928cd465dc356c45394aebb02270e1bab`
- GitHub Actions：#212，`success`
- 自动化：`33 passed / 0 failed / 0 skipped`
- Bash syntax：PASS
- ShellCheck：PASS
- 固定 Xray v26.3.27 服务端/客户端真实核心配置解析：PASS
- 生产凭据：未写入报告

## CI #212 结果

`dev/stage-d-maintenance` 的 GitHub Actions #212：

```text
unit-and-static     success
stage-b-real-xray   success

Summary: passed=33 failed=0 skipped=0
bash -n: PASS
shellcheck: PASS
Xray v26.3.27 server/client config parse: PASS
```

自动化基线已经稳定，但不能替代尚未覆盖的真实系统/网络/发行路径。

## 已确认的真实 VPS 证据

- **T25：PASS**。真实 3x-ui 线路机 → AsterNode 落地 Xray 的 VLESS + RAW/TCP + REALITY 全链路已完成认证、代理请求与落地出口确认。
- **SSH recovery：PASS（已覆盖关键故障路径）**。Ubuntu 24.04 `ssh.socket` 场景完成实际入口验证，并覆盖事务恢复、超时/回滚与 SIGKILL 中断窗口；恢复后基线入口可用且无非终态事务。
- **UFW 白名单/临时公网开放：PASS（已覆盖关键路径）**。空白名单真实外部对照确认节点端口被拒绝；临时开放期间外部 TCP 可达，到期恢复 managed DENY；维护 reconciler 缺失时 fail-closed；COMMITTED + ARMED crash window 可由全局 maintenance timer 清理。
- **Xray service lifecycle：PASS**。最后一个启用节点被禁用、重新启用、最后节点删除均在真实 VPS 验证；最终为 `inactive + disabled`，无 443/测试端口监听、无非终态事务。
- **验收环境收尾：PASS**。节点、线路、temporary opens 清空；UFW 仅保留受管 SSH 入口；maintenance timer 保持 active + enabled。

## 尚未闭环的发布阻断项

- Fail2ban 的真实攻击触发、封禁、解封。
- Stage D D-VPS-01～09 中尚未逐项形成真实证据的固定 HTTPS bootstrap、manager/core 更新与回退、同机/跨机恢复、卸载/重装、长期资源增长和中断/磁盘故障注入。
- ARM64 实机；以及当前承诺范围内尚未覆盖的 Debian/Ubuntu、IPv4/双栈/IPv6-only/NAT 组合。
- 正式发布资产 URL、签名密钥运维与首个 RC 的最终 VERSION/tag/release 流程。

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

Stage B 已取得 T25 真实 3x-ui 完整代理链证据；其余未覆盖的 systemd/网络矩阵、外部服务不接管、T24 独立客户端记录、轮换与来源迁移仍按 checklist 补齐，不把单一已验收组合外推到全部环境。

Stage C 的 SSH socket/故障恢复、UFW 来源对照与临时开放 crash-recovery 已有关键实机证据；Fail2ban 实际封禁/解封以及 checklist 中未覆盖的发行版/复杂防火墙组合仍需补齐。

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

**Stage A-D 的功能代码与隔离自动化开发已经收尾，关键真实 VPS 路径已部分通过。** 当前冻结基线为 `e532bb0` / CI #212。下一步只做 release-prep 与剩余真实 Gate 收口；在发布阻断项全部关闭之前，`VERSION` 保持 `0.2.0-dev`，不标记为生产稳定。

剩余 Gate 全部完成后，再以单独版本提交切换到首个计划候选 `1.0.0-rc.1`。
