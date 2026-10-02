# Relay Manager 测试报告

- 报告日期：2026-10-02
- 管理器版本：0.1.0-dev
- 当前阶段：A 基础
- 测试位置：隔离开发容器
- 开发容器：Debian 13 (trixie), x86_64
- systemd：容器内未运行
- 生产凭据：未使用

## 阶段 A 自动化结果

执行命令：

```bash
./tests/run.sh
```

最近一次结果：

```text
passed=11 failed=0 skipped=1
```

跳过项：本地开发容器未安装 `shellcheck`。仓库 CI 已配置在 Ubuntu runner 安装 ShellCheck 并执行 `shellcheck -S error -x`；在 CI 真正运行成功前，不把 ShellCheck 记为已通过。

| case_id | 需求 | 前置状态 / 操作 | 预期 | 实际 | 结果 |
|---|---|---|---|---|---|
| A01 | ENV-01/02 | `RM_ROOT` Debian 12 fixture 运行 `system_probe_fast`，前后快照 | 不写文件；读取 OS/内存/systemd/包管理信息；网络探测标未验证 | fixture 前后完全一致 | 通过 |
| A02 | UX-03 | 无控制 TTY (`setsid`) 执行 `quick-deploy` | 退出码 10；不创建受管状态 | 符合 | 通过 |
| A03 | ARC-02 | `protocols/vless-reality.sh describe` | 声明 7 个规定接口 | 7 个接口齐全 | 通过 |
| A04 | DATA-01/03 | 初始化状态两次、共享来源引用增删、非法重复 ID 更新 | 幂等；共享引用正确；非法状态拒绝且原文件不变 | 符合 | 通过 |
| A05 | ENV-01 | 已存在 state + committed transaction 后运行 `status`，前后快照 | status 仍完全只读 | 符合 | 通过 |
| A06 | SEC-01 | `RM_ROOT/etc` 设置为指向外部目录的符号链接后初始化状态 | 拒绝写入，外部目录不产生文件 | 符合 | 通过 |
| A07 | TX-01/03/05 | staged file 应用、提交、回滚；检查 transaction/snapshot/staged 权限 | 原子替换；0600/0700；可恢复旧内容 | 符合 | 通过 |
| A08 | TX-01/05 | 确认后、应用前人工修改目标 | 拒绝过期计划，不覆盖外部变化 | 返回 10，外部内容保留 | 通过 |
| A09 | TX-04 | APPLIED_PENDING 启动恢复；模拟 mv 后日志未更新的 kill-window | 恢复最后已知内容 | 两种情况均回滚 | 通过 |
| A10 | TX-05 | 应用后第三方再次改文件，再请求回滚 | 不覆盖第三方内容，标 NEEDS_RECOVERY | 返回 21，第三方内容保留 | 通过 |
| A11 | TX-02 | 一个进程持有 flock，另一个开始事务 | 后者等待；并发事务不能同时应用 | 等待约 1 秒；冲突事务返回 10 | 通过 |
| A12 | 安装入口/幂等 | `RM_ROOT` 下两次 `install.sh --install-source` | 单一版本目录、内容稳定、post-status 不创建 state | 符合 | 通过 |

> `tests/run.sh` 的“passed”按测试脚本和静态检查项计数；上表将一个脚本内的多个安全断言拆成了独立证据项，因此编号数量与 runner 的 passed 数不要求一一相等。

## T01-T36 当前结论

开发规格要求 T01-T36 作为首版最终门槛。阶段 A **没有**将 fixture/unit test 冒充真实 VPS 证据。

| 用例 | 当前结论 | 原因 / 已有证据 |
|---|---|---|
| T01 | 部分验证，未最终通过 | A01 证明 fixture 下只读；仍需受支持新机实测 |
| T02 | 部分验证，未最终通过 | 状态/安装幂等已测；UUID/密钥/规则幂等属于 B/C |
| T03 | 部分验证，未最终通过 | 非 TTY 已测；完整交互取消路径仍需各模块覆盖 |
| T04 | 未最终执行 | 环境检测已识别相关进程；真实外部 Xray/3x-ui/Nginx 不接管需 B 实测 |
| T05-T28 | 未执行 | 属于 B/C 或真实系统集成阶段 |
| T29 | 部分验证，未最终通过 | A11 验证锁与冲突事务；仍需真实并发业务事务 |
| T30 | 未执行 | 磁盘/inode/包管理锁故障注入待系统集成 |
| T31 | 部分验证，未最终通过 | A08/A10 验证事务级漂移；运行 Xray 配置漂移待 B |
| T32 | 部分验证，未最终通过 | 符号链接/受管路径已测；恶意归档和更多输入在 D 继续 |
| T33-T36 | 未执行 | 属于 D 与长时实测 |

## 未执行的真实环境矩阵

以下仍必须在可恢复 VM / 专用测试 VPS 完成，当前不能声明支持证据已经满足：

- Debian 12/13、Ubuntu 22.04/24.04 × x86_64/ARM64。
- 普通 `ssh.service` 与实际支持的 `ssh.socket`。
- IPv4、双栈、IPv6-only、NAT、复杂/已有 UFW。
- 256 MiB / 512 MiB / 1 GiB 资源档。
- 至少一台真实 3x-ui 线路 VPS 的 REALITY 认证与代理请求。
