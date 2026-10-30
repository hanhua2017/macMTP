# macMTP 全功能测试报告

> 公开副本已对个人路径及账号标识脱敏；日志、命令输出和归档为脱敏版本，测试结论未重新执行或改写。说明见[文档脱敏记录](../../maintenance/DOCUMENT_PRIVACY.md)。

| 项目 | 记录 |
| --- | --- |
| 测试日期 | 2026-10-29 |
| 测试基线 | 1.0.6（build 5），当前工作区多文件拖放修复；未提交工作区 |
| 对照规范 | [96 条功能测试用例](../../testing/TEST_CASES.md)、[PRD](../../product/PRD.md) |
| 测试方式 | 原代码单元测试、隔离副本服务/桥接真机测试、原生界面操作、现有 DMG 静态检查 |
| 结论 | **未达到发布验收门槛。发现 8 项问题，其中剪切源丢失、空子目录丢失及第二任务取消已有任务需优先处理。** |

本报告覆盖全功能目录的结果登记，不代表 96 条用例全部执行或通过。仅对有完整证据的用例记“通过”；缺少部分参数或入口记“部分验证”，环境或拖动操作链路受阻记“阻塞”，尚未操作记“未执行”。发现一个反例即可判对应验收用例失败，即使其余参数尚未完成。

## 1. 执行汇总

| 96 条验收用例状态 | 数量 |
| --- | ---: |
| 通过 | 8 |
| 失败 | 8 |
| 部分验证 | 37 |
| 阻塞 | 21 |
| 未执行 | 22 |
| 合计 | 96 |

逐条实际结果、缺陷编号及证据位置：[CSV](CASE_RESULTS.csv) / [JSON](CASE_RESULTS.json)。部分验证不计为通过。这里的验收用例数量与下面的自动化断言、服务子场景数量不同，不能相加计算通过率。

| 验证层 | 实际结果 | 证据 |
| --- | --- | --- |
| 原代码构建 | `swift build --build-tests` 成功，退出 0 | [构建日志](evidence/build-tests.log) |
| 原代码 XCTest | **22 项通过，0 失败**，含 8 项拖放测试 | [单测日志](evidence/unit-tests.log) |
| 真机主测试 | 20 个场景：15 PASS、5 FAIL；其中暂停场景为测试时机错误，后续重测通过 | [结果](evidence/live-results.json)、[日志](evidence/live-tests.log) |
| 真机补充测试 | 12 个场景：9 PASS、3 FAIL | [结果](evidence/supplemental-results.json)、[日志](evidence/supplemental-tests.log) |
| 原生应用双向传输 | 3 文件上传后再下载，3 组 SHA-256 相同 | [哈希](evidence/ui-roundtrip-hashes.json)、[界面记录](evidence/ui-observations.md) |
| 包检查 | 签名、资源语法和 DMG 校验通过；发现最低系统版本不一致 | [工作区包](evidence/package-checks.json)、[DMG 包](evidence/dmg-checks.json) |
| 设备清理 | 各轮独立测试根删除，其他根路径集合保留 | 主/补充结果 CLEANUP；[UI 清理](evidence/ui-cleanup.json) |

32 个服务子场景原始结果合计 24 PASS、8 FAIL；排除被后续复测替代的暂停时机错误后，有 7 条有效失败记录，归为 6 类服务/解析问题；另有包检查和 UI 焦点问题，总计 8 项缺陷。部分子场景为受控状态或解析测试，具体证据级别见缺陷说明。

## 2. 环境与版本

| 项目 | 实际值 |
| --- | --- |
| Mac | arm64，macOS 26.6.2（25G83） |
| 工具链 | Apple Swift 6.3.3；Xcode xctest；本机已有 Homebrew/开发依赖 |
| 设备 | iFlytek AiNote Gallery；MediaTek VID 0e8d / PID 201d，MTP + ADB 模式 |
| 存储 | 1 个，storageId=65537 |
| 声明协议能力 | CopyObject / MoveObject / GetPartialObject / SendPartialObject / EditObject 均为 true |
| 源码 HEAD | `e52592431f0170f9a0bb93f32f5d206640b31190`，另有未提交的拖放修复及文档 |
| UI 测试应用 | 仓库根 `macMTP.app`；没有覆盖安装 `/Applications/macMTP.app` |
| 主程序 SHA-256 | `71225766397e1641f554ee24e5f600e15835a6a48879fa2d07d28c949e5d7092` |
| 修复源文件 SHA-256 | `0f95996ce8648ae397df72ae333646e8b7338ec247dd933de25cfef0d009c0c0`（FileExplorerPane.swift） |
| 静态检查发布包 | `release/macMTP-1.0.6-mac-arm64.dmg`，与工作区应用分开检查；不推断 DMG 已包含本轮修复 |

详细环境见 [environment.json](evidence/environment.json)。设备固件、具体 USB 线材、峰值内存未采集，不能据此推导其他设备或平台的性能/兼容性。

### 测试宿主差异

服务真机测试在 `/tmp/macmtp-fulltest-20261029/project` 隔离副本运行，只将 `postTransferNotification` 换为日志，避免命令行 XCTest 无应用 bundle proxy 时触发 UserNotifications 异常。完整差异见 [test-host-only.patch](evidence/test-host-only.patch)。传输、冲突、源清理及 Swift/C 桥接未改动。**这些服务测试不覆盖通知投递。** 原代码单测和原生 app UI 测试均未应用此替换。

首次 CLI 通知异常保存在 [宿主错误日志](evidence/live-initial-host-error.log)，不计为产品 app 崩溃；早期 100 文件测试的 30 秒超时见 [早期日志](evidence/live-short-timeout.log)，提高测试等待至 180 秒后重跑成功，不计为传输缺陷。

## 3. 已验证的主要链路

- 真实设备自动连接，获取单存储与能力，读取根目录；逻辑断开再初始化成功。物理拔插尚未覆盖。
- 应用内复制/粘贴三文件双向传输，显示完成 3/3、100%、6 KB/6 KB；回读哈希一致，含中文及空格名。
- 服务批量三文件上传；多层非空树双向传输，重复文件名和隐藏文件回读哈希一致。
- 零字节文件上传后回读大小 0，哈希一致。观察到终态 batchProgress=0.0，UI 零字节进度仍需复验。
- 100 个 1 KiB 小文件上传、下载各 100 项，所有 SHA-256 匹配，总耗时 **75.593346 秒**。仅一轮，不作为稳定吞吐基准；未采集资源峰值及 UI 响应。
- MTP 创建目录、中文空格文件重命名、递归删除；真实 CopyObject / MoveObject 单文件成功并核对哈希。
- 无冲突的跨端单文件剪切双向成功，目标完整后源消失。
- 覆盖、跳过、大小不同覆盖、同大小跳过四策略双向服务验证通过；同大小不同内容时按大小规则处理，未误称内容去重。
- 冲突等待取消后新任务可执行；人为制造一个下载目标错误，得到 2 成功、1 失败。
- 实际上传发生非零字节进度后暂停，在第一文件完成处保持暂停；恢复后两文件完成。首次在文件尚未开始时暂停导致的等待超时已被此复测替代。
- 上传取消后不调度第二项，两个 32 MiB 剪切源文件均保留；尚未验证下载取消。
- 界面筛选大小写与扩展名、本地视图切换及大小排序、单栏/双栏切换、关于/偏好设置打开关闭有实际操作记录。

### 原多文件拖放问题的验收状态

解析层 8 项测试通过，其中完整文本优先于首项 fileURL、内部格式优先、Finder 文件名数组和读取失败回退均有覆盖。三文件服务上传及 UI 剪贴板传输也通过。

**真实鼠标拖放仍待端到端复验。** 本轮原生自动化从非首项启动拖动时，日志可见完整三项 provider，但多次尝试未得到 MTP 目标 `handleDrop` 回调。当前证据不足以区分自动化拖动问题和产品目标接收问题，因此没有将 TC-TRN-02～05 判为通过，也没有据此宣称原问题仍然存在。见 [拖动日志](evidence/ui-drag.log)。需在列表/两种图标视图、空白区/子目录、Finder 来源和反向下载补完原生拖放验证。

## 4. 缺陷明细

严重级别表示本轮影响评估；其中服务受控复现不等于已经完成 UI 重现。

| 编号 | 严重级别 | 问题与实测结果 | 关联用例 |
| --- | --- | --- | --- |
| BUG-01 | P0 | 跨端剪切选择跳过，仍删除源。上传 `skippedSourcePreserved=false`；下载 `skippedRemoteSourcePreserved=false` | TC-CLP-04 |
| BUG-02 | P1 | 空目录未迁移：`queueItems=0; targetEmptyDirExists=false` | TC-TRN-07 |
| BUG-03 | P0 | 剪切含空子目录的树后，文件成功但空子目录在源、目标均不存在 | TC-CLP-06 |
| BUG-04 | P0 | 已有 transferring 批次时提交第二任务，原批次被改为 cancelled（受控服务状态） | TC-QUE-05 |
| BUG-05 | P1 | 源文件消失被静默忽略：无 activeBatch，失败计数 0，没有缺失源错误 | TC-QUE-07 |
| BUG-06 | P1 | 内部负载遇换行文件名被拆行，路径从包含换行的全名截为 `/tmp/macmtp-newline`（解析层） | TC-DRG-09 |
| BUG-07 | P0（发布） | 主程序最低版本 14.0，但工作区和现有 DMG 的 5 个 dylib 均声明最低版本 26.0 | TC-PKG-02 |
| BUG-08 | P1 | 文本输入聚焦时全局快捷键拦截 Command-A / Return，路径编辑异常；文件操作快捷键有相同焦点检查缺口 | TC-BRW-11（相邻路径编辑场景） |

### BUG-01：跳过后删除剪切源

复现：在隔离本地和设备目录各放一个同名不同内容的文件 → `initiateTransfer(... isCut: true, conflictResolution: .skip)` → 等待批次终态 → 检查源。上传源不存在；下载设备源也不存在。已有目标并未接收到源内容，属于源数据丢失路径。

预期：被跳过的源必须保留，只能清理已经确认完整迁移的条目。根因核对：`FileTransferService.runQueue` 源清理只检查 failedItems 为空，未排除 skipped，随后清理整组 cutSourcePaths。

证据：[HW-CUT-SKIP](evidence/live-results.json)、[EX-DOWNLOAD-CUT-SKIP](evidence/supplemental-results.json)。仅使用本轮合成数据；本地源被应用移入废纸篓，设备源删除不具备同等回收保障。

### BUG-02 / BUG-03：空目录缺失及剪切丢失

复现 A：将独立 empty-dir 交给上传服务，队列无文件、目标不存在。

复现 B：本地目录内创建 file.txt 与 empty-child → 剪切上传目录 → 文件完成 1 项 → 目标无 empty-child，源 empty-child 也已移除。

预期：目录集合也属于完整性核对；目标缺目录时不得删除相应源目录。根因核对：扫描后使用 `expandedItems.filter { !$0.isDirectory }` 构建队列，未独立提交空目录；与批量剪切清理组合造成丢失。

证据：[HW-EMPTY-DIR](evidence/live-results.json)、[EX-CUT-EMPTY-CHILD](evidence/supplemental-results.json)。未将未执行的独立空目录下载/剪切分支算作已测试。

### BUG-04：拒绝第二任务时取消原批次

复现：服务 activeBatch 设为正在传输状态 A → 提交 B → 等待异步错误处理 → A.state 变为 cancelled。

预期：拒绝 B 不改变 A。根因核对：busy guard 抛 operationInProgress 后，`initiateTransfer` 的 catch 执行 `activeBatch?.cancel()`，此时仍指向 A。另在 busy 检查前已覆盖剪切相关服务字段，需修复时一并审查。

证据：[HW-BUSY](evidence/live-results.json)。本场景使用受控已有批次，没有让真实后台传输 A 同时运行；UI 粘贴/拖动入口及对底层在途调用的影响还需复测。

### BUG-05：源不存在缺少失败反馈

复现：将不存在的本地源路径交给传输服务。结果 activeBatch=nil、failed=0。预期应明确反馈并定位缺失源，不让用户误以为操作已被正常处理。

根因核对：本地展开时不存在路径被跳过，展开为空后直接返回。证据：[HW-INVALID-SOURCE](evidence/live-results.json)。源不可读、磁盘满尚未测试，不扩大结论。

### BUG-06：换行路径解析截断

复现：对 `local:file:/tmp/macmtp-newline\nname.txt` 内部负载执行解析（这里 `\n` 表示实际换行）。结果仅解析 `/tmp/macmtp-newline`。

预期：完整保留一个路径，或在入口明确拒绝并反馈。根因核对：内部负载以换行分隔条目，未转义文件名自身换行。证据：[EX-NEWLINE-PAYLOAD](evidence/supplemental-results.json)。尚未对真实文件做设备拖放，问题确认到解析层。

### BUG-07：发布依赖最低系统不匹配

复现：对工作区 app 和只读挂载的现有 DMG 分别执行 `vtool -show-build`。主程序 minos 14.0；libmtp、libusb、libgcrypt、libgpg-error、libintl 五库均 minos 26.0，全部仅 arm64。

预期：全部运行依赖与产品声明的最低系统匹配。签名校验通过不能证明最低版本兼容。证据：[package-checks.json](evidence/package-checks.json)、[dmg-checks.json](evidence/dmg-checks.json)。当前没有 macOS 14 机器，未实测其具体启动报错；Intel/universal 也未验证。

### BUG-08：输入焦点被面板快捷键截获

复现：双击本地路径面包屑进入编辑 → Command-A → 输入新路径 → 字段出现新内容与原路径拼接，普通 Return 未完成路径提交。精确 setValue 后 shift+Return 能提交。

预期：文本框焦点下按键交给编辑器。根因核对：`ContentView.installKeyboardMonitor` 对 Return、Command-A/C/X/V 等无 firstResponder 文本编辑检查。证据：[UI 记录](evidence/ui-observations.md)。实际观察为路径编辑，未逐个验证筛选/重命名输入，也未执行可能误删文件的快捷键；不宣称发生了键盘误删。

## 5. 关键缺口与补测条件

| 类别 | 本轮缺口 |
| --- | --- |
| 连接与恢复 | 物理拔插、切换 USB 模式、连续拔插、相机服务占用/授权拒绝 |
| 存储与能力 | 第二存储、跨存储剪贴板、缺少 CopyObject/MoveObject 的设备 |
| 数据边界 | 大于 4 GiB 实际传输、emoji/冒号/长名称、深度边界、隐藏目录 |
| 失败环境 | 受限源、空间不足、管理操作失败、传输中物理断线 |
| 交互 | 真实拖放完整矩阵；本地剪贴板各入口；重命名/删除弹窗及取消；框选、字母定位、焦点快捷键完整矩阵 |
| 冲突与队列 | 原生冲突弹窗逐项策略；本地到本地冲突；迟到清理竞争；下载取消；活跃任务时退出/关闭/语言重启 |
| 设置与外观 | 隐藏设置持久化、交换位置、字号边界、语言重启、深浅色、最小窗口、侧边栏失效卷 |
| 通知与隐私 | 系统通知允许/拒绝、首次隐私选择及日志开关边界 |
| 发布与稳定性 | macOS 14、Intel/universal、无开发依赖干净机、安装升级、20 轮批传/10 轮拔插；多轮资源与性能采样 |

具体“部分验证/阻塞/未执行”逐项区分见 CSV；没有将未操作的可测场景写为环境阻塞。以上条件应在修复后续测，全部适用 P0 完成前不作全功能验收通过结论。

## 6. 执行入口与原始产物

以下为本轮使用的关键命令。路径属于本次环境，重跑前需准备独立测试副本、合成数据并释放 app 对 MTP 的占用。服务测试会创建、剪切和清理专用测试根，不应替换为实际使用目录。

```bash
# 原工作区，原代码：构建退出 0，单测退出 0，22 tests / 0 failures
swift build --build-tests
DYLD_LIBRARY_PATH="$PWD/../libmtp-1.1.23/src/.libs:/opt/homebrew/lib" \
  /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest \
  .build/arm64-apple-macosx/debug/macmtpPackageTests.xctest

# 隔离副本含下面保存的测试脚本及 test-host-only.patch；构建退出 0
MACMTP_LIBMTP_ROOT=/path/to/libmtp-1.1.23 \
  swift build --package-path /tmp/macmtp-fulltest-20261029/project --build-tests

# 两个 XCTest 类分别退出 1，因为产品预期断言失败；不是命令启动失败
DYLD_LIBRARY_PATH="$PWD/../libmtp-1.1.23/src/.libs:/opt/homebrew/lib" \
  /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest \
  -XCTest macmtpTests.LiveFunctionalTests \
  /tmp/macmtp-fulltest-20261029/project/.build/arm64-apple-macosx/debug/macmtpPackageTests.xctest
# 同一命令类名换为 macmtpTests.SupplementalFunctionalTests
# 清理类名换为 macmtpTests.CleanupUIFixtureTests，实际退出 0
```

测试脚本：[主测试](scripts/LiveFunctionalTests.swift)、[补充测试](scripts/SupplementalFunctionalTests.swift)、[UI 测试根清理](scripts/CleanupUIFixtureTests.swift)。脚本保存在报告目录，不写入项目日常单测集；其中绝对路径和固定夹具名须在复用时检查。原始日志以 JSON 结果及 XCTest 汇总交叉判断，不把退出码 1 简化成所有场景失败。

## 7. 清理与交付状态

主轮、补充轮及早期中断轮创建的设备测试根已清理；UI 测试根删除前再次下载三个文件核对 SHA-256，删除后其他根路径集合不变，根目录恢复为 10 项。此核对覆盖根路径集合与测试文件内容，不冒称对全部用户文件逐字节审计。

本地合成样本和回读数据保留在 `/tmp/macmtp-fulltest-20261029/data` 与 `/path/to/home/Downloads/macmtp-ui-test-20261029`，用于复核缺陷；源数据丢失复现仅涉及这些合成夹具。没有清空废纸篓。

应用已重新启动、连接设备并恢复双栏，无活动任务；未改语言、自动连接、隐藏项、字号、隐私及系统通知授权设置。发布 DMG 已卸载；原 `/Applications/macMTP.app` 保留。产品源码未为本轮缺陷做修复，已有拖放修复保留。

建议优先修复 BUG-01/03/04，再处理空目录与失败反馈、输入焦点和包依赖版本；修复后重跑相应服务场景及真实 GUI 入口，并补完发布矩阵与原多文件拖放端到端验收。
