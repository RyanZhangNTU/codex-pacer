Codex Pacer 4.2.1 修复了 `/code-review` 这类技能结束后，Claude Code 任务仍显示为运行中的问题。

- 在自己的子代理里运行的技能（例如 `/code-review`）结束后，任务不再一直显示为运行中。这类技能汇报子代理的方式和 Agent 工具不同，Pacer 之前看不到它结束；现在技能返回时就算结束，在后台运行的技能则等 Claude 报告完成后结束。

### 安装

- **已有安装：** 通过“检查更新”原地升级，保留现有设置。
- **手动安装：** 先退出 Codex Pacer，再用新版替换“应用程序”中的副本，然后重新打开。
- 需要 macOS 14 及以上。

详见[使用指南](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
