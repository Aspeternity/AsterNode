# Stage B 真实 VPS 验收清单

> 目的：补齐自动化无法证明的 systemd、网络和 3x-ui 端到端证据。所有测试应在可恢复 VM / 专用测试 VPS 上执行，禁止把生产 SSH 私钥、完整分享 URI、REALITY server privateKey 写入报告。

## 记录模板

每个 case 至少记录：

```text
case_id:
requirement_ids:
commit_sha:
os_image:
os_version:
arch:
landing_xray_version:
line_3xui_version:
line_xray_version:
network_mode: ipv4 | dual-stack | ipv6-only | nat
pre_state:
actions:
expected:
actual:
result: PASS | FAIL | SKIP | BLOCKED
evidence_files:
tested_at:
```

## B-VPS-01：受管 Xray / systemd

- 新机只读体检。
- 安装固定核心与 service。
- 确认进程用户为 `rm-xray`。
- 确认运行配置为 root:rm-xray / 0640，目录为 0750。
- 启动、停止、重启节点。
- 重启 VPS，确认 autostart 行为与维护 timer。
- 人工制造配置错误，确认 candidate 检查或运行失败不会留下半应用状态。

## B-VPS-02：外部服务不接管（T04）

分别准备：

- 外部 `xray.service` 正在运行。
- 3x-ui 正在运行并管理自己的 Xray。
- Nginx/其他程序占用候选端口。

预期：AsterNode 只报告冲突，不杀进程、不覆盖外部配置、不接管外部服务。

## B-VPS-03：网络形态

至少覆盖：

- IPv4-only。
- 双栈。
- IPv6-only。
- NAT（内部 listen_port 与外部 public_port 分开记录）。

检查监听地址族、实际可达端点和错误状态是否准确；不能因为 IPv6-only 下载失败就标“系统不支持”。

## B-VPS-04：Target

在落地 VPS 上对候选与手工 Target 运行探测，记录 DNS/TCP/TLS1.3/证书/H2/重复握手/延迟。

- HTTP 非 200 不自动判坏。
- 不自动替换节点 Target。
- Target 不得指回本节点监听端点形成循环。
- CDN/共享目标需记录未认证回落转发的滥用风险判断。

## B-VPS-05：真实客户端（T24）

使用导出的 URI 与单 outbound 分别验证：

1. 使用固定兼容 profile 的真实客户端/Xray。
2. 建立 REALITY 连接。
3. 发起真实代理请求。
4. 核对出口为落地 VPS。
5. IPv6 地址 URI 必须正确加方括号和转义。

只有配置解析成功不能记 PASS。

## B-VPS-06：3x-ui 完整链路（T25）

线路 VPS 使用实际 3x-ui：

```text
客户端/业务流量
    -> 线路 VPS / 3x-ui
    -> 生成的 VLESS + RAW/TCP + REALITY outbound
    -> 落地 VPS / AsterNode Xray
    -> Internet
```

记录：

- 3x-ui 版本。
- 线路端 Xray 版本。
- 使用的 AsterNode profile。
- 实际代理请求结果。
- 落地出口 IP（可以记录 IP，但不要记录完整 UUID/URI/privateKey）。
- D4 证据文件。

## B-VPS-07：凭据删除/轮换（T22）

- 建立一条真实连接。
- UUID 并行轮换：旧/新 UUID 在过渡期按设计工作。
- 提交轮换后，新连接使用旧 UUID 必须失败。
- 删除线路机后，新连接必须失败。
- 已建立连接可能暂时持续；报告必须区分“既有连接”和“新连接”，不要把端口仍通误判为认证仍有效。

## B-VPS-08：来源迁移

先保留旧来源：

1. `source-add NEW`
2. 从 NEW 实际建立连接并验证
3. `source-remove OLD`

Stage C 白名单实现前，只验证状态迁移/引用语义，不得声称网络层隔离已生效。

## 完成条件

Stage B 可进入最终验收结论的最低条件：

- B-VPS-01 至 B-VPS-07 有明确 PASS/FAIL/SKIP/BLOCKED。
- T24 与 T25 必须有真实网络证据。
- 无凭据泄漏。
- 无外部配置破坏。
- 无未解释的 `NEEDS_RECOVERY`。
- 所有失败/跳过项都保留原因，不能改写成“通过”。
