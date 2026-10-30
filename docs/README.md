# macMTP 项目文档

## 阅读入口

| 分类 | 文档 | 用途 |
| --- | --- | --- |
| 产品需求 | [PRD](product/PRD.md) | 产品定位、功能规则、数据完整性与验收边界 |
| 技术架构 | [技术架构文档](architecture/TECHNICAL_ARCHITECTURE.md) | 模块、状态与并发、Swift/C 边界及构建发布 |
| 开源许可 | [MIT 与第三方声明](../THIRD_PARTY_NOTICES.md) | 主项目协议、依赖许可证原文、源码来源与再分发说明 |
| 开发构建 | [LibMTP 下载与编译](development/LIBMTP_BUILD.md) | 源码来源、SHA-256 校验、运行库编译、thirdparty 与链接配置 |
| 测试规范 | [测试用例](testing/TEST_CASES.md) | 96 条功能用例、环境准备、覆盖矩阵与发布门槛 |
| 测试结果 | [报告索引](test-reports/README.md) | 实际执行结果、缺陷修复、原始证据和回滚记录 |
| 开源发布 | [发布准备与检查](development/OPEN_SOURCE_RELEASE.md) | 忽略规则、隐私检查、历史身份边界及无历史源码导出 |
| 文档隐私 | [脱敏记录](maintenance/DOCUMENT_PRIVACY.md) | 个人路径、账号标识、历史证据与截图的公开处理约定 |
| 项目维护 | [截图、README 与组件清理](maintenance/2026-10-29-project-refresh.md) | 本轮组件移除、构建与测试验证及截图来源 |
| 历史资料 | [归档索引](archive/README.md) | LibMTP 接入计划、阶段记录和历史验证 |

## 目录约定

```text
docs/
├── README.md                 # 文档总入口
├── product/                  # 产品需求
├── architecture/             # 技术架构
├── development/              # 下载、编译及集成指南
├── testing/                  # 测试规范与用例
├── test-reports/              # 按日期保留报告、脚本和证据
├── maintenance/              # 项目维护与清理记录
└── archive/                  # 历史方案与阶段记录
```

根目录保留双语 README、LICENSE、贡献指南、安全政策、行为准则、治理及维护者信息，方便代码托管平台和新贡献者发现。工作树 `.worktrees/` 与构建产物中的副本不属于本次整理对象。

PRD、技术架构和测试用例保留首次整理的基线描述；当前修复行为以 [8 项缺陷修复与回归报告](test-reports/2026-10-29-fixes/REPORT.md) 和代码为准。文档覆盖不等于测试执行通过。

新增文档按职责进入对应目录，并在本索引或分类索引增加入口。测试报告与其 evidence、scripts、归档和回滚文件作为整体保留；历史日志、补丁及归档内部路径不因目录整理而改写。
