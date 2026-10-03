# 已知问题与阶段边界

## 当前阻断生产使用

1. Stage B 的自动化/配置级基线已稳定，但真实 systemd、IPv4/双栈/IPv6-only、NAT、T24/T25 仍未完成。
2. Stage C 的 SSH/UFW/Fail2ban 代码与隔离自动化在 `bd4d10d` / CI #88 达到 `21 passed / 0 failed / 0 skipped`，但 T05-T20/T26 的真实远程登录、故障注入、白名单对照和实际封禁仍待最终统一 VPS 验收。
3. 本机 SSH 回滚不能修复云安全组、NAT、供应商网络故障或损坏系统；`ssh recovery-guide` 只能给出本机/控制台恢复路径。
4. UFW 白名单在完成“允许来源成功 + 非允许来源失败”的外部对照前保持未验证。复杂 nftables、firewalld、Docker/容器链或自定义 UFW framework 会阻止自动接管。
5. Fail2ban 当前只管理 AsterNode 自有 sshd jail。实际攻击触发、封禁与解封效果必须在隔离 VM/VPS 验证；全局数据库保留和系统 logrotate 仅观察，不自动改写。
6. Stage D 的正式远程 bootstrap、发行包签名/信任锚、更新/回退、备份恢复、卸载与最终发布矩阵仍未完成。
7. ARM64 固定资产元数据已记录，但当前 CI 的真实 Xray 执行仍是 amd64；ARM64 必须在对应架构实测。
8. Target 探测只代表执行探测的 VPS 当时网络，不会自动选择 Target 或修改节点。

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
