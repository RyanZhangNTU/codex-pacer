修复了 Mac 上 Codex 可运行 Dot 任务时，Pacer 磁盘读取多、耗电高的问题。4.4.0 每两分钟会完整校验一次整个 Codex，每次读取约 1.6 GB；现在只确认 Pacer 要启动的那一部分。Mac 和 Windows 上，Pacer 也改为一直使用同一条 Dot 任务连接，不再每两分钟重连。Dot 任务的显示速度不变。建议 Mac 用户尽快更新。

更多信息见[使用说明](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
