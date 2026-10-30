# Task 5 报告：libmtp 连接、设备信息和存储列表

> 历史归档：原路径 `.superpowers/sdd/task-5-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 在公开 C 头文件中声明 `mtp_bridge_connect`、`mtp_bridge_disconnect`、`mtp_bridge_device_info_json` 和 `mtp_bridge_storages_json`。
- 实现首个原始 MTP 设备的探测、连接、断开和错误状态维护。
- 实现设备信息 JSON，返回制造商、型号、设备版本和序列号，并正确释放 libmtp 返回的字符串。
- 实现存储列表 JSON，包含存储 ID、容量、剩余空间和已转义的描述文本。
- 增加 NULL 安全、分配失败处理和完整 JSON 字符串转义，返回的 JSON 可使用 `mtp_bridge_free_string` 释放。
- 当前 libmtp 1.1.23 使用 `VolumeIdentifier` 与 `FreeSpaceInObjects` 字段；bridge 分别将其映射到约定 JSON 字段 `VolumeLabel` 与 `FreeSpaceInImages`。

## 测试结果

执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build
```

结果：通过，退出码 `0`。`CLibMTPBridge libmtp_bridge.c` 已编译，`macmtp` 已完成链接。

## TDD Evidence / 构建验证

- 本任务的连接与设备查询依赖物理 MTP 设备，简报未要求引入 mock 或测试 target。
- 以完整 SwiftPM build 验证 C 头文件导出、libmtp API 字段适配、C 编译和最终链接。
- 额外执行 `git diff --check`，通过。

## 改动文件

- `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- `Sources/CLibMTPBridge/libmtp_bridge.c`
- `.superpowers/sdd/task-5-report.md`

## 自检

- 所有新增 API 对 NULL handle 安全；未连接时 JSON API 返回 NULL 并记录错误。
- 原始设备数组和设备信息字符串在所有成功/失败路径均被释放。
- JSON 分配、格式化和扩容失败均返回 NULL，且不会解引用 NULL。
- 字符串中的引号、反斜杠及 ASCII 控制字符会被转义，确保 JSON 合法。
- `git diff --check` 通过。

## 问题

- 无阻塞问题。
- 链接输出仍有已知警告：libusb、libmtp、libgcrypt 和 libgpg-error 动态库的最低 macOS 版本为 26.0，高于包目标 macOS 14.0。按用户裁决保留现有链接策略，Task 11 处理打包风险。

## Review 第二轮修复（C handle 生命周期）

### 修复内容

- 为 `mtp_bridge_handle` 增加 `destroyed` 状态。
- `mtp_bridge_destroy` 在 mutex 锁内仅释放底层 MTP device，随后设置 `destroyed=1` 并写入稳定错误 `libmtp bridge handle is destroyed`。
- 销毁后不再销毁 mutex 或释放 handle；保留小型 handle/mutex 存储，避免等待 mutex 的并发调用或已持有 `mtp_bridge_last_error` 内部指针的调用访问已释放内存。Swift 单例生命周期下这是一处进程生命周期的一次性小对象保留。
- `connect`、`disconnect`、设备信息查询和存储查询均在持锁后检查 `destroyed`，销毁后不会访问 `device`；`last_error` 继续返回稳定的内部错误字符串。
- 保留上一轮的 libmtp error stack 汇总和 JSON 分配失败处理。

### 测试结果

执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build
git diff --check
```

结果：均通过，退出码 `0`。构建输出仅包含既有的 libusb、libmtp、libgcrypt 和 libgpg-error 最低 macOS 版本链接警告。

## Review 第三轮修复（Important finding）

### 修复内容

- 将 `LIBMTP_Get_Storage` 的失败判断从 `!= 0` 改为 `< 0`。
- 按 libmtp 1.1.23 契约保留返回 `1` 的成功路径，使其继续遍历 `device->storage` 并生成 JSON。
- 未处理 reviewer 指出的 `last_error` 内部指针 Minor 问题，当前 Swift actor 串行调用下记录为低风险。

### 测试结果

执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build
git diff --check
```

结果：均通过，退出码 `0`。构建输出仅包含既有的 libusb、libmtp、libgcrypt 和 libgpg-error 最低 macOS 版本链接警告。

## Review 修复（Task 5 fix worker）

### 修复内容

- 为 `mtp_bridge_handle` 增加 `pthread_mutex_t`，并在所有访问 `device` 或 `last_error` 的公开 API 中持锁；`disconnect` 与 `destroy` 在同一把锁下释放设备，避免与连接或 JSON 查询并发释放。
- 新增 libmtp error stack 汇总 helper：`LIBMTP_Get_Storage` 失败时收集全部非空 `error_text` 写入 `last_error`，无错误栈时使用 `Failed to read MTP storage list`，随后调用 `LIBMTP_Clear_Errorstack`。
- 设备信息和存储列表的 JSON 转义分配失败现会释放已分配资源、设置 `last_error` 并返回 `NULL`，不再将失败静默替换为空字符串生成成功 JSON。
- 未改变 Task 4 的链接策略、Swift、UI 或 `Package.swift`。

### 测试结果

执行：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build
git diff --check
```

结果：均通过，退出码 `0`。构建输出仅包含既有的 libusb、libmtp、libgcrypt 和 libgpg-error 最低 macOS 版本链接警告。
