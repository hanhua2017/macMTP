# 第三方开源声明 / Third-Party Notices

macMTP 自有代码采用 [MIT License](LICENSE)。第三方代码、随包运行库及其附属文件保留各自的版权和许可，不因集成到 macMTP 而改为 MIT。本声明是组件索引，具体授权范围以原始许可证、附加声明及各源码文件头为准。

macMTP's original code is licensed under MIT. Third-party components retain their own licenses and copyright notices. The original texts and file-level notices govern; this index does not relicense them.

## 随包动态库

| 组件 / 版本 | 运行库 | 许可及原始文件 |
| --- | --- | --- |
| LibMTP 1.1.23 | libmtp.9.dylib | LGPL；[COPYING](LICENSES/libmtp-1.1.23/COPYING) 提供 LGPL 2.1 文本，部分源文件标注 LGPL version 2 or later；[AUTHORS](LICENSES/libmtp-1.1.23/AUTHORS) |
| libusb 1.0.29 | libusb.dylib | LGPL-2.1-or-later；[COPYING](LICENSES/libusb-1.0.29/COPYING)、[AUTHORS](LICENSES/libusb-1.0.29/AUTHORS) |
| libgcrypt 1.11.2 | libgcrypt.20.dylib | 库采用 LGPL-2.1-or-later，另有文件级许可与附加署名；[COPYING.LIB](LICENSES/libgcrypt-1.11.2/COPYING.LIB)、[LICENSES](LICENSES/libgcrypt-1.11.2/LICENSES)、[AUTHORS](LICENSES/libgcrypt-1.11.2/AUTHORS) |
| libgpg-error 1.58 | libgpg-error.0.dylib | 库采用 LGPL-2.1-or-later；[COPYING.LIB](LICENSES/libgpg-error-1.58/COPYING.LIB)、[AUTHORS](LICENSES/libgpg-error-1.58/AUTHORS) |

libgcrypt 和 libgpg-error 上游还包含采用 GPL 等许可的构建辅助工具或文档，其 COPYING、README 同时保留以避免丢失说明；这不表示 macMTP 应用自有代码改用 GPL。libgcrypt 的 LICENSES 含 BSD 等贡献者附加声明，二进制分发时也应保留。

本清单对应项目脚本打包的 4 个动态库，不包括仅由操作系统提供的系统框架/库。已移除的 CKalam、SentryStub 不是当前随包依赖。

## 对应源码与构建方式

以下是本项目固定版本的上游发布包；构建脚本会逐一核对 SHA-256。源码自身的文件级许可、版权、例外条款和构建材料应一并保留。

| 组件 | 源码下载 | SHA-256 |
| --- | --- | --- |
| LibMTP 1.1.23 | https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz | `74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed` |
| libusb 1.0.29 | https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2 | `5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85` |
| libgcrypt 1.11.2 | https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.2.tar.bz2 | `6ba59dd192270e8c1d22ddb41a07d95dcdbc1f0fb02d03c4b54b235814330aac` |
| libgpg-error 1.58 | https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.58.tar.bz2 | `f943aea9a830a8bd938e5124b579efaece24a3225ff4c3d27611a80ce1260c27` |

项目内 `scripts/build-runtime.sh` 和 `scripts/build.sh` 记录相应构建配置及动态链接方式。`thirdparty/dependencies.tsv` 固定版本与校验值，`scripts/download.sh` 下载并将源码放在被 Git 忽略的 `thirdparty/sources/`；构建缓存及运行库也位于 thirdparty，构建输入为上表校验后的发布包。源码被忽略不取消实际分发时的对应源码提供义务。

## 再分发说明

- 保留 macMTP 的 MIT 文本、第三方许可证全文、原始版权及附加声明。
- 按相应 LGPL 条款向接收者提供匹配所分发二进制的完整对应源码和构建材料；修改库时同时提供对应修改及说明。上游下载链接不替代分发者对实际修改版本的源码义务，也不是本项目作出的书面源码提供承诺。
- 本项目动态链接这些运行库。接收者对库的修改、替换，以及为调试该等修改所需的逆向工程，依相应 LGPL 条款处理；不得用额外分发条款剥夺这些权利。替换库后可能需要重新对应用作本地签名。
- 下游若变更版本、链接方式、引入额外组件或分发工具，应重新核对对应许可证和源码材料，不能直接沿用旧依赖清单。

构建后的应用将这些文件放入 `macMTP.app/Contents/Resources/Licenses/`。本次文档补充不追溯修改此前已生成的 DMG；重新打包后才会随新安装包分发。
