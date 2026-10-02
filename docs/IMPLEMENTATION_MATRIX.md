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
| UP-01 | B | 完成（隔离/配置级） | lib/node.sh; lib/export.sh | test_stage_b_node.sh; CI #59 | 首条线路机稳定 ID/独立 UUID 已覆盖；真实线路链路仍看 T25 |
| UP-02 | B | 完成（隔离） | lib/node.sh | test_stage_b_node.sh; CI #59 | CRUD、启停、来源、轮换已覆盖；真实来源连通仍待 VPS |
| UP-03 | B | 部分完成 | lib/node.sh; lib/export.sh | test_stage_b_node.sh; test_stage_b_export.sh | 删除/撤销状态与导出已测；T22 现有连接/新连接行为需真实网络验证 |
| UP-04 | B | 完成（模型/隔离） | lib/state.sh; lib/node.sh | test_stage_b_node.sh | 共享出口可用独立 UUID；NAT 真实环境仍待矩阵测试 |
| UP-05 | B | 完成（逻辑/隔离） | lib/node.sh | test_stage_b_node.sh | REALITY 密钥轮换与导出失效已覆盖；线路端真实切换待 T25 |
| UP-06 | B | 完成（隔离） | lib/export.sh | test_stage_b_export.sh; CI #59 | 0600、默认隐藏凭据、privateKey 不导出；真实运维流程待 VPS |
| UP-07 | B | 部分完成 | lib/node.sh | test_stage_b_node.sh; CI #59 | source-add→验证→source-remove 迁移逻辑已实现；真正白名单隔离归 Stage C/UFW 实机门槛 |
| UP-08 | B | 完成（边界） | lib/node.sh; lib/export.sh | 代码审查; CI #59 | 不保存线路 SSH/面板密码，不调用远程 3x-ui API |
| NODE-01 | B | 完成（配置级） | protocols/vless-reality.sh; lib/core-xray.sh | test_stage_b_protocol.sh; CI #59 real Xray | v26.3.27 服务端/客户端配置真实核心解析通过；T24/T25 真实连接未完成 |
| NODE-02 | B | 部分完成 | lib/node.sh; protocols/vless-reality.sh | test_stage_b_node.sh; test_stage_b_protocol.sh | 内外端口/地址/Target/SNI/来源模型已实现；真实 NAT 与占用端口进程展示待 VPS |
| NODE-03 | B | 完成（隔离） | protocols/vless-reality.sh; lib/node.sh | test_stage_b_protocol.sh; test_stage_b_node.sh | UUID/X25519/8-byte Short ID 生成、重跑不直接改凭据已覆盖 |
| NODE-04 | B | 部分完成 | lib/node.sh; lib/core-xray.sh | test_stage_b_node.sh; CI #59 real Xray | candidate `xray run -test` 与回滚框架已接入；真实服务启动失败回滚待 systemd VPS |
| NODE-05 | B | 部分完成 | templates/relay-manager-xray.service; lib/core-xray.sh | test_stage_b_core_service.sh | rm-xray、0640/0750、systemd hardening 模板已测；能力/硬化实际启动待 VPS |
| NODE-06 | B | 部分完成 | lib/node.sh | test_stage_b_node.sh | 单受管 Xray 多 inbounds/共享重启影响逻辑已覆盖；真实多节点运行待 VPS |
| NODE-07 | B | 完成（隔离） | lib/node.sh | test_stage_b_node.sh | 节点/线路启停删除、最后节点空配置、无启用凭据拒绝已覆盖 |
| NODE-08 | B | 部分完成 | lib/core-xray.sh; templates/relay-manager-xray.service | test_stage_b_core_service.sh | autostart/Restart/无路由内核调优已实现；真实开机/崩溃恢复待 VPS |
| TARGET-01 | B | 部分完成 | lib/target.sh; compat/targets.json | test_stage_b_target.sh | 候选与手工 Target、受控探测已实现；目标 VPS 实测结果不能由 CI 代替 |
| TARGET-02 | B | 部分完成 | lib/target.sh | test_stage_b_target.sh | DNS/TCP/TLS1.3/证书/H2/重复握手/延迟已实现；真实网络矩阵待执行 |
| TARGET-03 | B | 完成（逻辑） | lib/target.sh | test_stage_b_target.sh | HTTP 非 200 不自动判失败；探测不自动选择/修改节点 |
| TARGET-04 | B | 部分完成 | lib/target.sh | test_stage_b_target.sh | Target 回环/格式防护与风险提示已实现；真实回落/滥用风险需 VPS 审查 |
| TARGET-05 | B | 完成（边界） | lib/target.sh | test_stage_b_target.sh | 不自动改 Target、不自动开端口；候选探测限时且受控并发 |
| EXPORT-01 | B | 完成（隔离） | lib/export.sh | test_stage_b_export.sh | 参数表、URI、单 outbound 与合并说明已生成 |
| EXPORT-02 | B | 完成（隔离） | lib/export.sh; protocols/vless-reality.sh | test_stage_b_export.sh | 必要字段/IPv6 URI/转义已测，server privateKey 不导出 |
| EXPORT-03 | B | 部分完成 | compat/compatibility.json; lib/export.sh | CI #59 real Xray config parse | 固定 profile 配置可被真实 Xray 解析；T24 实际客户端连接仍未验证 |
| EXPORT-04 | B | 部分完成 | lib/export.sh | test_stage_b_export.sh | 3x-ui 字段映射与路由说明已生成；不声明一键兼容，T25 待真实面板 |
| F2B-01 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-02 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-03 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| F2B-04 | C | 未验收 | lib/fail2ban.sh（早期草稿） | — | 存在草稿不代表完成；按对应阶段开发、隔离测试和实机证据后更新 |
| DIAG-01 | B/D | 部分完成 | diagnostics.sh | test_stage_b_diagnostics.sh | D1-D4 分层与证据失效检测已实现；D4 必须由真实线路 VPS 记录 |
| DIAG-02 | B/D | 完成（Stage B 范围） | diagnostics.sh | test_stage_b_diagnostics.sh | 脱敏包 0600、默认不联网、不上传、凭据不进入包；D 阶段再扩展发行/长期日志边界 |
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
| TEST-01 | A/跨阶段 | 完成当前阶段自动化 | tests/run.sh; .github/workflows/ci.yml | CI #59: 18/0/0; bash -n; ShellCheck | 真实 systemd/网络仍属于 TEST-02 |
| TEST-02 | A/跨阶段 | 未执行 | — | — | 真实 VM/VPS 阶段 |
| TEST-03 | A/跨阶段 | 部分建立 | docs/TEST_REPORT.md; docs/STAGE_B_REAL_VPS_CHECKLIST.md | Stage A/B 自动化记录 + CI #59 | 真实 VPS 记录仍需逐项 case_id/镜像/版本/实际结果 |
| TEST-04 | A/跨阶段 | 未完成 | docs/TEST_REPORT.md | T01-T36 当前结论表 | 最终首版门槛需 B/C/D 后完整执行 |
