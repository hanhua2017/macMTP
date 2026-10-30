# 第三方依赖

本目录统一存放 4 个依赖的下载缓存、源码、分架构构建结果和运行库。源码及二进制不提交 Git；只跟踪 `.gitignore`、本说明和 [dependencies.tsv](dependencies.tsv)。许可证原文另存于项目根目录 [LICENSES](../LICENSES/README.md)，不受这里的忽略规则影响。

| 组件 | 版本 |
| --- | --- |
| libusb | 1.0.29 |
| libgpg-error | 1.58 |
| libgcrypt | 1.11.2 |
| LibMTP | 1.1.23 |

```text
thirdparty/
├── dependencies.tsv          # 固定版本、URL、SHA-256，提交 Git
├── README.md                 # 提交 Git
├── .gitignore                # 提交 Git
├── downloads/                # 上游压缩包，忽略
├── sources/<name-version>/   # 解压后的公共源码，忽略
├── build/<arch>/             # 各架构独立 configure/make 目录，忽略
├── runtime/<arch>-macos14/   # include/lib/pkgconfig/bin，忽略
└── backups/                  # --force 保存的旧源码，忽略
```

在项目根目录运行：

```bash
./scripts/download.sh                  # 下载、校验、解压全部依赖，不编译
./scripts/download.sh --offline        # 只使用本地缓存，仍核对 SHA-256
./scripts/download.sh --force          # 备份现有源码，再从校验后的归档重新解压
./scripts/build-runtime.sh arm64       # 自动调用 download，再构建运行库
./scripts/build-runtime.sh x86_64
./scripts/build.sh release --arch arm64
```

下载使用临时文件，SHA-256 通过后才成为正式缓存；已有缓存每次都会校验。默认保留已初始化的源码，不覆盖本地修改。遇到非脚本管理的同名源码目录会报错，使用 `--force` 时先移到 backups，再提取新版副本。并行构建不同架构前，应先单独完成一次下载；不要同时运行多个 download 进程。

构建从验证过的归档建立分架构源码副本，不直接编译公共 sources，避免 arm64/x86_64 共用 configure 结果。旧版位于项目外或旧布局中的本地源码已保存在本机忽略的备份目录，不作为发布构建输入。

详细步骤见[依赖构建指南](../docs/development/LIBMTP_BUILD.md)。版权及许可见[第三方开源声明](../THIRD_PARTY_NOTICES.md)。变更版本时同步更新清单、构建脚本中的库版本、LICENSES 和开源声明。
