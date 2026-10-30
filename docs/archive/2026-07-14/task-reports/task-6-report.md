# Task 6 报告

> 历史归档：原路径 `.superpowers/sdd/task-6-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 新增 `LibMTPBridge` actor，持有 Task 5 的 C bridge 句柄，支持连接、设备信息读取、存储列表读取与 JSON 解码。
- 为 Swift 6 actor 析构隔离限制，将非 Sendable C 指针封装在私有 `@unchecked Sendable` 所有权对象中，由其析构调用 `mtp_bridge_destroy`；公开 Swift API 保持不变。
- 目录、文件与传输协议方法保留明确的未实现错误，未进入 Task 7+ 范围。
- `MTPBridgeFactory` 的 `.libmtp` 分支现在返回 `LibMTPBridge.shared`。
- 新增设备信息 JSON 解码测试。

## 测试结果

- 红灯：`MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test --filter LibMTPBridgeDecodeTests` 在 actor 创建前失败，报 `cannot find 'LibMTPBridge' in scope`。
- 绿灯：同一命令完成构建后，因外部 `libmtp.9.dylib` 的绝对 install name 指向不存在的 `local-install/lib` 而无法加载测试 bundle。
- 将仅位于 `.build` 的测试二进制加载路径改指向实际 `src/.libs/libmtp.9.dylib` 后，执行 `swift test --skip-build --filter LibMTPBridgeDecodeTests`：1 个测试通过，0 个失败。
- 构建链接期间仍有 macOS deployment target 与 Homebrew dylib 版本不一致的既有警告。

## TDD Evidence

- 先创建 `testDecodeDeviceInfoJSON`，并在未实现 actor 时运行，确认其因缺少 `LibMTPBridge` 而失败。
- 最小实现 `decode` 与 actor 骨架后，测试成功运行并通过 JSON 模型断言。

## 改动文件

- `Sources/macmtp/MTP/LibMTPBridge.swift`
- `Sources/macmtp/MTP/MTPBridgeFactory.swift`
- `Tests/macmtpTests/LibMTPBridgeDecodeTests.swift`
- `.superpowers/sdd/task-6-report.md`

## 自检

- `LibMTPBridge` 符合 `MTPBridgeProtocol`。
- `.libmtp` factory 选择已切换至对应单例。
- C 返回的字符串在 Swift 读取后调用 `mtp_bridge_free_string`。
- 不包含 Task 7+ 的目录、文件或传输实现。

## 问题

- 外部 libmtp 构建产物的 dylib install name 指向不存在路径，导致原始指定命令在测试 bundle 加载阶段失败；这是环境/依赖构建问题，不是 Task 6 测试或 Swift 实现失败。验证时只修改了未跟踪的 `.build` 测试二进制。

## Reviewer Fix

- 修复 `initialize()` 连接失败处理：现在抛出 `KalamError.operationFailed(lastError())`，保留 C bridge 返回的具体错误信息。
- 未修改 C、`Package.swift`、UI，也未实现 Task 7+ placeholder。
