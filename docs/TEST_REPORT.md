# AsterNode 测试报告

- 报告日期：2026-10-03
- 管理器版本：0.2.0-dev
- 当前阶段：B 节点（自动化/配置级已进入稳定基线；真实 VPS 门槛未完成）
- 稳定基线提交：`0a5be45ae50b56e46729f65c50ea01020f9bfa22`
- GitHub Actions：#59
- 生产凭据：未使用

## CI #59 结果

GitHub Actions #59 在 `dev/stage-b-node-continuation` 上完成：

```text
unit-and-static     success
stage-b-real-xray   success

Summary: passed=18 failed=0 skipped=0
bash -n: PASS
shellcheck: PASS
Xray v26.3.27 server config: Configuration OK
Xray v26.3.27 client config: Configuration OK
```

固定 Xray 资产：

- amd64: `Xray-linux-64.zip`
- SHA-256: `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae`
- CI 实际输出：`Xray 26.3.27 ... linux/amd64`

这里的“真实 Xray”仅表示 CI 下载官方固定摘要二进制并让服务端/客户端 JSON 通过 `xray run -test -config`；**不等于 T24/T25 的真实网络连接。**

## Stage B 自动化证据

| case_id | 需求 | 自动化内容 | 结果 |
|---|---|---|---|
| B01 | NODE-01/03 | VLESS + RAW/TCP + REALITY 渲染、UUID/X25519/Short ID、IPv6 URI、重复 UUID/回环 Target 拒绝 | 通过 |
| B02 | NODE-04 / EXPORT-03 | 固定 Xray v26.3.27 服务端/客户端配置真实核心解析 | 通过 |
| B03 | NODE-05/08 | rm-xray 单独用户、systemd 模板、维护 timer、归档符号链接拒绝 | 通过（隔离） |
| B04 | NODE-06/07 / UP-01/02/04 | 多线路机、共享来源引用、启停删除、最后节点与无凭据边界 | 通过 |
| B05 | UP-03/05/06 | UUID 并行轮换/到期回收、REALITY 密钥轮换、旧导出撤销 | 通过（逻辑） |
| B06 | UP-07 | source-add → source-remove 迁移、IPv4/IPv6/CIDR 规范化、共享引用计数 | 通过（逻辑） |
| B07 | DATA-03 / TX-01 | 受管 Xray 配置摘要漂移拒绝静默覆盖；state-only 事务观察运行配置 | 通过 |
| B08 | EXPORT-01/02/04 | 参数表、单 outbound、分享 URI、3x-ui 字段映射、0600、privateKey 不导出 | 通过 |
| B09 | TARGET-* | Target 格式/回环拒绝、有限超时、重复握手、受控并发、非 200 不自动判坏 | 通过（隔离/失败路径） |
| B10 | DIAG-01/02 | D1-D4 分层、旧 D4 证据失效、0600 脱敏诊断包、默认不联网/不上传 | 通过 |
| B11 | SEC-01 | 危险 ZIP 路径/符号链接、凭据泄漏回归 | 通过 |
| B12 | TEST-01 | Bash syntax + ShellCheck + 全部 unit 脚本 | 通过 |

## T01-T36 当前结论

自动化证据不能替代规格要求的真实 VPS 证据。当前与 Stage B 直接相关的状态：

| 用例 | 当前结论 | 说明 |
|---|---|---|
| T02 | 部分验证 | 节点重跑、凭据保护、来源引用与导出失效已自动化；真实服务规则幂等仍待 VPS |
| T04 | 未最终通过 | 代码会拒绝接管外部 Xray；真实外部 Xray/3x-ui/Nginx 共存需 VPS |
| T18 | 未执行 | IPv4/IPv6 白名单属于 Stage C，但 Stage B 已完成地址模型 |
| T21 | 部分验证 | 两线路机共享出口、独立 UUID/引用模型通过；真实 NAT 出口未验证 |
| T22 | 部分验证 | 删除/撤销逻辑通过；“现有连接可能持续、新连接失败”需真实连接验证 |
| T23 | 部分验证 | Target 失败/格式/回环自动化通过；真实候选质量需在目标 VPS 测量 |
| T24 | **未最终通过** | URI/outbound 可被固定 Xray 解析；尚未由真实客户端建立连接 |
| T25 | **未执行** | 仍需至少一台真实 3x-ui 线路 VPS 完成认证、代理请求与落地出口核对 |
| T27 | 部分验证 | 固定 Xray 下载摘要/归档安全有覆盖；正式发行签名归 Stage D |
| T28 | 部分验证 | candidate 配置失败/事务回滚有自动化；真实 systemd 启动失败回滚待 VPS |
| T31 | 部分验证 | 运行配置外部漂移检测已自动化；真实服务现场仍需对账测试 |
| T35 | 部分验证 | 导出/诊断凭据脱敏与权限有自动化；长期增长/日志轮转待 D |
| T36 | 未执行 | 资源档与长时运行仍需真实环境 |

## Stage B 实机门槛

阶段 B 还不能宣布最终通过，剩余阻断项集中在真实 VPS：

1. 真实 systemd 下安装/启动/重启/开机自启与 rm-xray 权限。
2. IPv4、双栈、IPv6-only、NAT 的监听和外部端点行为。
3. 外部 Xray/3x-ui/Nginx 共存时不接管、不杀进程。
4. T24：真实客户端使用生成 URI / outbound 建连。
5. T25：真实 3x-ui 线路 VPS → 落地节点 → 代理请求 → 落地出口核对。
6. UUID 删除/轮换后的新连接拒绝与既有连接语义。

具体执行与记录格式见 `docs/STAGE_B_REAL_VPS_CHECKLIST.md`。
