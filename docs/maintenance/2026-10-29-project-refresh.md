# 截图、README 与组件清理记录

日期：2026-10-29。[返回文档索引](../README.md)

## 变更

- 重写[英文 README](../../README.md)和[中文 README](../../README.zh-CN.md)，统一功能、限制、构建、测试和隐私说明。纠正旧 Go/OpenMTP 构建前提、过期路径和未验证架构的表述。
- 更新[截图清单](../../assets/screenshots/README.md)：主窗口、偏好设置、关于及新建目录；使用演示文件，无设备状态为真实状态。不再引用旧设备连接截图，图标单独放在 assets/icon.png。
- 删除 `Sources/CKalam/libkalam.a`（16,391,440 字节）及空目录。该文件已不在 Package.swift 的依赖图中，原来被 gitignore 忽略；从当前工作区清理。
- 删除 `Sources/SentryStub`、Sentry target/import/启动配置与空事件上报。保留本地 ErrorLogger.debug/log；删除无调用的 logMessage。
- 删除无效的首次隐私授权弹窗、崩溃报告设置及对应翻译；不再让界面暗示存在实际上未实现的遥测上传。
- 删除无调用、方法体为空的 `UpdaterService.swift`。
- 清理 CI 中的 OpenMTP checkout、Go 配置、旧 Homebrew 双架构依赖步骤；使用隔离的 LibMTP runtime。CI 仅构建 runner 本机架构，标签发布同样如此。测试失败正常使 CI 失败，不再吞掉返回码。
- 同步贡献指南中的构建环境和启动位置。

LibMTP bridge、libusb 及实际仍被使用的 `Go*` 响应模型保留。后者是当前 ABI/JSON 数据模型的兼容命名，不是未使用的 Go 组件。没有改动传输协议、剪切清理规则和八项缺陷修复。

## 验证

- 清理前：`swift test`，38 项发现、37 项通过、1 项默认跳过、0 失败。
- 清理后：`swift test`，38 项发现、37 项通过、1 项默认跳过、0 失败。
- `bash scripts/build.sh release --arch arm64` 构建与临时签名校验通过；应用启动后核对主窗口、偏好设置、关于及新建目录弹窗。
- 实拍偏好设置不再出现遥测开关；没有再次出现遥测授权弹窗。截图无合成设备数据。
- 本轮不重复真机传输测试，不将此前 11 项真机检查当作本轮新结果；x86_64、Universal 和 macOS 14 实机仍未验证。GitHub Actions 工作流仅做本地配置检查，未触发远程发布。

当前根目录 macMTP.app 是清理后的构建；release/ 中旧 DMG 未重打包，仍为此前产物。

## 可复核证据

本轮基线、修改归档、差异、逐文件 SHA-256、测试/构建日志和副本回滚脚本保留于本地 `.build/project-refresh-20261029/`。`.build/` 为忽略的构建目录，不将旧静态库重新打进版本库。回滚仅用于显式指定的副本，演练后当前工作区仍保留清理状态。

历史架构文档、阶段报告、日志和归档里的 Sentry/CKalam/Go 描述保留原始基线语义，不批量改写历史证据；当前结构以 README、Package.swift 及本记录为准。
