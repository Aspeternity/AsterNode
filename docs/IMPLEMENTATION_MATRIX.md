# IMPLEMENTATION_MATRIX

> 状态原则：只有完成当前阶段要求并有对应测试证据的项目才标“完成”。仓库中 B/C/D 的早期草稿代码不计为完成。

| 需求 | 阶段 | 当前状态 | 实现位置 | 测试证据 | 剩余限制 |
|---|---|---|---|---|---|
| ENV-01 | A/跨阶段 | 完成 | lib/system.sh; relay-manager.sh | test_system_readonly.sh; test_status_readonly.sh | 联网公网地址探测为独立函数，不在快速体检执行 |
| ENV-02 | A/跨阶段 | 完成（单元证据） | lib/system.sh | test_system_readonly.sh | 四个承诺系统/双架构真实证据待系统集成 |
| ENV-03 | A/跨阶段 | 部分完成 | lib/system.sh: system_ssh_json | test_system_readonly.sh | sshd -T -C、Match/不同用户与真实新连接验证需 Stage C 实机 |
| ENV-04 | A/跨阶段 | 完成检测框架 | lib/system.sh | test_system_readonly.sh | 外部 Xray/3x-ui/Nginx 实机不接管归 Stage B/C T04 |
| ENV-05 | A/跨阶段 | 部分完成 | lib/system.sh: system_probe_public_address | — | NAT 外部端口与手工输入的完整节点交互待 Stage B |
| UX-01 | A/跨阶段 | 部分完成 | relay-manager.sh; install.sh | test_install.sh | 菜单路由已固定；各功能真正完成取决于 B/C/D |
| UX-02 | A/跨阶段 | 部分完成 | lib/transaction.sh: tx_diff_summary_json/tx_apply | test_transaction.sh | 业务语义差异与影响清单由各后续模块补齐 |
| UX-03 | A/跨阶段 | 部分完成 | lib/common.sh; relay-manager.sh | test_non_tty.sh | Ctrl+C 不取消 SSH 回滚保护待 Stage C |
| UX-04 | A/跨阶段 | 未验收 | relay-manager.sh: quick_deploy（草稿） | — | 依赖 B/C 模块后验收 |
| ARC-01 | A/跨阶段 | 完成基础 | lib/common.sh; install.sh | test_install.sh | Fail2ban Python 资源计算待 Stage C |
| ARC-02 | A/跨阶段 | 完成接口契约 | protocols/vless-reality.sh | test_protocol_interface.sh | 协议端到端属于 Stage B |
| ARC-03 | A/跨阶段 | 部分完成 | protocols/; lib/core-xray.sh（草稿） | test_protocol_interface.sh | 核心生命周期/端口需求真实验证待 B |
| ARC-04 | A/跨阶段 | 完成路由基础 | relay-manager.sh | bash -n; help 手工检查 | 子命令行为随 B/C/D 继续验收 |
| DATA-01 | A/跨阶段 | 完成基础模型 | lib/state.sh | test_state.sh | UUID 撤销行为待 B |
| DATA-02 | A/跨阶段 | 部分完成 | lib/state.sh; lib/node.sh（草稿） | test_state.sh | 协议权限边界/Short ID 行为待 B |
| DATA-03 | A/跨阶段 | 部分完成 | lib/state.sh; lib/transaction.sh | test_state.sh; test_transaction.sh | 运行 Xray 配置外部编辑对账待 B/D |
| SEC-01 | A/跨阶段 | 完成 Stage-A 基础 | lib/common.sh; lib/state.sh; lib/transaction.sh | test_common.sh; test_symlink_safety.sh | 归档/发行包恶意输入仍需 D |
| TX-01 | A/跨阶段 | 完成框架 | lib/transaction.sh | test_transaction.sh | 各业务模块候选检查/运行验证接入待 B/C/D |
| TX-02 | A/跨阶段 | 完成框架 | lib/transaction.sh | test_transaction_lock.sh; test_transaction.sh | SSH 待确认释放短锁的业务流程待 C |
| TX-03 | A/跨阶段 | 完成文件框架 | lib/transaction.sh | test_transaction.sh | 服务状态 managed_change 接入在后续模块实测 |
| TX-04 | A/跨阶段 | 完成框架 | lib/transaction.sh | test_transaction.sh | 跨真实重启/systemd 恢复待 C/D |
| TX-05 | A/跨阶段 | 完成框架 | lib/transaction.sh | test_transaction.sh | 真实 UFW 规则归属回滚待 C |
| TX-06 | A/跨阶段 | 部分完成 | lib/transaction.sh; install.sh | test_transaction.sh | 包安装/删除/升级的业务语义待 D |
| TX-07 | A/跨阶段 | 完成退出码基础 | lib/common.sh | test_non_tty.sh; test_transaction.sh | 后续全部命令需继续统一覆盖 |
| SSH-01 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-02 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-03 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-04 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-05 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-06 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-07 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-08 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-09 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-10 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-11 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-12 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| SSH-13 | C | 未验收 | lib/ssh.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-01 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-02 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-03 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-04 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-05 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-06 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-07 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-08 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| FW-09 | C | 未验收 | lib/firewall.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-01 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-02 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-03 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-04 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-05 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-06 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-07 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UP-08 | B | 未验收 | lib/node.sh / lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-01 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-02 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-03 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-04 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-05 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-06 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-07 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| NODE-08 | B | 未验收 | lib/node.sh / lib/core-xray.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TARGET-01 | B | 未验收 | lib/target.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TARGET-02 | B | 未验收 | lib/target.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TARGET-03 | B | 未验收 | lib/target.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TARGET-04 | B | 未验收 | lib/target.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TARGET-05 | B | 未验收 | lib/target.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| EXPORT-01 | B | 未验收 | lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| EXPORT-02 | B | 未验收 | lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| EXPORT-03 | B | 未验收 | lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| EXPORT-04 | B | 未验收 | lib/export.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-01 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-02 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-03 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-04 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| DIAG-01 | B/D | 未验收 | diagnostics.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| DIAG-02 | B/D | 未验收 | diagnostics.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-01 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-02 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-03 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-04 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-05 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-06 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-07 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| UPDATE-08 | D | 未验收 | lib/update.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| BACKUP-01 | D | 未验收 | lib/backup.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| BACKUP-02 | D | 未验收 | lib/backup.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| BACKUP-03 | D | 未验收 | lib/backup.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| REMOVE-01 | D | 未验收 | lib/remove.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| REMOVE-02 | D | 未验收 | lib/remove.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| REMOVE-03 | D | 未验收 | lib/remove.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| PERF-01 | D/跨阶段 | 未验收 | 架构约束部分已体现在当前代码；正式证据待 D | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| PERF-02 | D/跨阶段 | 未验收 | 架构约束部分已体现在当前代码；正式证据待 D | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| PERF-03 | D/跨阶段 | 未验收 | 架构约束部分已体现在当前代码；正式证据待 D | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| TEST-01 | A/跨阶段 | 部分完成 | tests/run.sh; .github/workflows/ci.yml | bash -n 本地通过 | 本地 ShellCheck 缺失；CI 尚无运行证据 |
| TEST-02 | A/跨阶段 | 未执行 | — | — | 真实 VM/VPS 阶段 |
| TEST-03 | A/跨阶段 | 部分建立 | docs/TEST_REPORT.md | Stage-A case 表 | 提交 SHA/镜像/组件版本字段在真实测试继续补齐 |
| TEST-04 | A/跨阶段 | 未完成 | docs/TEST_REPORT.md | T01-T36 当前结论表 | 最终首版门槛需 B/C/D 后完整执行 |
