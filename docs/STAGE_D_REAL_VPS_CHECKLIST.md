# Stage D 真实 VPS 验收清单

> 目标：验证 CI 无法证明的发行、systemd、磁盘、重启、跨机器和故障恢复行为。必须使用可重装/可快照的专用 VM/VPS，不在唯一生产入口上首次执行破坏性故障注入。

## 每个 case 必填记录

每个 case 至少记录：

- case_id
- 日期/UTC 时间
- VPS 厂商或虚拟化类型（可脱敏）
- OS / 版本
- 架构（amd64 / arm64）
- CPU / RAM / 磁盘
- 公网形态（IPv4 / 双栈 / IPv6-only / NAT）
- AsterNode manager 版本与 commit
- Xray 版本
- 执行命令
- 预期结果
- 实际结果
- 退出码
- 关键 systemd / 文件 / 链接状态
- 是否需要回滚
- 脱敏证据路径或摘要

不得把 UUID、REALITY 私钥、完整分享 URI、SSH 私钥或真实管理凭据写进报告。

## D-VPS-01：固定版本 bootstrap / 首次信任

前提：准备固定版本发行包、发行公钥、bootstrap 脚本和 HTTPS 固定 URL。

验证：

1. 在干净 VPS 上先下载 bootstrap 到文件并人工检查版本、包 URL、包 SHA-256、公钥 URL、公钥 SHA-256均为固定值。
2. 执行固定 bootstrap，确认没有读取浮动 `main` / `latest`。
3. 验证安装后的 `/usr/local/lib/relay-manager/current`、`/usr/local/bin/relay-manager`、受信公钥与发行 manifest。
4. 再执行一次同一 bootstrap，确认同版本幂等，不产生第二套状态或重复服务。
5. 断网后执行 `relay-manager update status` 与 `verify-manager`，确认本地检查不依赖远端。
6. 修改发行包一个字节、替换公钥、修改签名或 SHA-256，分别确认安装在写入受管版本前拒绝。

通过条件：固定来源、哈希、签名、manifest 与首次信任边界全部符合设计；失败样本不留下半切换 current。

## D-VPS-02：管理器升级 / 回退

准备两个真实签名版本 A、B。

验证：

1. A 正常安装并创建至少一个节点状态。
2. 从 A 安装 B，确认 release smoke 后才切换 current。
3. 状态中的 manager_version 与 current 真实版本一致。
4. 执行 rollback-manager，确认回到 A，状态同步。
5. 再切到 B，验证旧版本仍可作为回退点。
6. 在切换前后分别注入坏 manifest / smoke 失败 / 不可写目标目录，确认旧 current 保持可用。
7. 重启 VPS 后确认 current、命令链接和状态仍一致。

通过条件：成功切换原子、失败不破坏旧版本、回退可用、重启后无链接漂移。

## D-VPS-03：Xray 核心升级 / 失败恢复 / 显式回退

准备当前兼容核心与一个测试候选版本。

验证：

1. 记录升级前 `current`、state.core_version、service enabled/active 和真实线路连通。
2. 升级核心，确认候选先完成配置验证再切换。
3. 服务原本启用/运行时，升级后保持同一启停语义。
4. 使用无效候选或故意让服务启动失败，确认自动恢复旧核心并返回“已回滚”而非成功。
5. 使用升级恢复点执行 `rollback-core`。
6. 回退后重新做真实线路机认证、代理请求和出口确认。
7. 重启 VPS 后确认 core current、状态与服务一致。

通过条件：没有“先切换再验证”；失败恢复明确；真实线路在升级/回退后可重新建立。

## D-VPS-04：同机备份 / 恢复

验证：

1. 创建包含节点/线路机的 config 备份。
2. 检查备份目录 0700、manifest/payload 0600、`backup verify` 通过。
3. 修改节点名称/Target/来源等非安全状态。
4. 记录当前 SSH、UFW、Fail2ban 与 Xray service enabled/active。
5. 执行同机 restore。
6. 确认节点/线路数据恢复，但 SSH/UFW/Fail2ban 所有权与 service enabled/active 没被旧备份覆盖。
7. 篡改 payload 或 manifest 后确认 verify/restore 拒绝。
8. 更换/伪造 machine-id 环境后确认完整同机 restore 拒绝。

通过条件：恢复点完整性有效，同机恢复不倒灌安全状态，不改变原服务启停语义。

## D-VPS-05：跨机器禁用恢复

使用第二台干净 VPS。

验证：

1. 将恢复点安全复制到第二台机器。
2. 当前节点/线路集合必须为空。
3. 执行 `restore-nodes`。
4. 确认所有导入节点/线路机默认 disabled，pending UUID/rotation 不迁移。
5. 确认 SSH/UFW/Fail2ban、machine-id、已验证登录状态均未迁移。
6. 人工重新检查公网地址、端口、Target/SNI、来源地址和防火墙。
7. 逐项启用并执行 Stage B/C 对应真实 Gate。
8. 在目标机已存在节点时再次执行，确认拒绝覆盖。

通过条件：跨机恢复是“导入供复核”，不是克隆机器安全状态。

## D-VPS-06：所有权范围卸载 / 重装

验证：

1. 创建受管节点、导出、备份、维护 timer，并保留一份明确的第三方文件/目录靠近受管目录。
2. 修改一个关键受管 helper 文件制造漂移，确认卸载预检拒绝且没有部分删除。
3. 恢复 helper 后执行默认卸载。
4. 确认先生成恢复备份。
5. 确认 Xray 服务/核心、manager current/命令、AsterNode 辅助 systemd 单元和陈旧 state 被清理。
6. 确认 SSH 安全策略/密钥、UFW 服务/管理员规则、Fail2ban 配置、受信公钥、默认备份/导出仍保留。
7. 确认第三方/无法证明所有权的内容未被删除并被报告。
8. 重启后检查无 AsterNode 残留进程/监听/失败 unit。
9. 重新安装，确认旧已删除节点不会因陈旧 state 自动复活。

通过条件：不误删第三方内容；默认安全状态保留；重装获得干净 manager/node 状态。

## D-VPS-07：低资源 / 长期增长

目标至少包含一台约 1 GB RAM 的低配 VPS。

验证：

1. 记录空闲时 manager/Xray RSS、CPU、磁盘占用。
2. 连续执行节点修改、UUID 轮换、导出、诊断、备份，制造多轮终态事务和历史对象。
3. `maintenance status` 的计数/bytes 与实际目录大致一致。
4. `maintenance prune` 后终态事务、旧备份、孤儿导出/证据和旧受管版本按策略收敛。
5. 人工放置未知文件/目录，确认 prune 不删除。
6. 创建 `NEEDS_RECOVERY` 或 pending 事务，确认维护回收暂停。
7. 观察 systemd maintenance timer 多次运行，确认无自有常驻 manager daemon。
8. 检查 system journal / Fail2ban logrotate 未被 AsterNode 重写，Xray access log 默认未增长。

通过条件：受管增长有界，不以删除恢复状态或未知内容换取空间；低配机器无异常常驻开销。

## D-VPS-08：重启 / reconcile

验证：

1. 在存在正常节点、临时开放/UUID rotation、维护 timer 的场景重启。
2. 启动后运行 status/doctor，确认 state、current 链接与 systemd 单元一致。
3. 确认过期临时开放、UUID rotation 按既定 reconcile 语义处理。
4. 确认 maintenance prune 不在 pending/recovery 事务上继续破坏性清理。
5. Xray 服务按原 autostart/active 语义恢复。
6. 重启后再次执行 B/C/D 关键 smoke。

通过条件：重启不会使状态、current、服务和过期状态出现互相矛盾。

## D-VPS-09：磁盘 / 中断故障注入

只在可快照测试机执行。

至少覆盖：

- 安装/更新前空间不足；
- 写入版本目录中途失败；
- manager 切换前 kill；
- core 候选准备失败；
- service 重启失败；
- 备份创建失败；
- 恢复应用失败；
- 卸载预检后、正式删除前外部漂移。

每种场景记录退出码，并区分：

- 10：前置条件拒绝；
- 20：应用失败但已恢复；
- 21：恢复不完整，需要人工处理；
- 30：网络/下载失败。

通过条件：不会把“恢复不完整”误报成成功或普通已回滚。

## D-VPS-10：系统 / 架构矩阵

至少记录：

- Debian 12 amd64；
- Ubuntu LTS amd64；
- 一台 arm64（Debian/Ubuntu 均可）；
- IPv4、双栈；有条件时补 IPv6-only/NAT。

arm64 必须实际运行对应 Xray 资产，不能仅凭兼容矩阵或下载元数据判通过。

## Stage D Gate 完成条件

以下全部满足才可将 Stage D 标为真实环境通过：

1. D-VPS-01 至 D-VPS-09 全部通过；D-VPS-10 至少覆盖当前承诺的发布系统/架构。
2. 没有未解释的 `NEEDS_RECOVERY`、失败 systemd unit、残留受管进程或 current/state 漂移。
3. 更新、回退、恢复、卸载都保留明确的所有权和失败边界。
4. B/C 的真实 Gate 同时通过；特别是 T24/T25、SSH 故障注入、UFW 来源对照与 Fail2ban 实际封禁。
5. 所有证据已脱敏并写入最终测试报告。

完成后再进入首个 `v1.0.0-rc` 候选流程；在此之前不把当前开发版描述为生产稳定。
