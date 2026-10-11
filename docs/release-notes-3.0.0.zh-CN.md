Codex Pacer 3.0 在 Codex 之外，开始支持 **Claude Code**。两个服务的任务、输出速度和额度，如今都在同一个灵动岛里。

### 主要更新

- **支持 Claude Code。** 本机和 SSH 主机上的 Claude 任务与 Codex 任务并列显示，包括当前阶段、等你回复或审批的请求、任务结束、输出速度和首输出时间。Claude 额度显示 5 小时与 7 天两个窗口。
- **自由选择服务。** Codex 与 Claude 是互相独立的模块，检测到已安装时自动开启。
- **自动完成配置。** Pacer 会在本机以及装有 Claude Code 的 SSH 主机上添加自己的 Claude Code hooks，关闭模块时移除本机的配置。SSH 主机直接沿用 Codex 和 Claude 中的设置，包括 Claude 桌面端保存的连接。
- **更清楚的灵动岛。** 一个活动徽标显示运行中的任务数：任务进行时有光弧环绕，有任务等你处理时变为实心琥珀色，有未读的结束任务时显示标记。两个服务的额度圆环带有配速刻度，并标注充裕、正常或偏快。
- **Codex Remote Control。** Remote Control 任务通过 Codex 应用加入任务列表。
- **液态玻璃**在 macOS 26 及以上跟随系统的液态玻璃设置；宽度始终贴合内容。
- **全新设置。** 侧边栏式设置窗口，修改立即生效；可拖动的折叠栏编辑器、连接诊断页、帮助图例，以及两步入门引导。
- **全新应用图标。**

### 需要了解

- Claude 额度来自 Claude Code 的状态栏数据，或 Pacer 专用登录窗口中的 claude.ai 会话。Pacer 不会读取其他应用的钥匙串条目或浏览器 Cookie。
- 菜单栏图标和岛内横幅提醒已移除。所有信息都显示在灵动岛上，macOS 通知可按需开启。
- 2.x 的偏好设置会保留，已停用的选项会自动清除。
- 需要 macOS 14 及以上，支持 Apple 芯片和 Intel。

详见[使用指南](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。

### 安装

已有“检查更新”的版本可以直接在应用内更新。否则请先退出旧版，再把 DMG 中的 Codex Pacer 拖入“应用程序”。如果 macOS 拦截了未签名的应用，打开“系统设置 → 隐私与安全性”，在“安全性”中选择“仍要打开”，然后再次打开。
