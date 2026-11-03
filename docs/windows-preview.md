# Windows 开发预览

这是未签名的 Windows x64 开发构建。安装器按当前用户安装，无需管理员权限。重新运行安装器可覆盖升级或修复；在 Windows“已安装的应用”中卸载。升级和卸载保留偏好与已读记录。卸载会清理当前安装的注册项、快捷方式、开机启动项，以及 Pacer 写入的本机 Claude hook 和 status-line 包装，保留用户原有配置。

清理失败时，交互卸载可重试、继续卸载或取消。继续卸载会保留失败项；若遗留 Pacer hook，Claude Code 可能报错，需按卸载日志手动移除这些 Pacer 条目。静默卸载遇到清理失败会中止并保留应用文件；固定内容的清理报告保存在 Pacer 数据目录的 uninstall-cleanup.log。

便携 ZIP 仍可使用：解压整个包后运行 CodexPacer.exe；Demo.cmd 使用示例数据。请保留同目录的 Engine、Maintenance、资源和运行库。

应用需要 Windows 10 2004（内部版本 19041）或更新版本。安装器和 ZIP 包含 .NET、Swift 与 VC 运行库，应用本体可离线启动；网页登录需要 WebView2 Runtime。若系统提示登录、权限或安装依赖，请由用户本人处理。

本机 Claude hook 和 status-line 使用包内 Python，无需自行安装。启用模块后，运行时部署到当前用户的 LocalAppData，多个 Claude home 共用；移动应用后命令仍有效。卸载先移除自有 hook，再清理无引用的运行时。详情见 `docs/windows-claude-runtime.md`。

“设置 > 通用 > 登录时打开”管理当前用户的启动项。Windows 禁用启动项时，应用会显示状态并提供“启动应用”入口。卸载保留的登录资料可在卸载前通过设置中的退出登录或删除 key 操作清除。

窗口使用黑色表面。悬停展开，点击固定，Esc 取消固定；菜单可打开设置。预览版尚未完成全部平台验收，远程来源和部分系统集成仍在迁移。额度、任务和计费展示来自共享引擎。

默认读取本机 Codex、Claude 和 DeepSeek 数据。需要演示或截图时，请使用 `Demo.cmd`，不要分享真实任务、账户、凭据或原始引擎通信内容。预览包不会修改这些工具的任务记录。

构建、测试和协议说明见仓库的 `docs/windows-shell.md`。本包是 CI 构建产物，不是 GitHub Release。
