# IMPLEMENTATION_MATRIX

> 状态原则：只有完成当前阶段要求并有对应测试证据的项目才标“完成”。仓库中 B/C/D 的早期草稿代码不计为完成。

| 需求 | 阶段 | 当前状态 | 实现位置 | 测试证据 | 剩余限制 |
|---|---|---|---|---|---|
| ENV-01 | A/跨阶段 | 完成 | lib/system.sh; relay-manager.sh | test_system_readonly.sh; test_status_readonly.sh | 联网公网地址探测为独立函数，不在快速体检执行 |
| ENV-02 | A/跨阶段 | 完成（单元证据） | lib/system.sh | test_system_readonly.sh | 四个承诺系统/双架构真实证据待系统集成 |
| ENV-03 | A/C | 部分完成 | lib/system.sh; lib/ssh.sh | test_system_readonly.sh; test_stage_c_ssh.sh; CI #88 | sshd -T -C、Include/Match/启动参数与目标用户检测已有隔离证据；真实发行版/连接条件待 T05/T07 |
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
| SSH-01 | C | 完成（隔离/逻辑） | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 服务/socket、启动参数、Include/Match/cloud-init 与 sshd -T -C 路径已实现；T05/T07 的真实发行版/服务矩阵待最终 VPS |
| SSH-02 | C | 完成（隔离/逻辑） | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 有效 AuthorizedKeysFile、外部命令/CA/MFA 阻断已实现；多用户真实目录/权限待 VPS |
| SSH-03 | C | 完成（隔离） | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 仅公钥、ssh-keygen 校验、拒绝私钥、材料去重与原行保留已覆盖 |
| SSH-04 | C | 部分完成 | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | fingerprint 删除与最后已验证入口保护已测；真实目标账户 ownership/权限待 VPS |
| SSH-05 | C | 部分完成 | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | Root 仅公钥/禁用的前置逻辑与 sudo 证明已实现；T11 真实非 Root 新连接 + sudo 待 VPS |
| SSH-06 | C | 部分完成 | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | Password/KbdInteractive/AuthenticationMethods/外部认证阻断已覆盖；PAM/Match 的真实发行版组合待 T05/T09 |
| SSH-07 | C | 完成（流程/隔离） | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 生成禁用连接复用/密码/键盘交互回退的新连接命令；实际成功仍必须人工/实机确认 |
| SSH-08 | C | 完成（安全边界） | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 不基于 SSH_CONNECTION 自动判定，无法可靠关联日志时只允许明确人工验证；T10 实机复用旧会话仍待验收 |
| SSH-09 | C | 部分完成 | lib/ssh.sh; lib/firewall.sh | test_stage_c_ssh.sh; test_stage_c_firewall.sh; CI #88 | 双端口、UFW 先放行、语法/重启/待确认/回滚流程已覆盖；T06-T08 真实 SSH/云侧阻断待 VPS |
| SSH-10 | C | 部分完成 | lib/ssh.sh | test_stage_c_ssh.sh; CI #88 | 关闭密码为独立受保护事务，要求已验证 key；新的纯密钥真实连接待 VPS |
| SSH-11 | C | 部分完成 | lib/ssh.sh; templates/relay-manager-ssh-* | test_stage_c_ssh.sh; CI #88 | systemd 绝对截止 timer 与 boot guard 已实现；T12 断线/kill/超时真实故障注入待 VPS |
| SSH-12 | C | 部分完成 | lib/ssh.sh; templates/relay-manager-ssh-* | test_stage_c_ssh.sh; CI #88 | 启动前 rollback guard 顺序已模板化；T07/T13 的 service/socket 实际重启顺序待 VPS |
| SSH-13 | C | 完成（流程/边界） | lib/ssh.sh; README.md | test_stage_c_ssh.sh; CI #88 | recovery-guide 明确本机回滚与云安全组/NAT/供应商故障边界，不承诺绝对不锁死 |
| FW-01 | C | 完成（检测/边界） | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | firewalld/nftables/容器链/UFW framework 漂移会阻止自动接管；复杂真实环境待最终对账 |
| FW-02 | C | 完成（流程/隔离） | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | 启用前展示监听，SSH 自动保留，其他业务必须显式 --preserve-port；不 reset/不改默认策略/不自动全开 |
| FW-03 | C | 完成（逻辑/隔离） | lib/firewall.sh; lib/state.sh | test_stage_c_firewall.sh; CI #88 | 规则按用途归属、规范化、语义删除与幂等已覆盖 |
| FW-04 | C | 部分完成 | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | 现有公网 ALLOW/LIMIT、framework/IPv6 冲突检测已实现；T16-T18 实际规则顺序与双栈隔离待 VPS |
| FW-05 | C | 部分完成 | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | 白名单生成 allow + 端口 deny，未做外部对照前保持 unverified；T17 默认允许/更早规则真实效果待 VPS |
| FW-06 | C | 部分完成 | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | IPv6 监听时要求 UFW IPv6；不关闭系统 IPv6；真实双栈/ICMP(v6) 行为待 T18 |
| FW-07 | C | 完成（语义/隔离） | lib/firewall.sh | test_stage_c_firewall.sh; CI #88 | UFW 未实施时明确 not_locally_enforced/unverified；空白名单在受管 UFW 下为节点端口拒绝 |
| FW-08 | C | 完成（语义） | lib/firewall.sh | test_stage_c_firewall.sh | 明确规则变更主要影响新连接，不默认清理 conntrack；当前未实现破坏性的全局立即撤销 |
| FW-09 | C | 部分完成 | lib/firewall.sh; templates/relay-manager-firewall-guard.service | test_stage_c_firewall.sh; test_stage_b_core_service.sh; CI #88 | 默认 10 分钟、精确撤销、自启动前过期回收已实现；T20 真重启/真实连接待 VPS |
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
| F2B-01 | C | 完成（逻辑/隔离） | lib/fail2ban.sh | test_stage_c_fail2ban.sh; CI #88 | 密码开放时推荐、纯 key 可选；已有管理员 sshd jail 冲突时拒绝覆盖 |
| F2B-02 | C | 完成（逻辑/隔离） | lib/fail2ban.sh | test_stage_c_fail2ban.sh; CI #88 | file/systemd backend、python-systemd 依赖、UFW banaction、实际 SSH 端口与 systemd 无 logpath 已覆盖 |
| F2B-03 | C | 部分完成 | lib/fail2ban.sh | test_stage_c_fail2ban.sh; CI #88 | 配置/服务/jail/日志源健康、ban 列表/单 IP unban/显式 ignore 已实现；T26 真实 Fail2ban 封禁/解封仍待隔离 VM/VPS |
| F2B-04 | C | 完成（策略/隔离） | lib/fail2ban.sh | test_stage_c_fail2ban.sh; CI #88 | 自有 jail maxmatches/findtime/bantime 已固定记录；全局数据库/logrotate 只观察不改；disable 只停自有 jail |
| DIAG-01 | B/D | 部分完成 | diagnostics.sh | test_stage_b_diagnostics.sh | D1-D4 分层与证据失效检测已实现；D4 必须由真实线路 VPS 记录 |
| DIAG-02 | B/D | 完成（Stage B 范围） | diagnostics.sh | test_stage_b_diagnostics.sh | 脱敏包 0600、默认不联网、不上传、凭据不进入包；D 阶段再扩展发行/长期日志边界 |
| UPDATE-01 | D | 完成（隔离/发行级） | lib/update.sh; tools/build-release.sh | test_stage_d_release.sh; CI #103 | 签名 manifest、SHA256SUMS、文件集合/大小/权限/哈希与危险归档输入已自动化；真实固定 URL 下载待 VPS |
| UPDATE-02 | D | 完成（隔离/信任边界） | tools/generate-bootstrap.sh; install.sh | test_stage_d_bootstrap.sh; CI #103 | bootstrap 固定版本、包/公钥 URL 与 SHA-256，不跟随 main/latest；首次 bootstrap HTTPS 信任仍需发布流程与 VPS 记录 |
| UPDATE-03 | D | 完成（隔离） | lib/update.sh: update_install_trusted_key | test_stage_d_release.sh | 首次受信公钥固定、不同公钥静默替换被拒绝；正式密钥轮换流程作为发布运维事项单独执行 |
| UPDATE-04 | D | 完成（隔离） | lib/update.sh: update_install_manager_package | test_stage_d_release.sh; CI #103 | 外层包 SHA、签名发行内容、release smoke、版本目录切换与同版本幂等已覆盖；真实磁盘/断电故障待 VPS |
| UPDATE-05 | D | 完成（隔离） | lib/update.sh: update_manager_rollback | test_stage_d_release.sh | 上一版本完整性/冒烟校验后回退，失败恢复 current；真实运行中版本切换待 VPS |
| UPDATE-06 | D | 完成（隔离/配置级） | lib/update.sh; lib/core-xray.sh | test_stage_d_core_update.sh; CI #103 real Xray | 新核心先准备/验证后切换，保留 service enabled/active 状态并在失败后恢复旧核心；真实线路兼容待 VPS |
| UPDATE-07 | D | 完成（隔离） | lib/update.sh: update_core_rollback; lib/backup.sh | test_stage_d_core_update.sh | 显式 rollback-core 使用升级恢复点，旧核心 0600 备份按 0755 恢复；真实服务/线路回退待 VPS |
| UPDATE-08 | D | 完成（边界） | lib/update.sh: update_status_json/update_verify_current_manager | test_stage_d_release.sh | 状态/完整性检查默认只读且不联网，不在启动时隐式更新；远端“是否有新版本”不作为首版自动行为 |
| BACKUP-01 | D | 完成（隔离） | lib/backup.sh | test_stage_d_backup.sh; test_stage_d_maintenance.sh; CI #103 | ID/路径/类型/权限/哈希/状态 schema 校验，0600 payload 与 0700 目录；真实磁盘损坏/空间压力待 VPS |
| BACKUP-02 | D | 完成（隔离/安全边界） | lib/backup.sh: backup_restore_local | test_stage_d_backup.sh | 同机恢复要求 machine-id 指纹一致，只恢复节点/线路数据并由当前核心重新渲染；当前 SSH/UFW/Fail2ban 与服务启停不被旧备份覆盖 |
| BACKUP-03 | D | 完成（隔离/迁移边界） | lib/backup.sh: backup_restore_nodes_only | test_stage_d_backup.sh | 跨机器仅允许导入到空节点状态，节点/线路强制禁用且不迁移安全状态；真实第二台 VPS 复核待最终 Gate |
| REMOVE-01 | D | 完成（隔离） | lib/remove.sh | test_stage_d_remove.sh; CI #103 | 卸载前检查未完成事务、关键文件所有权/漂移、manager/core current 一致性，并默认创建恢复备份 |
| REMOVE-02 | D | 完成（所有权边界） | lib/remove.sh | test_stage_d_remove.sh | 仅删除可证明归 AsterNode 管理的服务、核心、版本、运行状态；未知/漂移内容保留并报告 |
| REMOVE-03 | D | 完成（保守默认） | lib/remove.sh; relay-manager.sh | test_stage_d_remove.sh | 默认保留 SSH 安全策略/密钥、UFW 服务与管理员规则、Fail2ban 配置、受信发行公钥、备份和导出；备份/导出可显式单独删除 |
| PERF-01 | D/跨阶段 | 完成（架构/自动化） | lib/maintenance.sh; templates/relay-manager-maintenance.* | test_stage_d_maintenance.sh; test_stage_b_core_service.sh | 无自有常驻管理器 daemon，维护为 systemd oneshot/timer；真实长期 RSS/CPU 待 VPS 观察 |
| PERF-02 | D/跨阶段 | 完成（受管增长边界） | lib/maintenance.sh; lib/backup.sh | test_stage_d_maintenance.sh; CI #103 | 终态事务、备份、撤销/孤儿导出、D4 证据、旧 manager/core 版本均有保守回收；恢复状态/未知内容/当前及回退版本受保护 |
| PERF-03 | D/跨阶段 | 完成（可观测/边界） | lib/maintenance.sh: maintenance_status_json | test_stage_d_maintenance.sh | 报告磁盘与受管目录增长；不改 system journal / Fail2ban 全局 logrotate，Xray access log 默认关闭；低配 VPS 长期压力仍待实机 |
| TEST-01 | A/跨阶段 | 完成当前阶段自动化 | tests/run.sh; .github/workflows/ci.yml | CI #103: 27/0/0; bash -n; ShellCheck; pinned Xray parse | 真实 systemd/网络/SSH/UFW/Fail2ban/更新恢复仍属于 TEST-02 |
| TEST-02 | A/跨阶段 | 待最终统一实机验收 | docs/STAGE_B_REAL_VPS_CHECKLIST.md; docs/STAGE_C_REAL_VPS_CHECKLIST.md; docs/STAGE_D_REAL_VPS_CHECKLIST.md | — | A-D 代码/隔离自动化已收尾，下一 Gate 为可恢复 VM/VPS 统一真实验收 |
| TEST-03 | A/跨阶段 | 完成验收记录框架 | docs/TEST_REPORT.md; docs/STAGE_B_REAL_VPS_CHECKLIST.md; docs/STAGE_C_REAL_VPS_CHECKLIST.md; docs/STAGE_D_REAL_VPS_CHECKLIST.md | Stage A-D 自动化 + CI #103 | 每个真实 case 仍需镜像/架构/版本/命令/结果/脱敏证据 |
| TEST-04 | A/跨阶段 | 待最终 Gate | docs/TEST_REPORT.md; docs/STAGE_*_REAL_VPS_CHECKLIST.md | CI #103 为当前自动化基线 | B/C/D checklist 的真实门槛全部通过后，才能进入首个发布候选版本判定 |
