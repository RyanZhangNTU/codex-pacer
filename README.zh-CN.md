# Codex Pacer 2.1

[English](README.md) · [下载最新版本](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)

原生 macOS 灵动岛，集中显示 Codex 任务、输出速度和账户额度。悬停展开，离开收起；需要时固定在桌面。

![Codex Pacer 2.0](docs/assets/pacer-2.0.png)

- 查看本机与已启用 SSH 来源的运行、等待和本轮结束状态，点击任务打开对应会话。
- 显示运行任务的合计输出速度估算；工具等待与模型生成分开处理。
- 查看短期与七天额度、重置倒计时、配速和当前周期曲线。周期内即将到期的 banked reset 在曲线上标注。
- 查看账户 Credit 余额与可用重置券，点击重置次数查看具体到期时间，也可点击曲线上的到期标记。
- 本轮结束提示可在折叠状态显示；完成卡片保留到点击、状态变化或设定时间。
- 支持液态玻璃、显示器、提醒和隐私设置；菜单栏显示可选。灵动岛与设置中均可退出。
- 所有显示器均可选择自动、刘海或悬浮模式；任务按每页三个切换，额度始终可见。
- 默认使用自适应宽度，也可在设置中通过预览和滑块调整一个统一宽度。
- 支持简体中文与英文，默认跟随 Mac 语言，也可在设置中选择。
- 支持应用内更新，默认每天检查，点击安装后自动完成下载、验证、替换和重启。

**系统要求：** macOS 14 或更新，Apple Silicon 或 Intel。Liquid Glass 需要 macOS 26 或更新。已登录的 Codex 与 Python 3 用于读取账户和任务状态；SSH 来源需要现有的免交互 OpenSSH 连接。

## 安装未签名版

未签名版首次打开 DMG 时可能被 macOS 拦截。手动替换前先退出旧版。若当前版本已有“检查更新”，可直接使用它完成下载、验证、安装和重启。

1. [从最新 Release 下载 DMG 安装包](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)并双击，出现系统拦截提示后关闭提示。
2. 前往 **系统设置 → 隐私与安全**，**滚动到页面最下方的“安全性”**，找到刚被拦截的安装包，点击 **“打开”或“仍要打开”**，按提示确认。
3. **再次双击 DMG**，将 **Codex Pacer** 拖入右侧的 **Applications（应用程序）**，再从应用程序启动。

若启动应用时再次被拦截，按第 2 步放行 Codex Pacer，再双击启动。

![在隐私与安全页面最下方的安全性中点击仍要打开](docs/assets/macos-open-anyway.png)

[首次打开帮助（Apple 官方）](https://support.apple.com/zh-cn/102445) · [使用指南](docs/usage.zh-CN.md)

## 开发

需要 Xcode 26 或更新。应用没有 npm 或 Rust 依赖。

```sh
make test TEST_FILTER='CompletionInboxTests|SessionNameTests' # 开发时只跑相关测试
make build # 需要应用做界面验证时使用
```

发布候选只执行一次全量 `make test`。构建在本机临时目录中完成并复用固定依赖缓存，终端会打印 `.app` 路径。`make release-unsigned` 生成本次未签名通用 DMG，发布无需额外构建同源预览版；需要 Developer ID 签名和 Apple 公证时使用独立的 `make release` 流程。参见[开发与数据说明](docs/development.md)和[发布流程](docs/releasing.md)。

当前代码库仅维护 Swift 原生 macOS 实现。React/Tauri 与 Windows 1.x 可从 [Git 历史及旧版 Release](https://github.com/RyanZhangNTU/codex-pacer/releases)找回。

[贡献](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [MIT License](LICENSE)
