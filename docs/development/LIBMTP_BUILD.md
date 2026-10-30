# 第三方依赖下载、编译与项目集成

[文档索引](../README.md) · [依赖目录说明](../../thirdparty/README.md) · [固定版本清单](../../thirdparty/dependencies.tsv)

## 1. 依赖布局与版本控制

LibMTP 1.1.23、libusb 1.0.29、libgcrypt 1.11.2、libgpg-error 1.58 统一位于 `thirdparty/`。

| 路径 | 用途 | Git |
| --- | --- | --- |
| `thirdparty/dependencies.tsv` | 每个依赖的源码目录名、归档名、官方 URL 和 SHA-256 | 跟踪 |
| `thirdparty/downloads/` | 官方源码归档缓存 | 忽略 |
| `thirdparty/sources/<name-version>/` | 下载脚本初始化的源码，保留给阅读/修改 | 忽略 |
| `thirdparty/build/<arch>/<name-version>/` | 为每种架构独立解压和编译的工作目录 | 忽略 |
| `thirdparty/runtime/<arch>-macos14/` | 头文件、动态库、pkg-config 和辅助工具 | 忽略 |
| `thirdparty/backups/` | 强制解压前保存的旧源码 | 忽略 |
| `LICENSES/` | 依赖许可证及附加声明原文 | 跟踪 |

仓库不再提交第三方源码或本机构建结果。新拉取项目后运行下载脚本即可恢复依赖；构建和打包流程也会按需调用它。历史报告中的旧目录保留历史语义，不代表当前路径。

## 2. 下载与校验

环境：macOS、Xcode（含 Swift 6.0+ 和 SDK）、`curl`、`shasum`、`tar`、`make`，以及 `pkg-config`。

```bash
brew install pkg-config
./scripts/download.sh
```

脚本读取 `dependencies.tsv`，依次下载、核对 SHA-256 并解压到 sources。归档先写入临时文件，校验成功才移动到正式缓存。已有缓存仍会校验；哈希不符即失败，不解压、不继续编译。下载配置包含连接及总时限，失败正常返回非零状态。

```bash
# 网络不可用时，只使用预先准备好的缓存
./scripts/download.sh --offline
# 保存本地源码修改到 backups，再重新从校验后的归档提取
./scripts/download.sh --force
```

`--offline` 缺少缓存会失败。默认保留已初始化的 sources；`.macmtp-source.sha256` 只标识最初解压来源，不意味着之后手工修改的源码仍与上游逐字节相同。没有来源标识的同名目录不会被静默覆盖。

只阅读/修改 sources 不会改变默认构建结果：默认构建输入是经过校验的官方归档。需要使用本地源码修改时，应显式维护对应补丁/构建工作树，并按实际版本同步源码分发材料。

## 3. 编译运行库与应用

```bash
./scripts/build-runtime.sh arm64
./scripts/build.sh release --arch arm64
open macMTP.app

# 单独构建 Intel 运行库和应用
./scripts/build-runtime.sh x86_64
./scripts/build.sh release --arch x86_64
```

运行库按 libusb → libgpg-error → libgcrypt → libmtp 顺序编译。使用 `MACOSX_DEPLOYMENT_TARGET=14.0` 和 `-arch <arch>`，全部为动态库，libgpg-error 禁用 NLS，因而不需要 gettext/libintl。不会修改 Homebrew 中的库。

每个架构从同一份已校验归档建立独立的 in-source configure 工作目录。LibMTP 发布包带有 Linux 环境生成的字节序头文件，应在各自工作源码中 configure 重新生成；不要直接改为独立 build 目录，否则可能错误包含旧头文件，出现 `byteswap.h` 缺失。

`MACMTP_BUILD_JOBS=4` 可调整并行度。并行构建不同架构前先完成一次 download；来源目录不被编译过程写入，各架构使用独立 build/runtime。

## 4. 链接配置

默认使用 `thirdparty/runtime/<arch>-macos14`，`Package.swift` 根据本机架构自动发现对应 prefix。`build.sh --arch` 显式选用目标架构 prefix，避免交叉编译混用本机依赖。

高级覆盖项：

- `MACMTP_RUNTIME_PREFIX`：兼容的自定义运行库安装目录。
- `MACMTP_LIBMTP_ROOT`：源码树模式下的根目录，默认后备为 `thirdparty/sources/libmtp-1.1.23`；该目录本身不含默认编译产物。
- `MACMTP_LIBMTP_LIB_DIR`：独立覆盖 libmtp 动态库路径，显式值优先。
- `MACMTP_LIBUSB_LIB_DIR`：SwiftPM 的 libusb 链接目录。
- `MACMTP_ARM64_LIBUSB_PKGCONFIG` / `MACMTP_X86_64_LIBUSB_PKGCONFIG`：指定架构的 libusb pkg-config 目录。

通常只需使用 build-runtime/build 两个脚本，不应将未经重编的旧源码树动态库当作可发布依赖。打包前会检查库架构和最低系统版本，随后复制到 app 并改写依赖路径、签名。

## 5. 验证

```bash
./scripts/download.sh --offline
bash Tests/scripts/test-download.sh
swift test
codesign --verify --deep --strict macMTP.app
lipo -archs macMTP.app/Contents/MacOS/macMTP
xcrun vtool -show-build macMTP.app/Contents/MacOS/libmtp.9.dylib
# 检查原始依赖文件未被纳入版本控制
git status --short --untracked-files=all thirdparty
```

thirdparty 的 Git 列表应仅包含清单、README 和 .gitignore；若源码曾被手工加入索引，需另行从索引移除，单靠 .gitignore 不会取消已跟踪文件。本次调整前 thirdparty 无已跟踪源码。

arm64 和 x86_64 使用不同的运行库；Rosetta 上测试通过不等于 Intel 实机验证。最低系统元数据为 14.0 不等同于 macOS 14 实机验收。Universal 仍要求所有运行库同时包含两种架构，不自动合并 prefix。

## 6. 开源许可与发布

[LICENSES](../../LICENSES/README.md) 和[第三方声明](../../THIRD_PARTY_NOTICES.md)保留并提交 Git，应用构建会将其打包。源码被 Git 忽略不取消对应 LGPL 的源码提供要求；分发时仍需提供匹配二进制的源码、构建材料及实际修改。
