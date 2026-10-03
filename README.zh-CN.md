# Codex Pacer 2.0

[English](README.md) · [下载正式版](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)

原生 macOS 状态岛，集中显示 Codex 任务、输出速度和账户额度。悬停展开，离开收起；需要时固定在桌面。

![Codex Pacer 2.0](docs/assets/pacer-2.0.png)

- 查看本机与已启用 SSH 来源的运行、等待和本轮结束状态，点击任务打开对应会话。
- 显示运行任务的合计输出速度估算；工具等待与模型生成分开处理。
- 查看短期与七天额度、重置倒计时、配速和当前周期曲线。周期内即将到期的 banked reset 在曲线上标注。
- 本轮结束提示可在折叠状态显示；完成卡片保留到点击、状态变化或设定时间。
- 支持外观、显示器、提醒和隐私设置；菜单栏显示可选。状态岛与设置中均可退出。

**系统要求：** macOS 14 或更新，Apple Silicon 或 Intel。Liquid Glass 需要 macOS 26 或更新。已登录的 Codex 与 Python 3 用于读取账户和任务状态；SSH 来源需要现有的免交互 OpenSSH 连接。

下载 DMG，将 Codex Pacer 拖入“应用程序”。2.0 安装包使用 Developer ID 签名并经 Apple 公证。详见[使用指南](docs/usage.zh-CN.md)与[2.0 发布说明](docs/release-notes-2.0.zh-CN.md)。

## 开发

需要 Xcode 26 或更新。应用没有 npm 或 Rust 依赖。

```sh
make test
make build
```

构建在本机临时目录中完成，终端会打印 `.app` 路径。开发构建使用本地临时签名；正式包另行签名、公证。参见[开发与数据说明](docs/development.md)和[发布流程](docs/releasing.md)。

2.0 主分支仅维护 Swift 原生 macOS 实现。React/Tauri 与 Windows 1.x 可从 [Git 历史及旧版 Release](https://github.com/RyanZhangNTU/codex-pacer/releases)找回。

[贡献](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [MIT License](LICENSE)
