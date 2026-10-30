# LibMTP Backend Verification

> 历史归档：原路径 `docs/libmtp-backend-verification.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

Date: 2026-07-14
Device: iFlytek AiNote Air2
Host: macOS arm64
Backend: LibMTP

切换偏好设置中的 MTP Engine 后需要重启应用，新的后端选择才会生效。

## Commands

```bash
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift test
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" swift build
MACMTP_LIBMTP_ROOT="$PWD/../libmtp-1.1.23" ./scripts/build.sh release --arch arm64
open macMTP.app
mtp-detect
codesign --verify --deep --strict macMTP.app
otool -L macMTP.app/Contents/MacOS/macMTP
```

从 `.worktrees/libmtp-bridge` worktree 执行时，将 LibMTP 路径覆盖为：

```bash
MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23"
```

## Checklist

- [ ] Detects connected device.
- [ ] Displays manufacturer and model.
- [ ] Lists internal storage.
- [ ] Lists root directory.
- [ ] Navigates into a folder.
- [ ] Creates a folder.
- [ ] Renames the folder.
- [ ] Deletes the folder.
- [ ] Downloads a small file.
- [ ] Uploads a small file.
- [ ] Detects upload conflict.
- [ ] Downloads a folder recursively.
- [ ] Uploads a folder recursively.
- [ ] Transfers a file larger than 4 GB.
- [ ] Fix MTP Connection still works when macOS camera services hold the interface.

## Results

- `swift test`：失败。编译完成，但测试 bundle 启动时找不到运行时 `/path/to/libmtp-1.1.23/local-install/lib/libmtp.9.dylib`，以 signal 5 退出。
- `swift build`：通过。
- `./scripts/build.sh release --arch arm64`：当前按预期失败。release bundle 校验发现 bundled `libusb.dylib` 的最低 macOS 版本为 26.0，高于支持目标 14.0；必须以 `MACOSX_DEPLOYMENT_TARGET=14.0` 重建所有运行时依赖后才能生成发布包。
- `codesign --verify --deep --strict macMTP.app`：通过。
- `otool -L macMTP.app/Contents/MacOS/macMTP`：通过；主程序对 LibMTP、libusb、libgcrypt、libgpg-error 的引用均为 `@executable_path`，未发现绝对路径。
- 当前环境未连接 MTP 设备，且 `mtp-detect` 不可用：命令未安装（exit 127）。因此所有设备 checklist 项目保持 unchecked，未宣称设备验收通过。
- universal LibMTP 验证未完成；当前 arm64-only runtime dylib 不满足 universal，需要 fat runtime dylibs。
