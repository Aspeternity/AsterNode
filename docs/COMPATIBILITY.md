# 兼容性状态

## 管理器目标矩阵

| 系统 | 架构 | 当前证据 |
|---|---|---|
| Debian 12 | x86_64 / ARM64 | 自动化逻辑存在；真实 systemd/VPS 未执行 |
| Debian 13 | x86_64 / ARM64 | 开发容器曾为 Debian 13 x86_64，但无 systemd；不能替代 VPS |
| Ubuntu 22.04 | x86_64 / ARM64 | 未实测 |
| Ubuntu 24.04 | x86_64 | GitHub Actions #59 在 Ubuntu 24.04 runner 完成脚本/配置级测试；不是完整 VPS |
| Ubuntu 24.04 | ARM64 | 未实测 |

目标网络：IPv4、双栈、IPv6-only、NAT。Stage B 已有地址族/外部端点模型，但没有完成真实网络矩阵。

## Xray 固定 profile

当前默认固定核心：`v26.3.27`。

- amd64 官方资产 SHA-256：`23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae`
- arm64 官方资产 SHA-256：`4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c`
- CI #59 在 amd64 上实际下载并校验固定摘要，服务端与客户端 JSON 均通过真实 Xray `run -test -config`。
- arm64 尚没有对应架构的真实执行证据。

这证明固定 profile 的**配置字段可被该核心解析**，不证明 T24/T25 的实际 REALITY 建连与 3x-ui 链路已经通过。

## 3x-ui

当前只提供字段语义映射和单 outbound/路由合并说明：

- 不保存面板密码。
- 不调用远程 3x-ui API。
- 不承诺“一键粘贴即可用”。
- 必须记录真实面板版本、线路端 Xray 版本以及代理请求出口，才能把对应组合标为已验证。

## 声明原则

- 未实测组合不标“支持已验证”。
- 配置解析通过不等于网络互操作通过。
- 预发布核心不作为默认更新目标。
- profile 与具体 Xray 版本绑定，不向历史/未来版本外推。
