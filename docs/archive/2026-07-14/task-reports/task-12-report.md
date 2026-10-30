# Task 12 报告：LibMTP 后端验证和文档更新

> 历史归档：原路径 `.superpowers/sdd/task-12-report.md`。文内命令与非链接路径保留当时记录，不代表当前项目布局或实现。

## 实现内容

- 新增 `docs/libmtp-backend-verification.md`，记录日期、目标设备、主机架构、后端、实际命令、设备回归清单和当前结果。
- 更新 `README.md`，加入实验性 LibMTP 后端的构建方式、默认 Kalam 后端说明和 universal fat runtime dylib 限制。
- 更新 `README.zh-CN.md`，加入对应中文说明。

## 验证

执行目录：`/path/to/MacMTP/.worktrees/libmtp-bridge`

- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift test`：失败。编译完成，但测试 bundle 启动时找不到运行时 `/path/to/libmtp-1.1.23/local-install/lib/libmtp.9.dylib`，因此以 signal 5 退出。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" swift build`：通过。
- `MACMTP_LIBMTP_ROOT="$PWD/../../../libmtp-1.1.23" MACMTP_KALAM_DIR="$PWD/../../../openmtp/ffi/kalam/native" ./scripts/build.sh release --arch arm64`：通过，生成 arm64 `macMTP.app`。
- `codesign --verify --deep --strict macMTP.app`：通过。
- `otool -L macMTP.app/Contents/MacOS/macMTP`：主程序对 LibMTP、libusb、libgcrypt、libgpg-error 的引用均为 `@executable_path`，未发现绝对路径。
- `mtp-detect`：无法执行，命令未安装（exit 127）；当前环境未连接 MTP 设备，设备清单全部保持 unchecked。
- universal LibMTP 设备验证未宣称通过；当前 arm64-only runtime dylib 不满足 universal，需要 fat runtime dylibs。
- `git diff --check`：通过。

## 改动文件

- `README.md`
- `README.zh-CN.md`
- `docs/libmtp-backend-verification.md`
- `.superpowers/sdd/task-12-report.md`

## 自检

- 仅修改本任务要求的文档文件，未回退或覆盖其他 worktree 改动。
- README 的实验性后端说明与验证文档路径一致。
- 设备相关项目未因缺少真实设备而伪造结果；实际通过项和环境限制均已记录。
- 脚本实际参数为 `release --arch arm64`，报告使用可执行命令；简报中的 `--release` 形式未直接使用。

## 问题

- 测试运行时缺少可加载的 LibMTP dylib，需修复测试环境的 runtime search path 或提供对应 dylib 后重跑 `swift test`。
- 当前没有 iFlytek AiNote Air2，且环境未安装 `mtp-detect`，无法完成真实设备浏览、文件操作、冲突和大文件传输验收。
- universal LibMTP 仍需 fat runtime dylibs 后才能进行有效验证。

## Reviewer 修复说明

- 将验证文档的标准命令恢复为主仓库默认的相邻依赖路径 `$PWD/../libmtp-1.1.23`，并补充 worktree 执行时使用 `$PWD/../../../libmtp-1.1.23` 及对应 Kalam 路径的覆盖说明。
- 在验证文档 Results 中补齐 `swift test` 失败原因、`swift build`、arm64 release build、codesign 和 `otool` 的实际结果，以及设备和 `mtp-detect` 不可用、universal 需要 fat runtime dylibs 的限制。
- 明确所有设备 checklist 项目保持 unchecked，未伪造真实设备验收通过。
