# Stage C 审查交接

## 当前基线

- 项目仓库：`Aspeternity/AsterNode`
- 管理器版本：`0.2.0-dev`
- 分支：`dev/stage-c-security`
- Stage C 功能稳定基线：`bd4d10d0a7bc4903a0209f06c7e2c9a25c5a7f69`
- GitHub Actions：#88，`success`
- 自动化：`21 passed / 0 failed / 0 skipped`
- Bash syntax：PASS
- ShellCheck：PASS
- 固定 Xray v26.3.27 服务端/客户端配置解析：PASS

> Stage C 收尾文档提交会使 HEAD 前移；审查安全模块功能时，以 `bd4d10d` 与 CI #88 作为稳定代码基线。真实 VPS Gate 按项目计划延后到 A-D 全部开发完成后的统一验收。

## Stage C 已实现

### SSH

1. 检测 ssh/sshd service、socket 模式、实际监听、Include/Match/cloud-init、systemd ExecStart/SSHD_OPTS。
2. 使用 `sshd -t` 与 `sshd -T -C` 获取/校验有效策略，检测 `-f/-p/-o` 等启动参数覆盖并阻止自动收紧。
3. 按有效 AuthorizedKeysFile 定位公钥；拒绝私钥；ssh-keygen 校验；按密钥材料去重。
4. key inventory/fingerprint；按 fingerprint 删除；阻止删除最后一个当前仍存在的已验证入口。
5. 新连接验证命令禁用连接复用、密码与键盘交互回退；不使用 SSH_CONNECTION 自动判成功。
6. 密码关闭与 Root 策略分别使用独立受保护事务；禁 Root 前要求非 Root key 与实际 sudo 验证。
7. SSH 端口双端口迁移；可管理 UFW 下先放行新端口；新连接确认前保留旧端口。
8. systemd rollback timer + boot guard；待确认状态可回滚；提供 `ssh recovery-guide` 控制台恢复说明。

### UFW

1. 只在检测为可管理 UFW 环境时自动写规则；发现 firewalld/nftables/容器链或 framework 漂移时拒绝自动接管。
2. 新启用前列出监听服务；自动保留 SSH，其他业务只接受显式 `--preserve-port`；不 reset、不改默认策略、不自动全开。
3. 规则按节点/用途记录所有权，规范化、幂等、语义删除。
4. 白名单使用具体 allow + 受管端口 deny；检测外部公网放行冲突；没有真实网络对照前保持 unverified。
5. IPv6 监听时要求 UFW IPv6 支持，不通过关闭系统 IPv6 绕过。
6. 临时公网开放有固定时限（默认 10 分钟），到期只移除本次规则；Xray 启动前有 firewall guard 做过期回收。

### Fail2ban

1. 根据有效 SSH 认证策略给出 recommended/optional/unverified。
2. 只管理自有 sshd jail；发现已有管理员 `[sshd]` 配置时拒绝覆盖。
3. file/systemd backend 区分；systemd 检查 python-systemd，且不写 file logpath。
4. 按实际 SSH 端口生成 jail；UFW 可安全使用时选择 UFW banaction。
5. apply 后检查 config、服务、sshd jail 和实际配置的日志源，不在健康检查时悄悄切换后端。
6. 提供 banned list 与单 IP unban；ignoreip 只包含显式管理来源，不复制线路机白名单。
7. 自有 jail 设置 maxmatches/findtime/bantime；全局数据库保留/logrotate 仅观察，不影响其他 jail；disable 只停自有 jail。

## 建议审查顺序

```text
lib/ssh.sh
  -> templates/relay-manager-ssh-*
  -> lib/firewall.sh
  -> templates/relay-manager-firewall-guard.service
  -> lib/fail2ban.sh
  -> relay-manager.sh
  -> tests/test_stage_c_ssh.sh
  -> tests/test_stage_c_firewall.sh
  -> tests/test_stage_c_fail2ban.sh
  -> docs/IMPLEMENTATION_MATRIX.md
  -> docs/TEST_REPORT.md
  -> docs/STAGE_C_REAL_VPS_CHECKLIST.md
```

重点检查：

- 任意 SSH 收紧是否都无法绕过保护事务/新连接验证。
- systemd boot guard 是否在 service 与 socket 模式都能在 SSH 接受连接前恢复未验证配置。
- confirm 与 timeout 并发时事务锁是否保证唯一最终状态。
- UFW 是否可能因外部 allow、默认策略、before/after 或 IPv6 形成“白名单虚假成功”。
- 临时公网开放重启后是否一定恢复原访问模式。
- Fail2ban 健康检查是否检查“当前配置的后端”，而不是日志源变化后静默切换到另一个后端。
- 停用/卸载是否只影响受管对象，不破坏管理员已有安全配置。

## 尚不能标为最终通过

Stage C 的规范 Gate 是“白名单隔离与 SSH 故障注入通过”。当前仅完成代码与隔离自动化，以下真实证据仍待最终统一验收：

- T05-T14：Include/Match/启动参数、普通 service、ssh.socket、云端阻挡、公钥失败、Root/sudo、断线/kill/超时/重启/并发。
- T15-T20：UFW 业务入口、外部规则冲突、默认/早期规则、双栈来源隔离、复杂环境、临时开放到期与重启。
- T26：真实 Fail2ban 日志消费、封禁与解封。

具体步骤见 `docs/STAGE_C_REAL_VPS_CHECKLIST.md`。

## 下一阶段

Stage C 文档收尾完成后进入 Stage D：正式 bootstrap/发行信任、更新与回退、备份恢复、卸载、资源/长期增长、最终 A-D 统一实机矩阵。未经用户明确授权，不合并到 `main`。
