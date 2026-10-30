# AGENTS.md

## 仓库协作约定

- 默认使用中文沟通、编写文档和注释，除非用户指定其他语言。
- Git 提交信息必须使用一行英文，并符合 `type: message` 格式。
- `type` 使用常见类型，例如 `feat`、`fix`、`docs`、`refactor`、`test`、`ci` 或 `chore`。
- `message` 使用简洁明确的英文动词短语，不换行，不添加额外正文。
- 面向公开仓库的文档变更应提供英文版本；中文基线文档使用对应的 `.en.md` 文件，并在双语索引中互相链接。
- 修改文档入口时同步检查中英文 README 的链接、标题和相对路径。

示例：

```text
fix: prevent drag callbacks from crossing actor boundaries
```
