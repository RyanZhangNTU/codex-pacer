Codex Pacer 4.2.2 推出 Windows 版，登录 Claude 和 DeepSeek 不再需要点“继续”，并修复了 `/code-review` 这类技能结束后，Claude Code 任务仍显示为运行中的问题。

- **Windows 版 Codex Pacer。** 与 Mac 相同的灵动岛、任务列表、额度圆环、提醒和设置，支持 Codex、Claude Code 与 DeepSeek Harness，也支持 SSH 主机、WSL 和 Codex Remote Control。需要 Windows 10 2004（内部版本 19041）或更新版本，支持 x64 和 ARM64；Windows 11 22H2 及以上使用玻璃表面。
- 登录 Claude 和 DeepSeek 后会自动完成。登录窗口顶部有一条服务颜色的提示条，说明登录后会显示什么，并提供“刷新”和“稍后”；在网页上登录完成后，提示条变绿，窗口自动关闭。用其他方式关闭窗口时，只要已经登录，也会照常完成。
- 在自己的子代理里运行的技能（例如 `/code-review`）结束后，任务不再一直显示为运行中。这类技能汇报子代理的方式和 Agent 工具不同，Pacer 之前看不到它结束；现在技能返回时就算结束，在后台运行的技能则等 Claude 报告完成后结束。

### 安装

- **Mac 已有安装：** 通过“检查更新”原地升级，保留现有设置。
- **Mac 手动安装：** 先退出 Codex Pacer，再用新版替换“应用程序”中的副本，然后重新打开。需要 macOS 14 及以上。
- **Windows：** 运行下方与你电脑对应的安装程序。按当前用户安装，无需管理员权限；之后的版本可在“设置 → 通用”中更新。

详见[使用指南](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
