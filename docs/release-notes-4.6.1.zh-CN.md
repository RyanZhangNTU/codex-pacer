**Codex 任务恢复显示**。Codex 新版（26.1117）去掉了 Pacer 读取 Codex 任务用的连接（[#275](https://github.com/RyanZhangNTU/codex-pacer/issues/275)）。Pacer 改为通过 Codex 自己的钩子跟踪任务，本地 Codex 任务、进度和待你审批的提醒都会恢复显示。更新后 Pacer 会列出两步：Codex 较旧时先更新，再在 Codex 里允许 Pacer 一次。**打开 Codex** 会打开 Codex 的设置，旁边有一个小引导，每完成一步会自动打勾。新用户在欢迎向导里也会看到这两步。

**Codex 没报上来时会提醒你**。如果 Codex 在运行任务、Pacer 却没有收到，设置里的 Codex 页和折叠栏会提示你检查；Pacer 重新收到 Codex 的消息后，提示会自动消失。

**每个服务的设置页都统一了**。每页开头都是任务监测、账号和用量，下面是显示选项。“远程”页现在只列 SSH 主机，以及 Windows 上的 WSL。

**移除了 Remote Control**，因为 Codex 新版不再支持。

**修复**。在 Codex 桌面版里添加的 SSH 主机，正在运行的任务也会显示。Codex 在任务进行中退出或崩溃后，任务不会再一直显示为运行中。

更多信息见[使用说明](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
