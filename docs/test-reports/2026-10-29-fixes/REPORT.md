# macMTP 8 项缺陷修复与回归报告

> 公开副本已对个人路径及账号标识脱敏；日志、命令输出和归档为脱敏版本，测试结论未重新执行或改写。说明见[文档脱敏记录](../../maintenance/DOCUMENT_PRIVACY.md)。

日期：2026-10-29。基线为[全功能测试报告](../2026-10-29/REPORT.md)中的 BUG-01～08，保留此前多文件拖放修复。所有修复在当前工作区，未提交 Git。

**8 项代码问题已修复并完成针对性回归。** `swift test` 发现 38 项：37 项执行通过，1 项真机测试按默认规则跳过，0 失败；随后单独启用真机测试，11 个检查点全部通过。原生界面验证了路径编辑、筛选文本快捷键和缺失源错误弹窗。新版 arm64 app 与新 DMG 的主程序/运行库最低系统均为 14.0，签名及依赖路径检查通过。

## 修复对照

| 编号 | 改动与最终行为 | 回归证据 |
| --- | --- | --- |
| BUG-01 | `completedCutSources` 只返回所含队列项全部 completed 的选择。跳过/失败项不清理；部分跳过的目录保留整棵源树，独立成功文件可清理 | 双向真机跳过+成功混合批次；跳过源保留，成功源移除；旧目标哈希不变；无设备测试覆盖部分跳过目录 |
| BUG-02 | `TransferItem.isDirectory` 使空目录成为队列项，显式建目录并记录成功/失败；检查目标类型，普通文件不能冒充目录；零字节队列有完成进度 | 真机嵌套空目录双向往返，下载进度 1.0；目录创建失败测试保留源 |
| BUG-03 | 空子目录成功迁移后才允许清理整棵剪切源；任一目录/文件失败或跳过，原目录保留 | 真机含文件+空子目录的树双向剪切成功，目标保留空子目录；目录目标冲突时源保留的无设备测试 |
| BUG-04 | `requestInProgress` 在启动 Task 前占用，覆盖扫描、冲突等待、传输与取消后的底层返回；B 报忙而不更改 A；剪切路径作为本次调用参数，移除全局剪切字段 | 真机真实在途 32 MiB 剪切 A 遇到 B，A 完成、目标 SHA-256 相同、A 源正确清理、B 未写入；无设备测试覆盖准备期和取消未返回期 |
| BUG-05 | 本地/设备缺失源明确抛错；`transferError` 连接应用内弹窗，队列失败展示文件名和详情，通知拒绝也不影响反馈 | 双向缺失源无设备测试；真机服务错误属性；原生 UI 显示缺失 source.txt 的 Transfer Failed 弹窗 |
| BUG-06 | 内部拖动负载改用 Codable JSON，完整保留换行、冒号和 Unicode；合法旧格式兼容，畸形旧格式整体拒绝，不截取一部分。上传后核对目标名称/大小，防设备静默改名或截断后误清理源 | JSON 与 provider 单测通过；模拟改名/截断均失败且保留剪切源；本台真机拒绝特殊名称时显示 PTP 失败详情并保留源 |
| BUG-07 | 新增 `build-runtime.sh`，从固定版本、SHA-256 校验的源码构建 macOS 14 运行库；默认原生打包使用独立 prefix；打包前检查架构/minOS，旧 package.sh 复用相同完整打包路径 | app、只读挂载的新 DMG 均通过检查；故意指定旧 macOS 26 库时提前拒绝，已有 app 哈希不变 |
| BUG-08 | 全局快捷键和字母导航对文本 firstResponder 让行；恢复系统编辑菜单 A/C/X/V 快捷键；点击文件/空白或开始拖动时退出文本编辑 | 原生 UI Command-A 替换完整路径、普通 Return 提交；筛选框 A/C/X/V 只编辑文本，点击文件后焦点回主窗口；路由单测通过 |

主要代码：`FileTransferService.swift`、`MTPUploadVerification.swift`、`TransferItem.swift`、`FileExplorerPane.swift`、`ExplorerKeyboardRouting.swift`、`ContentView.swift`、`App/main.swift`、`Package.swift` 和构建脚本。队列计数显示改为“项”，包含目录；成功通知区分已复制与跳过。

## 验证记录

| 检查 | 结果 | 原始记录 |
| --- | --- | --- |
| 修改前构建与测试 | 构建退出 0；22 tests、0 failures，退出 0 | [构建](evidence/baseline-build.log)、[测试](evidence/baseline-tests.log) |
| 最终无设备测试 | 38 tests、1 skipped、0 failures，退出 0，即 37 项实际通过 | [swift test](evidence/final-unit-tests.log) |
| 真机回归 | 1 个 XCTest 内 11 个检查点全 PASS，退出 0 | [结果](evidence/device-results.json)、[日志](evidence/device-tests.log) |
| 原生 UI | 3 条记录 PASS | [结果](evidence/ui-results.json) |
| 最终打包 | release 构建、完整 bundle 复制及签名成功，退出 0 | [构建](evidence/final-app-build.log) |
| 运行库构建 | libusb / libgpg-error / libgcrypt / libmtp 均 minos 14.0 | [构建](evidence/runtime-build.log) |
| app 校验 | arm64、minos≤14.0、签名、资源语法、所有非系统依赖随包，退出 0 | [结果](evidence/final-package.json) |
| 新 DMG | 创建、校验、只读挂载、包检查、卸载全部成功 | [包检查](evidence/dmg-package.json)、[校验](evidence/dmg-verify.log)、[挂载](evidence/dmg-mount.log) |
| 错误依赖负向验证 | 旧 minos 26 库被拒绝（构建退出 1，符合预期），已有 app 未改动 | [结果](evidence/incompatible-dependency-rejection.json) |
| 回滚演练 | 在另一份副本恢复 21 个文件；原 22 项单测通过；原换行截断行为探针确认恢复 | [回滚](evidence/rollback.log)、[测试](evidence/rollback-tests.log)、[行为探针](evidence/rollback-behavior.log) |

本轮真机服务测试通过依赖注入替换通知投递和目录刷新，不修改产品源代码，不需要上一轮的通知源码补丁。日常测试无需设备；真机测试必须显式设置 `MACMTP_RUN_DEVICE_TESTS=1`。原生 app 使用正常通知实现，但本轮不覆盖系统通知授权矩阵。

初期无设备替身测试出现 `/var` 与 `/private/var` 路径别名差异，已改为基于目录相对路径生成 MTP 路径。特殊名称真机首次断言错误地期待成功，后依据队列实际 PTP 错误修正为验证“完整解析、明确失败、保留源”；没有把设备拒绝记为成功上传，也没有声称已证明设备改名。

## 构建依赖与复用

固定版本：libusb 1.0.29、libgpg-error 1.58、libgcrypt 1.11.2、libmtp 1.1.23；编译目标 `MACOSX_DEPLOYMENT_TARGET=14.0`。libgpg-error 禁用诊断信息本地化，因而无需 gettext/libintl；应用中英文资源保持正常。没有修改 Homebrew 安装。

```bash
./scripts/build-runtime.sh arm64
./scripts/build.sh release --arch arm64
swift test
# 关闭 app，连接空闲设备后显式运行；创建并清理独立 UUID 测试根
MACMTP_RUN_DEVICE_TESTS=1 swift test --filter FileTransferDeviceRegressionTests
```

`MACMTP_RUNTIME_PREFIX` 可指定兼容依赖安装目录。显式指定旧 LibMTP 根目录仍受支持，但不兼容依赖会在替换已有 app 前被拒绝。

本轮没有 macOS 14、Intel 或 universal 实机，验证到 arm64/macOS 26.6.2 下运行及最低版本元数据一致。原全功能报告中未执行/阻塞的物理拔插、容量、全套真实拖放等仍需补测；本报告不把那 96 条用例改写成全部通过。

## 产物与回滚

- [修复后的源文件归档](MODIFIED_FILE.tar.gz)
- [相对本轮修改前的完整补丁](DIFF_FILE.patch)，包含此前未提交的拖放修复之外的本轮增量
- [命令、输入、逐字输出、退出状态与哈希](VERIFICATION.txt)
- [可执行回滚脚本](ROLLBACK.sh)，搭配 [本轮修改前文件](BASELINE.tar.gz) 与 [哈希清单](evidence/change-manifest.json)
- [修复版 arm64 DMG](../../../release/macMTP-1.0.6-fixes-arm64.dmg)

应用：`/path/to/MacMTP/macMTP.app`。仍为版本 1.0.6 build 5，以 [final-environment.json](evidence/final-environment.json) 内 SHA-256 区分修复版；没有覆盖原 DMG、安装目录或发布到外部。

回滚需显式传入目标 checkout/copy；脚本先校验当前哈希，任何文件在本轮后又有变化则在写入前中止。演练在 `/tmp/macmtp-eight-bugs-20261029/rollback-project` 完成，工作区保持修复状态。脚本恢复源码、测试、构建脚本、资源和 README；app/运行库二进制及历史报告保留，若真正回退运行版本，应另行使用匹配的构建产物。

真机每轮只操作新 UUID 测试根，最终根路径集合恢复为原 10 项。本地 UI 合成文件已恢复，测试数据保留用于复核，没有改动业务文件或清空废纸篓。应用已重启，内部测试剪贴板随进程清空，无活动批次。

> 开源发布说明：历史源码归档、补丁、回滚脚本、验证原始记录与 `.log` 文件为本地复核材料，由 Git 忽略，不包含在源码发布快照中。文中指向这些材料的链接仅在保留本地证据的工作区可用；公开测试结论与结构化结果保留。发布检查和导出方式见[开源发布准备](../../development/OPEN_SOURCE_RELEASE.md)。
