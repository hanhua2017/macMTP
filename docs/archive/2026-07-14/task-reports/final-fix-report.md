# 最终审查修复报告

> 历史归档：原路径 `.superpowers/sdd/final-fix-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 修复内容

1. Critical: 下载覆盖保护
   - `LibMTPBridge.downloadFiles` 现在先将每个文件下载到目标目录中的 UUID 临时文件。
   - C bridge 成功返回后，使用同一文件系统上的 `rename` 原子替换最终路径；bridge 失败或替换失败时，`defer` 清理临时文件，既有目标文件保持不变。

2. Critical: LibMTP 进度计数
   - 进度上下文携带上传本地文件大小或下载的远端元数据大小。
   - `LibMTPTransferProgressMapper` 将 `sent` 钳制到真实文件大小，并以真实文件大小生成 `total` 和 `progress`，因此进度不会超过 1。
   - `FileTransferService` 不再因进度回调达到文件大小而标记条目完成；仅在 bridge 调用成功返回后由队列逻辑标记完成。
   - 新增 `LibMTPProgressTests.testProgressMapperClampsPTPFramingToFileSize`。

3. Important: 上传覆盖语义
   - C bridge 在目标目录中检测同名对象。不存在同名对象时保持原上传路径。
   - 存在同名文件时，先以唯一临时名称上传；上传成功后查找临时对象、删除旧对象，再将临时对象改名为目标名称。
   - 上传失败时不会删除旧对象；同名目录不会被文件覆盖。

4. Important: 存储 JSON UInt32 解码
   - `LIBMTP_Get_Storage == 1` 的成功降级路径中，`FreeSpaceInObjects == UINT64_MAX` 现在映射为 `0`。
   - 其他超过 `UInt32` 范围的值映射为 `UINT32_MAX`，保证 `FreeSpaceInImages` 可被 Swift `UInt32` 解码。

5. Important: macOS 14 release 保护
   - `scripts/build.sh` 在 release bundle 复制运行时 dylib 后使用 `xcrun vtool -show-build` 读取每个 bundled dylib 的 `minos`。
   - 任一运行库高于 macOS 14.0 时，release 构建失败并提示以 `MACOSX_DEPLOYMENT_TARGET=14.0` 重建依赖。
   - 更新验证文档，不再把当前 minos 26.0 依赖构建出的 bundle 说明为 macOS 14 可用。

6. Minor: 后端切换说明
   - README、中文 README 和 LibMTP 验证文档均说明切换 MTP Engine 后需要重启应用。

## 验证

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。链接器仍报告第三方运行库最低 macOS 版本为 26.0；该问题由 release 校验阻止发布。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test --filter LibMTPProgressTests`：测试源码和 bundle 编译通过，但测试 bundle 因既有绝对 install name 找不到 `.../libmtp-1.1.23/local-install/lib/libmtp.9.dylib` 而无法加载。未伪造通过结果。
- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" MACMTP_KALAM_DIR="$PWD/../../../openmtp/ffi/kalam/native" ./scripts/build.sh release --arch arm64`：按预期失败。`libusb.dylib` 的 `minos 26.0` 高于 14.0，脚本要求以 `MACOSX_DEPLOYMENT_TARGET=14.0` 重建依赖。

## 未执行项

- 当前环境没有可用 MTP 设备，未执行真实设备上传、下载或覆盖测试。

---

## 第二轮最终审查修复

### 1. Critical: bridge 异常后的传输状态与延迟进度回调

- `FileTransferService` 在一个 chunk 的 bridge 调用失败时，将该 chunk 内所有未完成条目都标记为失败；不再以 `bytesTransferred < fileSize` 作为条件。因此 `.transferring` 条目和零字节文件都会正确失败。
- `updateActiveItemProgress` 在更新字节数、速度或状态前拒绝所有终态条目；异步延迟到达的 progress callback 不会把 `.completed`、`.failed` 或 `.skipped` 改回 `.transferring`。
- `TransferItem.markTransferring` 也拒绝终态，作为状态机的额外保护。
- 新增 `TransferItemTests.testMarkTransferringDoesNotReplaceTerminalStatus` 回归测试。测试 bundle 已包含该测试，但环境的既有 libmtp 绝对 install-name 问题使 XCTest 无法启动，见验证结果。

### 2. Critical: MTP 上传覆盖的可回滚发布流程

- C bridge 检测到同名文件时，先上传为唯一 `upload` 临时名。
- 上传成功后，将旧对象重命名为唯一 `backup` 名，再将临时对象改名为目标名，最后才删除 backup。
- 新对象在获得目标名之前不会删除旧对象。新对象改名失败时，bridge 尽力将 backup 恢复为目标名，再清理临时对象。

### 3. Important: 覆盖失败后的 MTP 清理与错误

- 上传本身失败、临时对象查找失败、生成 backup 名失败、旧对象改名失败和新对象改名失败的路径都会尽力查找并删除临时对象。
- 回滚重命名或临时对象清理失败时，会保留原始失败原因，并追加可读的 rollback/cleanup 错误信息。
- 新对象发布成功后若删除 backup 失败，调用返回明确错误；旧内容仍作为 backup 保留，不会为清理而丢失数据。

## 第二轮验证

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。仍有第三方 dylib 最低 macOS 版本为 26.0 的既有链接器警告。
- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test --filter TransferItemTests`：测试源码和 bundle 均编译完成，但 XCTest 启动时仍找不到既有绝对 install name 指向的 `.../libmtp-1.1.23/local-install/lib/libmtp.9.dylib`，因此无法执行断言；未伪造通过结果。
- 未连接 MTP 设备，未执行真实设备覆盖/回滚测试。

---

## 第三轮最终审查修复

### 1. Important: LibMTP 批量传输状态

- `FileTransferService` 现在按选中的 MTP 后端确定 chunk 大小：Kalam 保持每块 50 个文件，LibMTP 固定每块 1 个文件。
- 因此 LibMTP 内部逐文件完成后发生的后续失败，只会影响当前单个条目；上层不会将先前已经提交的文件重新标记为失败。
- 新增 `FileTransferServiceTests.testUploadChunkSizeUsesSingleFileForLibMTP` 覆盖该后端策略。

### 2. Important: 覆盖发布后的 backup 清理

- C bridge 已将新对象改名为目标名后，若删除旧 backup 失败，会输出 warning 供诊断、清空 bridge 错误并返回成功。
- 发布失败发生在新对象取得目标名之前，仍然返回失败并执行既有回滚/临时对象清理；只有提交后的 cleanup failure 被降级。

### 3. Minor: 延迟 progress callback

- 每个 bridge progress 闭包捕获发起该操作的 `TransferBatch` 的 `ObjectIdentifier`。
- `updateActiveItemProgress` 仅在当前 `activeBatch` 的身份匹配时更新，并在写入 `currentItemIndex` 前拒绝终态条目，防止旧批次或终态条目被延迟回调覆盖。

## 第三轮验证

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。链接器仍报告第三方运行库最低 macOS 版本为 26.0。
- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test --filter FileTransferServiceTests`：测试与 bundle 编译完成，但 XCTest 启动时仍找不到既有绝对 install name 指向的 `.../libmtp-1.1.23/local-install/lib/libmtp.9.dylib`，因此无法执行断言；未伪造通过结果。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test`：所有测试源码和 bundle 编译完成，但测试 bundle 因同一既有绝对 install name 问题无法加载，未执行测试断言。

---

## 第三轮最终审查修复

### 1. Important: LibMTP 批量传输状态

- `FileTransferService` 现在按选中的 MTP 后端确定 chunk 大小：Kalam 保持每块 50 个文件，LibMTP 固定每块 1 个文件。
- 因此 LibMTP 内部逐文件完成后发生的后续失败，只会影响当前单个条目；上层不会将先前已经提交的文件重新标记为失败。
- 新增 `FileTransferServiceTests.testUploadChunkSizeUsesSingleFileForLibMTP` 覆盖该后端策略。

### 2. Important: 覆盖发布后的 backup 清理

- C bridge 已将新对象改名为目标名后，若删除旧 backup 失败，会输出 warning 供诊断、清空 bridge 错误并返回成功。
- 发布失败发生在新对象取得目标名之前，仍然返回失败并执行既有回滚/临时对象清理；只有提交后的 cleanup failure 被降级。

### 3. Minor: 延迟 progress callback

- 每个 bridge progress 闭包捕获发起该操作的 `TransferBatch` 的 `ObjectIdentifier`。
- `updateActiveItemProgress` 仅在当前 `activeBatch` 的身份匹配时更新，并在写入 `currentItemIndex` 前拒绝终态条目，防止旧批次或终态条目被延迟回调覆盖。

## 第三轮验证

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。链接器仍报告第三方运行库最低 macOS 版本为 26.0。
- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test --filter FileTransferServiceTests`：测试与 bundle 编译完成，但 XCTest 启动时仍找不到既有绝对 install name 指向的 `.../libmtp-1.1.23/local-install/lib/libmtp.9.dylib`，因此无法执行断言；未伪造通过结果。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test`：所有测试源码和 bundle 编译完成，但测试 bundle 因同一既有绝对 install name 问题无法加载，未执行测试断言。

---

## 本轮最终审查收口修复

### 修复内容

- `FileTransferService` 保持按后端选择传输 chunk：Kalam 为 50，LibMTP 为 1，避免 LibMTP 单个 chunk 内局部成功后被上层整块标失败。
- `FileTransferService.updateActiveItemProgress` 保持批次身份校验，并在写入 `currentItemIndex` 前拒绝终态条目，防止延迟 progress callback 把已完成/失败/跳过条目切回 transferring。
- `mtp_bridge_upload_file` 在新对象已经 rename 到目标名后，如果删除旧 backup 失败，会将 cleanup 错误输出为 `MacMTP libmtp warning`，清空 `last_error` 并返回成功；publish 前失败仍按原逻辑返回失败并回滚/清理。
- `FileTransferServiceTests.testUploadChunkSizeUsesSingleFileForLibMTP` 覆盖 LibMTP/Kalam chunk 策略。

### 验证结果

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。
- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `swift test`：不带 `MACMTP_LIBMTP_ROOT` 时编译 C target 失败，原因是当前 shell 环境找不到 `libmtp.h`。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test`：测试 bundle 编译完成，但加载失败；`libmtp.9.dylib` install-name 指向的 `/path/to/libmtp-1.1.23/local-install/lib/libmtp.9.dylib` 不存在，未执行断言。

### 已知环境限制

- 当前环境未连接 MTP 设备，未执行真实设备覆盖上传测试。
- 当前 libmtp 依赖的绝对 install-name 路径不可用，导致 `swift test` 无法启动测试 bundle；未为环境问题修改工程结构。
