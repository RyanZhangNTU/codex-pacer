Codex Pacer 3.2.4 修复了重启后已结束的 Claude 任务一直显示为运行中的问题。

- Codex Pacer 重启后（例如刚更新完），已经结束的 Claude 任务不再一直显示为运行中。Pacer 现在会先读完自己的钩子记录，再匹配对话的结束信号，和 SSH 主机的处理方式一致。
- 重启前不久真正被中断的任务也不会一直挂着运行中：最后一次活动满 15 分钟后会显示为状态未确认，之后一有新活动就会恢复为运行中。

### 安装

- **已有安装：** 通过“检查更新”原地升级，保留现有设置。
- **手动安装：** 先退出 Codex Pacer，再用新版替换“应用程序”中的副本，然后重新打开。
- 需要 macOS 14 及以上。

详见[使用指南](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
