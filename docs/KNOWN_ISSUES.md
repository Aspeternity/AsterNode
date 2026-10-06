# 已知问题与阶段边界

## 当前阻断生产使用

1. Stage B 已完成 T25 真实 3x-ui → 落地 Xray 全链路，但系统/架构/网络矩阵并未全部覆盖；T24 独立客户端记录、ARM64、IPv6-only/NAT 等仍按对应 checklist 视为未验证。
2. Stage C 的 Ubuntu 24.04 `ssh.socket`、SSH crash-recovery、UFW 来源对照和临时公网开放关键路径已有实机 PASS；Fail2ban 实际攻击触发/封禁/解封及未覆盖的发行版/复杂防火墙组合仍是发布阻断项。
3. 本机 SSH 回滚不能修复云安全组、NAT、供应商网络故障或损坏系统；`ssh recovery-guide` 只能给出本机/控制台恢复路径。
4. UFW 白名单只有在“允许来源成功 + 非允许来源失败”的外部对照后才能标记 verified；已完成的单一 VPS 证据不外推到其他云、防火墙或网络栈。
5. Fail2ban 当前只管理 AsterNode 自有 sshd jail。全局数据库保留和系统 logrotate 仅观察，不自动改写。
6. Stage D 的签名发行、bootstrap、更新/回退、备份/恢复、卸载和维护逻辑已有自动化覆盖，但 D-VPS-01～09 尚未全部形成真实 VPS 证据。
7. ARM64 固定资产元数据已记录，但当前 CI 的真实 Xray 执行仍是 amd64；ARM64 必须在对应架构实测。
8. 正式公共 bootstrap URL、发行签名密钥运维、License 与首个 RC 的 VERSION/tag/release 仍未最终落定；当前 `VERSION` 保持 `0.2.0-dev`。
9. Target 探测只代表执行探测的 VPS 当时网络，不会自动选择 Target 或修改节点。

## 当前安全边界

- SSH 收紧操作要求 root + TTY，并使用独立事务；端口、密码、Root 不一次性同时收紧。
- 新 SSH 入口不能仅凭文件存在、旧终端或 SSH_CONNECTION 判成功；必须使用全新连接并禁用复用/密码/键盘交互回退进行验证。
- 删除公钥时阻止移除最后一个当前仍存在的已验证入口。
- SSH 端口迁移默认保留旧端口，并在可管理 UFW 下先放行新端口；到期或未确认走回滚。
- UFW 不 reset、不修改已有默认策略，不自动开放扫描到的所有服务；非 SSH 业务入口需要显式确认。
- 白名单规则存在不等于隔离成功；未做真实网络对照时保持 unverified。
- 临时公网开放只移除本次受管放行，不做全局 conntrack 清理。
- Fail2ban 不覆盖已有管理员 sshd jail，不把线路机来源名单自动当作 SSH ignoreip。
- 遇到受管配置摘要漂移或外部修改时拒绝静默覆盖。
- 诊断/导出默认不泄漏完整 UUID、REALITY 私钥或分享 URI。
- 若出现 `NEEDS_RECOVERY`，保留第三方现场，默认不强行覆盖。
