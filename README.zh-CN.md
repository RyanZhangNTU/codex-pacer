# Codex Pacer 3.0 候选版

[English](README.md) · [下载最新版本](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)

原生 macOS 灵动岛，集中显示 Codex 与 Claude Code 的任务、输出速度和账户额度。悬停展开，离开收起；需要时固定在桌面。

3.0.0 build 48 当前是开发候选版。上方“下载最新版本”指向已公开发布的版本，不表示本候选版已经发布或安装。

![早期 Codex Pacer 2.0 界面](docs/assets/pacer-2.0.png)

- 展开后在上方统一查看 Codex 与 Claude Code 的本机、SSH 任务，以及 Codex Remote Control 任务；青绿色代表 Codex，暖橙色代表 Claude。
- 用并排双圆环同时查看 Codex / Claude：圆环显示剩余额度，白色刻度标出均匀使用时应剩的位置，并标注充裕 / 正常 / 偏快；双模块时圆环显示 7d，5h 显示在各环下一行。圆环布局下，单模块同时显示两个周期；确认账户仅有每周限制时，5h 使用 PRO 占位。环内只突出额度数字与简短倒计时，来源和更新时间在悬停提示及设置中查看。折叠时仅以颜色区分两个服务的百分比。
- 仅启用 Codex，且主账户已返回额度限制但没有 5h 窗口时，使用原来的额度条形展示，保留所有服务实际返回的窗口，包括非标准或未知时长的窗口。
- 在设置中独立启用或关闭模块；默认根据应用/CLI 安装情况自动检测，手动选择会在重启后保留，也可恢复自动检测。
- 查看运行、等待、审批和本轮结束状态。Codex 任务可打开会话；Claude 可打开已映射的 Desktop 会话，或通过已安装 CLI 的 Desktop / Terminal resume 路径继续会话，打开不会发送提示词。
- 显示可用的合计 TPS 与首输出延迟；子代理归入主任务并累加 TPS。Claude 的准确请求时间来自匹配的 OTLP 数值记录；确认停止后，权威 transcript token 数和完整观察窗口可提供吞吐率估算。首输出延迟需要真实的流式显示回调或服务报告的 TTFT；Desktop SDK 与 `-p` 仅发送最终消息时，缺少数值遥测便保持未知，不能从消息完成记录推算。工具执行或等待新测量时保留上次速率，15 秒内显示白色，超过 15 秒显示灰色。
- 查看服务提供的短期与七天额度、重置时间、配速和周期曲线。缺少重置日期时保留未知状态，不推算配速或曲线周期。
- 在设置中查看额度历史、服务提供的 Credit 余额、重置券及到期详情；不会给 Claude 编造 Credit 或 banked reset 等价数据。
- 本轮结束提示可在折叠状态显示；成功打开 Codex 会话或已验证 Claude Desktop 目标后移除完成卡，正常重启后仍保持已读。状态变化或设定时间到期也会移除。Claude 的 Terminal resume 回退会保留卡片。
- 支持液态玻璃、显示器、提醒和隐私设置；菜单栏显示可选。灵动岛与设置中均可退出。
- 所有显示器均可选择自动、刘海或悬浮模式；任务按每页三个切换，额度始终可见。
- 默认使用自适应宽度，也可在设置中通过预览和滑块调整一个统一宽度。
- 自定义单行折叠栏：按任务、性能、额度、警告分类选择组件，拖动调整顺序及左、右位置，预览即时更新，一次保存即可生效。
- 支持简体中文与英文，默认跟随 Mac 语言，也可在设置中选择。
- 支持应用内更新，默认每天检查，点击安装后自动完成下载、验证、替换和重启。

**系统要求：** macOS 14 或更新，Apple Silicon 或 Intel。Liquid Glass 需要 macOS 26 或更新。安装并登录实际使用的模块；本机原生读取器观察可用日志，可选 Claude hooks 补充生命周期与输入/审批事件。配置工具和远程 helper 需要 Python 3，SSH 主机支持 Python 3.6 及以上。Codex Remote Control 需要 Codex 桌面端保持开启、连接远程主机，并由 stream owner 加载对应会话；SSH 来源需要现有的免交互 OpenSSH 连接。

Claude 额度优先读取同账户新鲜 status-line 样本，其次使用 Pacer 自己的 WebKit 会话。“登录 Claude”打开专用 claude.ai 窗口，由用户完成正常网页登录与验证；已有会话只执行额度 GET，多组织需要明确选择。生产环境从不读取其他应用的 Keychain 或 Safe Storage，登录时也不读取。cookie 仅由 WebKit 管理，不写入设置、JSON 或日志。Pacer 自有 OAuth 缓存与显式提供的环境变量/文件凭据仅作安静的兼容回退。会话过期可能需要重新登录，不保证永久有效。缺少重置日期和旧数据会明确显示；仅使用 Claude 的 SSH 环境也可在设置中添加已有 SSH 别名。参见[使用指南](docs/usage.zh-CN.md)与[数据说明](docs/development.md)。

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
