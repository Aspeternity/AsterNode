# AsterNode 测试报告

- 报告日期：2026-10-03
- 管理器版本：0.2.0-dev
- 当前阶段：Stage C 安全模块代码/隔离自动化收尾完成；真实 VPS Gate 按计划延后到 A-D 全部开发完成后的统一验收
- Stage C 功能稳定基线：`bd4d10d0a7bc4903a0209f06c7e2c9a25c5a7f69`
- GitHub Actions：#88，`success`
- 生产凭据：未使用

## CI #88 结果

`dev/stage-c-security` 的 GitHub Actions #88：

```text
unit-and-static     success
stage-b-real-xray   success

Summary: passed=21 failed=0 skipped=0
bash -n: PASS
shellcheck: PASS
Xray v26.3.27 server/client config parse: PASS
```

固定 Xray 的真实二进制配置解析仍然只是配置级证据，不等于 T24/T25 的实际网络代理链。Stage C 的 SSH/UFW/Fail2ban 测试主要使用隔离根目录和受控 systemd/UFW/Fail2ban 适配层，也不能替代真实远程登录、防火墙和封禁效果。

## Stage C 自动化证据

| case_id | 需求 | 自动化内容 | 结果 |
|---|---|---|---|
| C01 | SSH-01/02/06 | ssh/sshd service/socket、Include/Match/cloud-init、启动参数覆盖、sshd -T -C 有效策略、外部认证/MFA/CA 阻断 | 通过（隔离/逻辑） |
| C02 | SSH-03/04/07/08 | 公钥/私钥校验、材料去重、fingerprint inventory、最后已验证入口删除保护、无复用/无密码回退验证命令 | 通过（隔离） |
| C03 | SSH-05/09/10/11/12/13 | Root/sudo 前置、双端口迁移、UFW 先放行、回滚 timer、boot guard、pending confirm/rollback、控制台恢复说明 | 通过（隔离/流程） |
| C04 | FW-01/02/03 | UFW 环境完整性/复杂网络拒绝、显式保留业务端口、规则所有权、幂等与精确删除 | 通过（隔离） |
| C05 | FW-04/05/06/07/08/09 | 白名单 allow+deny、冲突拒绝、IPv6 边界、未实施/未验证状态、临时开放/到期回收/boot guard | 通过（逻辑/隔离） |
| C06 | F2B-01/02 | 推荐逻辑、现有 sshd jail 冲突、file/systemd backend、依赖、UFW banaction、SSH 实际端口 | 通过（隔离） |
| C07 | F2B-03/04 | 配置/服务/jail/日志源健康、ban 列表/unban、显式 ignore、managed jail 增长策略、只停受管 jail | 通过（接口/隔离） |
| C08 | TEST-01 | 全部 unit、Bash syntax、ShellCheck、固定 Xray 真实配置解析 | 通过 |

## T05-T20 / T26 当前结论

这些用例是 Stage C 的主要真实门槛。按当前计划，代码与自动化先收尾，真实 SSH/UFW/Fail2ban 故障注入统一放到最终 A-D 实机验收。

| 用例 | 当前结论 | 说明 |
|---|---|---|
| T05 | 部分验证 | Include/Match/cloud-init/启动参数覆盖与有效策略检测已自动化；真实发行版/目标用户组合待 VPS |
| T06 | 部分验证 | 双端口事务与移除旧口前确认流程已测；普通 ssh.service 的真实新连接待 VPS |
| T07 | 未执行 | ssh.socket 真实监听、迁移和重启顺序必须在 VM/VPS 验证 |
| T08 | 部分验证 | 到期回滚与“本机不证明云侧可达”流程已实现；云安全组阻挡场景待 VPS |
| T09 | 部分验证 | 仅存在 key 文件不能直接关闭密码，必须记录新连接验证；“key 存在但认证失败”需真实连接 |
| T10 | 部分验证 | 当前没有基于 SSH_CONNECTION 的自动成功判定，人工验证命令禁用复用/回退；旧连接复用攻击需实机 |
| T11 | 部分验证 | 禁 Root 需要非 Root 已验证 key + 实际 SUDO_USER 证明；完整新连接/sudo 链待 VPS |
| T12 | 部分验证 | timer/rollback/boot guard 已隔离测试；真实断线、kill、超时持续执行待 VPS |
| T13 | 部分验证 | boot guard 在 SSH 服务/socket 前声明恢复；真实 reboot 顺序待 VPS |
| T14 | 未执行 | confirm 与 timeout 同时发生的真实并发故障注入尚未完成 |
| T15 | 部分验证 | UFW enable 只保留自动检测 SSH + 显式 --preserve-port；真实业务连通性待 VPS |
| T16 | 部分验证 | 非受管公网 ALLOW/LIMIT 冲突会拒绝自动白名单；真实 UFW/底层规则对账待 VPS |
| T17 | 部分验证 | 默认策略、framework 漂移和受管 deny 逻辑已覆盖；更早规则的实际生效顺序待 VPS |
| T18 | 未执行 | IPv4/IPv6 双栈允许/拒绝对照必须真实网络测试 |
| T19 | 部分验证 | 复杂 firewall 环境进入拒绝/未验证，不虚假显示成功；真实 Docker/firewalld/nftables 场景待 VPS |
| T20 | 部分验证 | 临时开放、到期精确删除和 Xray 前 boot reconcile 已实现；真实重启与 UUID 认证待 VPS |
| T26 | 部分验证 | backend/jail/log source/ban-unban 接口已测试；真实 Fail2ban 触发封禁与解封仍需隔离 VM/VPS |

## Stage B 仍待真实门槛

Stage C 收尾不改变 Stage B 的网络 Gate。以下仍必须实测：

1. 受管 Xray 的真实 systemd 生命周期、权限、重启和开机自启。
2. IPv4、双栈、IPv6-only、NAT。
3. 外部 Xray/3x-ui/Nginx 共存不接管。
4. T24 真实客户端使用生成 URI/outbound 建连。
5. T25 真实 3x-ui 线路 VPS → 落地 → Internet 完整代理链。
6. UUID 删除/轮换后的新连接拒绝与既有连接语义。

执行格式见 `docs/STAGE_B_REAL_VPS_CHECKLIST.md`。

## Stage C 最终实机 Gate

执行格式见 `docs/STAGE_C_REAL_VPS_CHECKLIST.md`。完成前不能把 Stage C 的安全能力标为“真实环境最终验收通过”，尤其不能把本地规则存在当作来源隔离成功，也不能把保留旧终端当作新 SSH 入口可用的证据。

## 当前结论

Stage C 的**代码/隔离自动化开发已收尾**，稳定功能基线为 `bd4d10d` / CI #88。由于用户选择在整个 A-D 开发完成后统一验收，Stage C 的真实安全 Gate 暂不执行，所有未执行项保持显式未验证状态。下一开发阶段为 Stage D。
