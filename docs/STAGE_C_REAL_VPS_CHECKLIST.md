# Stage C 真实 VM/VPS 验收清单

> 本清单用于最终 A-D 统一实机验收。Stage C 代码/隔离自动化已在 `bd4d10d` / CI #88 达到稳定基线，但本文件中的真实 SSH/UFW/Fail2ban 证据尚未执行。
>
> 只在可重装/有控制台的测试 VM/VPS 上执行。不要把生产 SSH 私钥、完整节点 URI、REALITY server privateKey 或面板密码写入报告。

## 每个 case 必填记录

- `case_id`
- `requirement_ids`
- `commit_sha`
- `os_image` / `os_version`
- `arch`
- `ssh_version`
- `systemd_version`
- `ufw_version`
- `fail2ban_version`
- `network_mode`：IPv4-only / dual-stack / IPv6-only / NAT
- `ssh_start_mode`：service:ssh / service:sshd / socket
- `pre_state`
- `actions`
- `expected`
- `actual`
- `result`：PASS / FAIL / SKIP / BLOCKED
- `evidence_files`
- `tested_at`

脱敏要求：不得记录 SSH 私钥、完整 authorized_keys 限制外的秘密、完整代理 URI、REALITY server privateKey、面板密码或历史密钥。

## C-VPS-01：SSH 有效策略与外部覆盖（T05）

覆盖 SSH-01/02/06。

1. 准备含 `Include`、`Match`、cloud-init drop-in 的 SSH 配置。
2. 分别测试普通用户与 root 的 `relay-manager ssh status USER`。
3. 验证输出与 `sshd -T -C user=...,addr=...,host=...` 一致。
4. 使用 systemd ExecStart / `SSHD_OPTS` 注入 `-f`、`-p` 或 `-o` 覆盖。
5. 期望：覆盖被识别；无法安全判定时自动收紧被拒绝，不覆盖 MFA/CA/AuthorizedKeysCommand。

## C-VPS-02：普通 SSH service 双端口迁移（T06/T08）

覆盖 SSH-09。

1. 记录当前真实 SSH 端口与云安全组/NAT。
2. 启动迁移到新端口；确认旧端口仍监听。
3. 若 UFW active，确认新 SSH 端口先放行。
4. 从**另一台机器或全新 SSH 进程**按生成命令连接新端口，禁用连接复用与密码回退。
5. 只有新连接成功后执行 `ssh confirm`。
6. 再单独执行移除旧端口事务并验证。
7. 反向测试：故意不放行云安全组新端口，等待保护到期。
8. 期望：不能提交假成功；本机配置恢复到此前已验证入口；控制台恢复说明准确。

## C-VPS-03：ssh.socket 与重启恢复（T07/T13）

覆盖 SSH-11/12。

1. 在使用 `ssh.socket` 的可恢复 VM 上执行端口迁移。
2. 验证实际 socket 监听、service 启动机制未被静默切换。
3. 在 APPLIED_PENDING 状态直接 reboot。
4. 启动后检查 boot guard 是否在 SSH 接受连接前恢复最后已提交配置。
5. 验证旧入口可用，未验证新策略没有跨重启继续生效。

## C-VPS-04：公钥、密码与 Root 收紧（T09/T10/T11）

覆盖 SSH-03/04/05/07/08/10。

1. 添加新公钥，记录 fingerprint。
2. 构造“authorized_keys 中存在，但实际认证失败”的 key/权限/选项场景。
3. 期望：不能因此关闭密码。
4. 验证连接复用/旧 master socket 不能替代全新连接证明。
5. 两把已验证 key 时删除一把应成功；删除最后一个当前仍存在的已验证 key 应被阻止。
6. 非 root 管理用户完成全新 key 登录与真实 `sudo relay-manager ssh verify-sudo USER`。
7. 未完成上述验证时禁 Root 必须被阻止；完成后再验证 Root 策略。

## C-VPS-05：SSH 保护故障注入（T12/T14）

覆盖 SSH-09/10/11/12。

分别在待确认事务中：

1. 关闭发起变更的终端。
2. kill 管理器进程。
3. 等待绝对截止时间。
4. 在确认与超时临界点并发执行 confirm / rollback。
5. 检查 transaction.json 最终状态只有一个，不重复回滚、不覆盖后续提交。
6. 期望：保护任务继续工作；恢复完成或明确进入 NEEDS_RECOVERY，不留下无法解释的半应用状态。

## C-VPS-06：UFW 业务入口与白名单真实隔离（T15-T19）

- Debian/Ubuntu fresh UFW 的 before/after framework 完整性必须按 UCF canonical 模板 `/usr/share/ufw/iptables/*.rules` 与历史 MD5 校验；不得依赖 dpkg Conffiles，也不得把包自身合法的 `/usr/share/ufw/*.rules` 软链接误判为篡改。真正的 `/etc/ufw/*.rules` 软链接、未知本地修改或无法验证的参考元数据仍必须 fail-closed。

覆盖 FW-01~08。

1. 在 UFW inactive 的新机上同时运行 SSH 与另一个 TCP 测试服务。
2. `firewall enable --preserve-port PORT` 只保留 SSH + 明确业务端口；未确认的监听端口不得自动开放。
3. 已有 UFW 时验证不 reset、不改默认策略、不删除外部规则。
4. 构造 443 全网/网段 ALLOW，确认白名单自动接管被拒绝。
5. 构造默认允许、早期 deny/before/after、自定义规则，确认状态不会仅因“受管规则存在”就显示 verified。
6. 双栈节点分别从白名单 IPv4/IPv6 来源建立新连接，并从非白名单 IPv4/IPv6 来源尝试。
7. PASS 条件：允许来源成功，非白名单新连接均失败；此前不得标记白名单成功。
8. 在 Docker/firewalld/独立 nftables 等复杂环境确认转为只读/拒绝自动接管。

## C-VPS-07：临时公网开放与重启（T20）

覆盖 FW-09。

1. 在已验证白名单节点上执行默认 10 分钟或短测试时限的 `firewall temp-open`。
2. 验证公网新连接在时限内可建立，UUID/REALITY 认证仍生效。
3. 到期后确认只删除本次临时 allow，原白名单模式恢复。
4. 在临时开放期间 reboot，使截止时间跨重启。
5. 期望：Xray 重新服务前完成过期 reconcile；不通过全局 conntrack 清理影响其他连接。

## C-VPS-08：Fail2ban 真实日志与封禁（T26）

覆盖 F2B-01~04。

1. 分别选择至少一个 file backend 环境和一个 systemd journal 环境（若支持）。
2. 安装/应用后检查 `fail2ban-client -t`、服务 active、`sshd` jail、实际日志来源。
3. 从隔离测试来源产生足够 SSH 失败登录以触发封禁；**不要使用当前唯一管理地址作为攻击源**。
4. `fail2ban banned` 应显示被封 IP；新连接应被阻止。
5. `fail2ban unban IP` 后应恢复。
6. 显式 ignore 来源不应被封；线路机白名单不应自动进入 ignoreip。
7. 停用受管 jail 后，管理员其他 jail 必须保持。
8. 记录数据库/日志增长观察值；确认 AsterNode 没有修改全局数据库保留或系统 logrotate。

## Stage C Gate 完成条件

以下全部满足后，Stage C 才可从“代码/自动化收尾”提升为“真实环境最终通过”：

- T05-T20 与 T26 均有 PASS，或有明确且合理的 N/A/SKIP 说明。
- 无 SSH 锁死或无法恢复的未受保护修改。
- 无“规则存在即白名单成功”的虚假结论。
- service 与 socket 启动模式的恢复顺序均有证据。
- 双栈来源隔离有允许/拒绝真实对照。
- Fail2ban 有真实日志消费、封禁和解封证据。
- 无生产凭据进入日志、测试报告或诊断包。
- 失败项保留原始脱敏证据，不以修改测试期望代替修复。
