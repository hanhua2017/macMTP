# Task 11 报告：打包 libmtp 运行时依赖

> 历史归档：原路径 `.superpowers/sdd/task-11-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 在 `scripts/build.sh` 中增加 `MACMTP_LIBMTP_ROOT` 与 `MACMTP_LIBMTP_LIB_DIR` 的默认值，并在 debug/release Swift 构建时传入。
- 增加 `MACMTP_KALAM_DIR` 覆盖，保持主仓库原有相对路径默认值不变，使 worktree 可显式指向 Kalam 源码。
- 通过 `otool -L` 发现主二进制的 libmtp 引用及 libmtp 的 libgcrypt/libgpg-error 引用；当 libmtp install name 指向不存在的安装路径时，回退到 `MACMTP_LIBMTP_LIB_DIR`。
- 将 `libmtp.9.dylib`、`libgcrypt.20.dylib`、`libgpg-error.0.dylib` 复制到 `macMTP.app/Contents/MacOS`，设置 `@executable_path` install ID，改写主二进制和 dylib 间引用，并在脚本内校验结果。
- 对新增的三个 dylib 进行 ad-hoc 签名，然后深度签名 app bundle。

## 验证

- `bash -n scripts/build.sh`：通过。
- `git diff --check`：通过。
- `rm -f Sources/CKalam/libkalam.a && MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" MACMTP_KALAM_DIR="$PWD/../../../openmtp/ffi/kalam/native" ./scripts/build.sh release`：通过，生成 arm64 release bundle。
- `otool -L macMTP.app/Contents/MacOS/macMTP`：libusb、libmtp、libgcrypt、libgpg-error 均为 `@executable_path`。
- `otool -L macMTP.app/Contents/MacOS/libmtp.9.dylib`：libusb、libgcrypt、libgpg-error 均为 `@executable_path`；`libusb-1.0.0.dylib` 正确映射到 bundle 中的 `libusb.dylib`。
- `otool -L macMTP.app/Contents/MacOS/libgcrypt.20.dylib`：libgpg-error 为 `@executable_path/libgpg-error.0.dylib`。
- `codesign --verify --deep --strict --verbose=2 macMTP.app` 及三个新增 dylib 的严格验证：通过。
- `lipo -archs`：主程序、libusb、libmtp、libgcrypt、libgpg-error 均为 arm64。

## 改动文件

- `scripts/build.sh`

`Package.swift` 已有对 `MACMTP_LIBMTP_ROOT` 和 `MACMTP_LIBMTP_LIB_DIR` 的读取逻辑，因此本任务无需改动。

## 自检

- 主仓库默认的 Kalam 和 libmtp 相对路径保持不变。
- worktree 构建使用环境变量覆盖路径，不依赖错误的 worktree 相邻目录。
- libmtp install name 的实际路径由 `otool -L` 发现，不硬编码 `local-install` 路径。
- 没有修改 C bridge、Swift UI 或 README。

## 问题

- 首次 release 构建受被忽略的旧生成物 `Sources/CKalam/libkalam.a` 阻塞，Go 1.26 拒绝覆盖它；删除该非版本控制构建产物后，使用相同命令构建通过。
- 当前 Homebrew 的 `libgpg-error.0.dylib` 仍引用 `/opt/homebrew/opt/gettext/lib/libintl.8.dylib`。该依赖不在任务简报列出的 bundle dylib 范围内；若 release app 必须在未安装 Homebrew gettext 的机器上运行，需要后续任务一并打包并改写 libintl。

---

## Reviewer 修复：libintl 运行时依赖与 universal 预检

### 修复内容

- 将 `libintl.8.dylib` 解析为 `libgpg-error.0.dylib` 的运行时依赖，复制到 `macMTP.app/Contents/MacOS`，并设置 install ID 为 `@executable_path/libintl.8.dylib`。
- 将 bundle 内 `libgpg-error.0.dylib` 的 `libintl.8.dylib` 引用改写为 `@executable_path/libintl.8.dylib`，并在脚本中拒绝残留的 Homebrew `libintl` 引用。
- 对 `libintl.8.dylib` 执行 ad-hoc 签名；app bundle 的验证改为 `codesign --verify --deep --strict --verbose=2`，不再忽略失败。
- universal 构建在开始 Kalam/Swift 构建前检查 `libmtp.9.dylib`、`libgcrypt.20.dylib`、`libgpg-error.0.dylib` 和 `libintl.8.dylib` 同时包含 `arm64` 与 `x86_64`。缺少任一架构时明确退出，并提示提供 fat dylib 或架构专用依赖目录。

### 验证

- `bash -n scripts/build.sh`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" MACMTP_KALAM_DIR="$PWD/../../../openmtp/ffi/kalam/native" ./scripts/build.sh release`：通过，严格签名验证通过。
- `otool -L macMTP.app/Contents/MacOS/libgpg-error.0.dylib`：`libintl.8.dylib` 为 `@executable_path/libintl.8.dylib`，不再引用 `/opt/homebrew` 或 `/usr/local` 的 Homebrew libintl。
- `otool -L` 检查确认主程序、libmtp、libgcrypt、libgpg-error 的 bundle 内运行时引用均为 `@executable_path`。
- 使用当前 arm64-only 依赖执行 `./scripts/build.sh release --universal`：预检按预期失败，输出 fat dylib/架构专用依赖目录的明确提示，且未开始构建。
- `git diff --check`：通过。
