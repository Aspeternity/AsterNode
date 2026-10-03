# Stage D 审查交接

## 当前基线

- 项目仓库：`Aspeternity/AsterNode`
- 管理器版本：`0.2.0-dev`
- 分支：`dev/stage-d-maintenance`
- Stage D 稳定功能基线：`489fb8ac94f8847d68ad4f46a27f9be04deb6ef0`
- GitHub Actions：#103，`success`
- 自动化：`27 passed / 0 failed / 0 skipped`
- Bash syntax：PASS
- ShellCheck：PASS
- 固定 Xray v26.3.27 服务端/客户端真实核心配置解析：PASS

> Stage A-D 的功能代码与隔离自动化已收尾。真实 VPS Gate 尚未执行，不能把当前状态描述为生产环境最终通过。未经用户明确授权，不合并到 `main`。

## Stage D 已实现

### 发行与 bootstrap

1. 管理器发行包包含签名 `SHA256SUMS`、`MANIFEST.json` 与版本化文件清单。
2. 安装前检查外层包固定 SHA-256、签名、公钥、文件集合、大小、权限、内容哈希和危险归档条目。
3. 固定版本 bootstrap 同时固定发行版本、包 URL/哈希、公钥 URL/哈希，不跟随 `main` 或 `latest`。
4. 首次远程 bootstrap 的 HTTPS 自身信任边界被明确记录，不宣称脚本能在下载前验证自己。
5. 已固定的受信公钥不会被不同公钥静默替换。

### 管理器 / Xray 更新与回退

1. 管理器更新安装到版本目录，release smoke 通过后原子切换 `current`；同版本重装保持幂等。
2. 管理器回退只接受状态记录的上一受管版本，并重新验证发行完整性与 smoke。
3. Xray 更新先准备候选，不先改 `current`；使用现有运行配置验证候选核心。
4. 切换核心时保留原 service enabled/active 状态；切换后失败自动恢复旧核心。
5. 显式 `update rollback-core BACKUP_ID` 使用升级恢复点恢复旧核心。
6. `update status` / `verify-manager` 默认只读，不因离线失败而阻断本地检查，也不会在启动时隐式联网更新。

### 备份 / 恢复

1. 恢复点使用严格 ID、路径白名单、普通文件类型、0700/0600 权限、SHA-256 和 state schema 校验。
2. 同机恢复使用 machine-id 指纹约束，不原样覆盖旧 state；只恢复节点/线路数据并由当前管理器/核心重新生成运行配置。
3. 同机恢复保留当前 SSH/UFW/Fail2ban 所有权与 Xray 服务启停状态。
4. 跨机器恢复只允许导入到当前空节点集合，并强制节点/线路机保持禁用供人工复核。
5. 跨机恢复不会迁移机器身份、SSH/UFW/Fail2ban 或“已验证”访问状态。

### 卸载 / 所有权

1. 卸载前拒绝未完成事务与待确认 SSH 事务，并检查关键受管文件漂移。
2. 默认先创建恢复备份，再删除节点相关 UFW 规则与受管运行对象。
3. 仅删除能够证明归 AsterNode 管理的 systemd 单元、Xray 核心、manager current/版本等内容。
4. 无法证明所有权或已经漂移的额外版本/路径保留并报告，不做模糊删除。
5. 默认保留 SSH 安全配置与密钥、UFW 服务/默认策略/管理员规则、Fail2ban 配置、受信发行公钥、备份和导出。
6. 卸载清理陈旧 `state.json` 与运行事务/证据，避免重装后复活已删除节点。

### 低资源维护

1. 不增加 AsterNode 自有常驻管理 daemon；维护继续使用 systemd oneshot/timer。
2. `maintenance status` 只读展示磁盘可用量和受管事务、备份、导出、证据、manager/core 版本占用。
3. `maintenance prune` 保守回收终态事务、超额备份、撤销/孤儿导出、孤儿 D4 证据和旧的已验证版本。
4. `NEEDS_RECOVERY` / pending 事务、当前/上一 manager、当前/回退 core、未知或无法验证内容均不自动删除。
5. Xray access log 默认关闭；system journal 与 Fail2ban 全局 logrotate 属于系统边界，不由 AsterNode 自动改写。

## 建议审查顺序

```text
lib/update.sh
  -> tools/build-release.sh
  -> tools/generate-bootstrap.sh
  -> lib/backup.sh
  -> lib/remove.sh
  -> lib/maintenance.sh
  -> relay-manager.sh
  -> tests/test_stage_d_release.sh
  -> tests/test_stage_d_bootstrap.sh
  -> tests/test_stage_d_core_update.sh
  -> tests/test_stage_d_backup.sh
  -> tests/test_stage_d_remove.sh
  -> tests/test_stage_d_maintenance.sh
  -> docs/IMPLEMENTATION_MATRIX.md
  -> docs/TEST_REPORT.md
  -> docs/STAGE_D_REAL_VPS_CHECKLIST.md
```

重点检查：

- 发行包和 bootstrap 是否存在任何浮动版本/浮动信任来源。
- manager/core 切换失败时是否始终能区分“已回滚”与“恢复不完整”。
- 备份恢复是否可能把旧机器安全状态或服务状态倒灌到当前机器。
- 卸载是否可能因为目录名相似或 state 陈旧而删除第三方内容。
- 维护回收是否可能删除 `NEEDS_RECOVERY`、当前/回退版本或未知文件。
- 所有只读 status/list 命令是否仍保持不修改系统。

## 尚不能标为最终通过

以下真实证据仍缺失：

- 固定版本远程 bootstrap 的真实 HTTPS 下载、安装、重复执行与离线边界。
- manager/core 真实升级、服务切换、故障回滚和重启恢复。
- 第二台 VPS 的跨机器恢复与人工复核启用。
- 卸载后真实 systemd/进程/端口/文件/重装状态对账。
- 低配 VPS 的长期磁盘/RSS/CPU 与维护 timer 行为。
- B/C 阶段尚未完成的真实网络、SSH、UFW、Fail2ban、T24/T25 门槛。

具体步骤见三份清单：

- `docs/STAGE_B_REAL_VPS_CHECKLIST.md`
- `docs/STAGE_C_REAL_VPS_CHECKLIST.md`
- `docs/STAGE_D_REAL_VPS_CHECKLIST.md`

## 下一步

进入统一真实 VPS 验收。按项目既定计划，先不继续扩功能；真实 Gate 发现的问题在当前 Stage D 分支修复并重新跑完整 CI。全部 Gate 通过后，再准备首个 `v1.0.0-rc` 候选。未经用户明确授权，不合并到 `main`。
