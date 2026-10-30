# Task 4 报告：CLibMTPBridge C target 骨架

> 历史归档：原路径 `.superpowers/sdd/task-4-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 新增 `CLibMTPBridge` SwiftPM C target，并将其加入 `macmtp` 可执行 target 的依赖。
- 增加通过 `MACMTP_LIBMTP_ROOT` 和 `MACMTP_LIBMTP_LIB_DIR` 覆盖的 libmtp include、library 搜索路径及链接 flags。
- 新增公开 C 头文件、Clang module map 与最小桥接实现。
- 提供 `mtp_bridge_create`、`mtp_bridge_destroy`、`mtp_bridge_last_error` 和 `mtp_bridge_free_string` 接口；创建与销毁处理 `LIBMTP_Init` 和设备释放。

## 测试结果

执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build
```

结果：通过，退出码 `0`。`CLibMTPBridge libmtp_bridge.c` 已编译，`macmtp` 已完成链接。

链接输出包含已知警告：libusb、libmtp、libgcrypt 和 libgpg-error 动态库的最低 macOS 版本为 26.0，高于本包目标版本 macOS 14.0；未影响本次构建成功。

## TDD Evidence

本任务仅新增 C target 骨架和声明接口，简报未要求新增测试 target 或运行时连接 API 测试。以完整 SwiftPM build 作为验证：该 build 同时验证 C 头文件、module map、libmtp include path、链接 flags，以及 Swift 可执行 target 对 C target 的依赖。

## 改动文件

- `Package.swift`
- `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- `Sources/CLibMTPBridge/libmtp_bridge.c`
- `Sources/CLibMTPBridge/module.modulemap`
- `.superpowers/sdd/task-4-report.md`

## 自检

- 公共头文件与实现均包含全部四个指定 C API。
- 不透明 `mtp_bridge_handle_t` 类型仅在 C 实现中定义。
- `mtp_bridge_destroy(NULL)` 安全返回，并在存在设备时释放设备。
- `mtp_bridge_last_error(NULL)` 返回静态错误文本。
- `git diff --check` 通过。

## 问题

- 无阻塞问题。
- 构建保留上述已知 macOS 版本链接警告。
