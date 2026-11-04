# Windows 使用说明

Windows 版提供 x64 和 ARM64 安装器，暂未做代码签名：首次运行若 SmartScreen 提示“Windows 已保护你的电脑”，点“更多信息 → 仍要运行”。安装器按当前用户安装，无需管理员权限。重新运行安装器可覆盖升级或修复；在 Windows“已安装的应用”中卸载。升级和卸载保留偏好与已读记录。卸载会清理当前安装的注册项、快捷方式、开机启动项，以及 Pacer 写入的本机 Claude hook 和 status-line 包装，保留用户原有配置。

清理失败时，交互卸载可重试、继续卸载或取消。继续卸载会保留失败项；若遗留 Pacer hook，Claude Code 可能报错，需按卸载日志手动移除这些 Pacer 条目。静默卸载遇到清理失败会中止并保留应用文件；固定内容的清理报告保存在 Pacer 数据目录的 uninstall-cleanup.log。

CI 构建的便携 ZIP 只用于开发验证：解压整个包后运行 CodexPacer.exe；Demo.cmd 使用示例数据。请保留同目录的 Engine、Maintenance、资源和运行库。

应用需要 Windows 10 2004（内部版本 19041）或更新版本。安装器和 ZIP 包含 .NET、Swift 与 VC 运行库，应用本体可离线启动；网页登录需要 WebView2 Runtime。若系统提示登录、权限或安装依赖，请由用户本人处理。

本机 Claude hook 和 status-line 使用包内 Python，无需自行安装。启用模块后，运行时部署到当前用户的 LocalAppData，多个 Claude home 共用；移动应用后命令仍有效。卸载先移除自有 hook，再清理无引用的运行时。详情见 `docs/windows-claude-runtime.md`。

“设置 > 通用 > 登录时打开”管理当前用户的启动项。Windows 禁用启动项时，应用会显示状态并提供“启动应用”入口。卸载保留的登录资料可在卸载前通过设置中的退出登录或删除 key 操作清除。

Windows 11 22H2 及更新版本默认使用玻璃表面；更早的系统、关闭透明效果或开启高对比度时使用黑色表面。悬停展开，点击固定，Esc 取消固定；菜单可打开设置。额度、任务和计费展示来自与 Mac 共用的引擎，SSH、WSL、Remote Control 和 Claude 云端项目都在“设置 > 连接”中管理。

安装版每天检查一次更新，可在“设置 > 通用”中关闭自动检查。发现新版本时，Pacer 的更新窗口显示更新说明，下载时显示实际进度。更新源和安装包都需通过 Ed25519 签名校验；确认安装后，安装程序只显示进度，不再逐页询问，装完自动重新打开 Pacer。

默认读取本机 Codex、Claude 和 DeepSeek 数据。需要演示或截图时，请使用 `Demo.cmd`，不要分享真实任务、账户、凭据或原始引擎通信内容。Pacer 不会修改这些工具的任务记录。

构建、测试和协议说明见仓库的 `docs/windows-shell.md`。正式版本从 4.2.2 起与 Mac 版在同一个 GitHub Release 发布；CI 构建产物只用于开发验证。
