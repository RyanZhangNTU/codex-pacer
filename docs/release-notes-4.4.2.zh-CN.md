Pacer 在后台运行时耗电大幅降低。在相同的真实任务、面板收起的情况下，Windows 上的 CPU 占用比 4.4.1 减少约 60%，Mac 上减少约 65%。屏幕上没有变化时，Pacer 不再重绘界面或发送更新；连不上的主机和失败的连接会降低重试频率；已经识别过的应用也不再反复扫描。

额外耗电的来源改为默认关闭。Codex Dot 任务在“远程”页有了单独的开关“统计 Codex Dot 任务”；升级后，如果这台电脑上已有 Dot 任务上报过进度，开关会保持开启。Codex Remote Control 监测和 Windows 上的 WSL 监测需要在“设置 → 远程”里手动开启；Windows 升级后会关闭一次 WSL 监测。

额度接口回复慢时不再显示错误：Pacer 会保留上一次的读数，10 分钟后才把它调暗。收起栏在 TPS 数字变化时也不再改变宽度。

更多信息见[使用说明](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
