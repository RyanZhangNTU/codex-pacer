# Codex Pacer 2.0

[English](README.md) · [下载 2.0.0 未签名版](https://github.com/RyanZhangNTU/codex-pacer/releases/tag/v2.0.0)

原生 macOS 灵动岛，集中显示 Codex 任务、输出速度和账户额度。悬停展开，离开收起；需要时固定在桌面。

![Codex Pacer 2.0](docs/assets/pacer-2.0.png)

- 查看本机与已启用 SSH 来源的运行、等待和本轮结束状态，点击任务打开对应会话。
- 显示运行任务的合计输出速度估算；工具等待与模型生成分开处理。
- 查看短期与七天额度、重置倒计时、配速和当前周期曲线。周期内即将到期的 banked reset 在曲线上标注。
- 查看账户 Credit 余额与可用重置券，点击到期标记查看具体日期。
- 本轮结束提示可在折叠状态显示；完成卡片保留到点击、状态变化或设定时间。
- 支持液态玻璃、显示器、提醒和隐私设置；菜单栏显示可选。灵动岛与设置中均可退出。

**系统要求：** macOS 14 或更新，Apple Silicon 或 Intel。Liquid Glass 需要 macOS 26 或更新。已登录的 Codex 与 Python 3 用于读取账户和任务状态；SSH 来源需要现有的免交互 OpenSSH 连接。

## 安装未签名版

**2.0.0 未使用 Developer ID 签名，也未经 Apple 公证。** 应用只保留运行所需的本地 ad hoc 签名，不能据此验证开发者身份。

1. 从 [v2.0.0 Release](https://github.com/RyanZhangNTU/codex-pacer/releases/tag/v2.0.0) 下载 `Codex-Pacer-2.0.0-universal-unsigned.dmg`，打开后将应用拖入“应用程序”。更新前先退出旧版。
2. 双击 Codex Pacer 一次。如果出现无法验证开发者或无法检查恶意软件的提示，关闭提示框。
3. 前往 **苹果菜单 → 系统设置 → 隐私与安全 → 安全性**，找到 Codex Pacer 的拦截提示，点击 **“打开”或“仍要打开”**（不同 macOS 版本用词可能不同）。
4. 在确认框中选择 **“仍要打开”或“打开”**，按提示验证登录身份。以后可正常双击启动。

请先确认文件来自本仓库，可用 Release 中的 `SHA256SUMS.txt` 核对下载文件。若未看到按钮，重新尝试打开应用后再返回设置；Apple 说明该选项在尝试打开后约一小时内可用。步骤依据 [Apple 官方使用手册](https://support.apple.com/zh-cn/guide/mac-help/mh40616/mac)及[安全打开 App 说明](https://support.apple.com/zh-cn/102445)。

详见[使用指南](docs/usage.zh-CN.md)与[2.0 发布说明](docs/release-notes-2.0.zh-CN.md)。本次 Release 同时附带横版、竖版中文宣传图。

## 开发

需要 Xcode 26 或更新。应用没有 npm 或 Rust 依赖。

```sh
make test
make build
```

构建在本机临时目录中完成，终端会打印 `.app` 路径。`make release-unsigned` 生成本次未签名通用 DMG；需要 Developer ID 签名和 Apple 公证时使用独立的 `make release` 流程。参见[开发与数据说明](docs/development.md)和[发布流程](docs/releasing.md)。

2.0 主分支仅维护 Swift 原生 macOS 实现。React/Tauri 与 Windows 1.x 可从 [Git 历史及旧版 Release](https://github.com/RyanZhangNTU/codex-pacer/releases)找回。

[贡献](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [MIT License](LICENSE)
