# Task 8 报告：libmtp 文件管理操作

> 历史归档：原路径 `.superpowers/sdd/task-8-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 在 `libmtp_bridge.h` 声明创建目录、删除路径、重命名路径和存在性检查 JSON 接口。
- 在 C bridge 中实现四个接口，并在持有 handle mutex 时完成路径解析、libmtp 调用、错误栈清理与所有失败路径的解锁。
- 创建目录从目标路径拆分父目录和名称，解析父目录后调用 `LIBMTP_Create_Folder`。
- 删除和重命名先解析 object id；重命名额外读取并释放 metadata 后调用 `LIBMTP_Set_Object_Filename`。
- 存在性检查返回兼容 `GoFileExistsResult` 的 JSON；明确的路径不存在结果为 `false`，设备或内存错误会保留为 bridge 错误。
- Swift `LibMTPBridge` 已接入四项操作。`checkFilesExist` 会规范化路径、复制为 C 字符串数组，在 C 调用完成后释放所有临时内存，并按规范化路径恢复原输入顺序。
- 同时修正 Task 7 路径解析的非根路径初始 parent id：根目录使用 `LIBMTP_FILES_AND_FOLDERS_ROOT`，非根路径从 `0` 开始。

## 验证

- 通过：`MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`
- 通过：`git diff --check`
- 未能运行：`swift test` 的测试 bundle 在加载时找不到绝对 install name 指向的 `.../libmtp-1.1.23/local-install/lib/libmtp.9.dylib`。即使设置 `DYLD_LIBRARY_PATH` 仍失败；此动态链接/打包问题按任务要求留给 Task 11。
- 未能运行：`mtp-detect` 命令在当前环境不存在，因此无法进行真实设备的手动创建、重命名、删除和上传冲突扫描验收。

## 改动文件

- `Sources/CLibMTPBridge/include/libmtp_bridge.h`
- `Sources/CLibMTPBridge/libmtp_bridge.c`
- `Sources/macmtp/MTP/LibMTPBridge.swift`

## 自检与问题

- 所有新增 C 操作在已销毁或未连接状态下返回明确错误，并在每个持锁返回分支解锁。
- libmtp 操作前清空错误栈；失败时收集并清空错误栈。
- JSON 中的路径进行转义，返回结构为 `{"error":null,"data":[{"fullpath":"...","exists":true}]}`。
- 未修改动态链接策略、上传下载或进度实现。

## Reviewer 修复

- 修复 `mtp_bridge_root_parent_for_path`：所有路径（包括 `/Documents` 和 `/Documents/file.txt`）均从 `LIBMTP_FILES_AND_FOLDERS_ROOT` 开始，由后续分段解析逐段查找。
- 本次仅修改 `Sources/CLibMTPBridge/libmtp_bridge.c` 与本报告；未实现 Task 9。
