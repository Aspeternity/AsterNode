# Stage B 审查交接

## 当前基线

- 项目仓库：`Aspeternity/AsterNode`
- 版本：`0.2.0-dev`
- 分支：`dev/stage-b-node-continuation`
- 自动化稳定基线：`0a5be45ae50b56e46729f65c50ea01020f9bfa22`
- GitHub Actions：#59，`success`
- CI：`18 passed / 0 failed / 0 skipped`；Bash syntax / ShellCheck 通过；固定 Xray v26.3.27 服务端/客户端配置解析通过

> 后续文档提交会使 HEAD 前移；审查功能基线时仍可从上述 SHA 与 CI #59 对照。

## Stage B 已实现

1. 固定兼容矩阵 Xray 下载/摘要/归档安全检查。
2. 独立 `rm-xray` 用户、受管 service 与维护 timer。
3. VLESS + RAW/TCP + REALITY / `xtls-rprx-vision` 配置生成。
4. 节点/线路机生命周期、独立 UUID、共享来源引用、UUID/REALITY 密钥轮换。
5. 运行配置 candidate 测试、漂移拒绝、事务回滚框架。
6. source-add → verify → source-remove 的来源迁移模型。
7. 参数表、URI、单 outbound、3x-ui 映射与旧导出撤销。
8. Target 受控探测与 D1-D4 诊断/脱敏诊断包。

## 建议审查顺序

```text
compat/compatibility.json
  -> lib/core-xray.sh
  -> protocols/vless-reality.sh
  -> lib/node.sh
  -> lib/export.sh
  -> lib/target.sh
  -> diagnostics.sh
  -> tests/test_stage_b_*.sh
  -> docs/IMPLEMENTATION_MATRIX.md
  -> docs/TEST_REPORT.md
```

重点关注：

- `enabled=false` 的 JSON 布尔语义不能被默认值覆盖。
- node/upstream 普通修改不能绕过 UUID/REALITY 专用轮换流程。
- source 地址变更不能直接整组替换，必须分阶段迁移。
- state-only 事务仍需观察受管 Xray 配置摘要，避免确认后竞态覆盖。
- 旧导出在凭据或节点关键参数变化后必须撤销。
- D4 没有真实线路证据时必须保持 `unverified`。

## 尚不能验收为通过

Stage B 的最终 Gate 仍缺真实 VPS 证据：

- systemd 服务生命周期、重启与开机自启。
- IPv4 / 双栈 / IPv6-only / NAT。
- 外部 Xray/3x-ui/Nginx 共存。
- T24 真实客户端连接。
- T25 真实 3x-ui 线路 VPS 完整代理链。
- 删除/轮换凭据后的真实新连接/既有连接语义。

因此当前适合进入**Stage B 实机验收准备**，不应合并为生产完成版本。
