# AsterNode Release Readiness

> 更新：2026-10-06。本文只记录当前发布判定，不替代 B/C/D 三份详细真实 VPS checklist。

## 冻结基线

- 分支：`dev/stage-d-maintenance`
- Commit：`e532bb0928cd465dc356c45394aebb02270e1bab`
- VERSION：`0.2.0-dev`
- CI：#212，success
- Unit/static：33 passed / 0 failed / 0 skipped
- Bash syntax：PASS
- ShellCheck：PASS
- 固定 Xray v26.3.27 服务端/客户端真实核心配置解析：PASS

## 已通过的关键真实路径

- T25：真实 3x-ui 线路机 → 落地 Xray 全链路 PASS。
- SSH：Ubuntu 24.04 `ssh.socket` 场景、入口验证、事务/回滚及关键 SIGKILL crash-recovery PASS。
- UFW：默认拒绝、空白名单外部对照、临时公网开放正常到期、durable reconciler fail-closed 与 COMMITTED + ARMED crash window PASS。
- Xray service lifecycle：最后启用节点 disable → `inactive + disabled`；重新 enable → `active + enabled`；最后节点 delete → `inactive + disabled` PASS。
- 验收环境清理：nodes/upstreams/temporary_opens 为空，443/临时端口无监听，UFW 仅保留 SSH，maintenance timer active + enabled，无非终态事务。

这些结果证明对应路径在已记录环境中通过，不代表所有发行版、架构、云网络或面板版本均已验证。

## 发布阻断项

- [ ] Fail2ban 真实攻击触发、封禁、解封。
- [ ] D-VPS-01 固定 HTTPS bootstrap / 首次信任。
- [ ] D-VPS-02 manager 升级 / 回退。
- [ ] D-VPS-03 Xray 核心升级 / 失败恢复 / 显式回退。
- [ ] D-VPS-04 同机备份 / 恢复。
- [ ] D-VPS-05 跨机器禁用恢复。
- [ ] D-VPS-06 所有权范围卸载 / 重装。
- [ ] D-VPS-07 低资源 / 长期增长。
- [ ] D-VPS-08 重启 / reconcile 的完整场景。
- [ ] D-VPS-09 磁盘 / 中断故障注入。
- [ ] D-VPS-10 当前承诺范围的系统/架构矩阵，至少补 ARM64。
- [ ] 正式固定 bootstrap HTTPS URL 与 release assets 位置。
- [ ] 发行签名私钥保管/轮换流程。
- [ ] License 决策。
- [ ] 清理/关闭已被当前 dev 基线取代的旧 PR 与历史修复分支。

## 版本契约

当前不提前修改 `VERSION`。发行构建器要求所选 commit 的 `VERSION` 与 `--version` 完全一致，因此版本号必须和最终 RC commit 原子绑定。

计划流程：

1. 继续保持 `0.2.0-dev` 完成剩余发布阻断项。
2. 最终 Gate 通过后创建单独 release-candidate 分支。
3. 在同一提交中把 `VERSION` 切换为计划的 `1.0.0-rc.1`，同步 CHANGELOG/README。
4. 完整 CI + release smoke + 最终真实 smoke 全绿。
5. 经明确授权后合入 `main`。
6. 从 `main` 的确定 commit 构建签名 package/bootstrap，创建 tag 与 GitHub prerelease。

在以上条件完成前，不发布 production/stable，也不把 `main` 当作已发布基线。
