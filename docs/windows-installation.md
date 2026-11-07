# Windows 每用户安装

Release 工作流（推送 vVERSION tag 时，或手动运行）为 x64 和 ARM64 各生成未签名安装器（windows-installer-ARCH-unsigned）和便携 ZIP（windows-app-ARCH-unsigned）。安装生命周期测试只在 Platforms 的 PR 运行和手动运行中进行；PR 上只在改到安装器、维护、更新、打包脚本、工具链，或这些检查会启动的应用代码（启动、单实例、安装身份、通知和开机启动登记）时运行，见[持续集成](development.md#continuous-integration)。Release 工作流只打包，不重跑测试；tag 运行在同一次运行中用 Sparkle 签名 Windows 更新源，并把安装器与 Mac DMG 一起发布到同一个 GitHub Release，见[发布流程](releasing.md)。便携 ZIP 只用于开发验证：解压整个包后运行 CodexPacer.exe，并保留同目录的 Engine、Maintenance、资源和运行库。

安装器使用 Inno Setup，默认安装到 %LOCALAPPDATA%\Programs\Codex Pacer。注册项和快捷方式属于当前用户，不申请管理员权限。这由 [PrivilegesRequired=lowest](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm) 指定。应用和安装器需要 Windows 10 2004（内部版本 19041）或更新版本。安装器暂未做代码签名：首次运行若 SmartScreen 提示“Windows 已保护你的电脑”，点“更多信息 → 仍要运行”。

安装器按 Windows 显示语言自动使用简体中文或英文；其他语言的系统会先弹出选择框。中文消息来自 Inno Setup 项目的非官方翻译，固定在 `windows/ThirdParty/InnoSetup`（含许可证和来源哈希），打包前会校验。安装完成页提供“创建桌面快捷方式”“添加到开始菜单”和“运行 Codex Pacer”，默认全部勾选，点“完成”后执行；取消勾选只是不新建，不删除已有的快捷方式。应用内更新静默运行，不显示这些选项：只刷新本安装已有的快捷方式，不补回已删除的，并由更新流程自行重新打开应用。静默的全新安装按默认创建两个快捷方式。

安装包包含 .NET、Swift、VC 和 Claude helper 所需的 Python 运行库。应用本体可离线启动，网页登录需要 Windows 提供的 WebView2 Runtime。安装过程不下载运行库、不安装系统服务，也不更改系统或显卡设置。Claude 的路径、所有权与安全更新见 [本机运行时说明](windows-claude-runtime.md)。

## 升级和修复

重新运行安装器，选择原安装位置即可覆盖升级或修复。同版本文件也会替换，可修复丢失或损坏的程序文件。偏好、历史、已读记录和登录资料放在应用目录外，覆盖安装保留这些数据。

安装器从自身取出新的独立维护程序，检查当前安装后再替换文件。新版本不再包含的旧文件（按已安装清单和内容哈希判断）会在复制完成后删除；内容已变动或清单外的文件保留。

应用内更新可能使用补丁安装器：它只带有变化的文件，只能装在它对应的那个旧版本上。动任何文件之前，它先核对已安装清单的哈希，并确认它不带的每个文件都已是新内容；不符合就拒绝安装，原有安装保持不变。复制完成后会按新清单逐个校验文件。详见[自动更新](windows-automatic-updates.md#patch-updates)。即使已安装的 .NET 主程序集损坏，也能开始修复。维护只通知相同可执行文件路径、当前用户和当前会话中的应用退出，随后有界等待；不会按进程名关闭其他副本。文件仍被占用时，在覆盖前失败，不安排重启替换，也不强制结束别的应用。

请使用本地目录。网络路径、驱动器根目录和带重解析点的路径会被拒绝。不要把任务数据或其他应用的文件放进安装目录。

## 登录时打开

“设置 > 通用 > 登录时打开”管理当前安装位置的 HKCU Run 项。应用读回系统状态，不在偏好 JSON 中另存一个开关。带空格的路径保留引号；超过 Windows Run 命令长度限制的路径会显示失败。[Run 注册项约定](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys)

勾选表示已注册启动请求。Windows“启动应用”或策略仍可阻止它运行；设置页会显示禁用、策略阻止或无法确认的状态，并提供“打开启动应用”入口。应用不会改写 StartupApproved 来绕过系统禁用。更改失败时尝试恢复之前的注册值，再读回状态并显示错误。窗口重新激活时刷新，不做后台轮询。

StartupApproved 的二进制格式没有公开 API 契约。当前识别已观察到的 2/6（允许）和 3/7（禁用）状态；其他值或损坏数据显示“无法确认”。入口使用固定的 [ms-settings:startupapps](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings)。

## 卸载和数据

从 Windows“已安装的应用”卸载 Codex Pacer。确认卸载后，先预检 Claude 配置，再关闭当前安装、清理自有项并删除程序文件和安装目录。已完成的更新下载会一并删除；偏好、已读记录、更新状态和最近一次的安装日志保留。

清理失败时可选择“重试”“继续卸载”或“取消”。取消会保留应用文件；预检发现无效 JSON、过大配置或不安全路径时，也不会更改 Claude 配置或应用注册。继续卸载会删除应用文件，清理仍能安全处理的自有注册项，保留失败项，并在卸载日志中说明手动清理方法。遗留的 Pacer hook 可能调用已删除的程序，在手动移除这些 Pacer 条目前，Claude Code 可能报错。提示只列配置文件名和定位方式，不显示配置内容或任务资料。

静默卸载（/SILENT 或 /VERYSILENT）遇到清理失败会返回非零结果，保留应用文件。维护程序在数据目录的 uninstall-cleanup.log 中区分 Codex 配置、Claude 配置和 Windows 注册的清理失败。从 Windows 应用列表启动卸载也会启用 Inno 日志。排查命令行卸载时可另加 /LOG。

卸载移除当前安装自有的安装登记、开始菜单和桌面快捷方式、启动项和通知注册。不同路径的启动项、其他应用的注册值，以及用户改过的快捷方式会保留。通知清理先核对激活程序路径，再调用 SDK 的 [UnregisterAll](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.appnotifications.appnotificationmanager.unregisterall)，并移除当前可执行文件的路径映射。

Claude 配置通过共享 ClaudeHookInstaller 的卸载规则处理：只移除 Pacer 自有的当前或旧版 hook 命令；status-line 仍是 Pacer 包装时恢复原值；只移除安装记录里由 Pacer 添加且未被用户修改的环境值。原有或后来添加的用户 hooks、status-line 和其他配置不删除。处理本机默认、已配置及运行时索引记录的 Claude home，不处理远程 hooks。无安装记录时不推测归属。全部 hook 清理后，再按所有权和引用检查删除共享运行时；未知文件或用户引用会阻止删除。

偏好、历史、已读和登录资料保留。需要清除登录资料时，请在卸载前通过设置中的退出登录或删除 key 操作处理。共享卸载器也保留 Claude home 中的适配脚本与已清理的记账元数据；正常清理后，配置不再引用这些脚本。

## 演示数据

需要演示或截图时，先退出 Pacer，再从安装目录运行 `CodexPacer.exe --demo`：它只显示示例数据，不读取真实任务，也不写入正式偏好。所有副本共用同一个单实例锁，Pacer 仍在运行时只会把已有窗口调到前面。不要分享真实任务、账户、凭据或原始引擎通信内容。

## 开发验证

编译器固定为 Inno Setup 6.7.4。脚本校验官方安装包的 SHA-256 和发布者签名，以便携方式放在工作树的 output 下，不创建系统安装登记。PACER_INNO_ROOT 可指向已验证的便携工具目录。

构建桌面应用后，依次运行：

    ./scripts/windows/package-preview.ps1 -SkipBuild
    ./scripts/windows/test-installer.ps1 -Archive <ZIP>
    ./scripts/windows/package-installer.ps1 -Archive <ZIP>

生命周期测试编译独立 QA 标识的安装器，使用中文路径、独立启动项、开始菜单目录、桌面快捷方式名称和合成 Claude 配置。它验证安装、默认快捷方式、损坏修复（静默修复保持快捷方式选择）、文件占用失败、运行中覆盖安装、合成偏好与已读文件保留、启动项、卸载清理和离线 demo。无效 Claude JSON 场景覆盖静默中止、交互取消、重复重试和明确继续卸载，并检查原始字节及日志隐私；交互选择通过仅限 QA 包的参数调用同一维护入口。测试后卸载并清理测试目录。截图只包含 demo 数据。

可选的 `-CodexExecutable` 参数使用本机 Codex 和两个隔离配置测试进度上报。检查会在上报器仍运行时覆盖安装和卸载，并验证无效 TOML 会阻止卸载。成功卸载会从两个配置中撤销 Pacer 的 `pacer_progress`，让已连接的上报器停止接受估计。上报器运行时位于应用目录之外，随用户数据保留。

使用屏幕前，测试等待其他展示或背景测试进程退出；每分钟检查一次，最多等 30 分钟。测试只关闭自己安装位置的应用。可选 ProtectedProcessId 参数只检查指定进程仍存在，不向它发送消息。

本机 Codex 进程树的 HKCU 被隔离；树内注册表测试不能证明真实系统生效。真实 HKCU 的登记、启动项、通知和卸载检查需在进程树外的当前交互用户任务中补跑，CI 安装生命周期测试也必须通过。文件系统检查仍是实际文件系统。

这些检查不代替重新登录、干净系统、其他 Windows 设备或 ARM64 设备上的实机验证；ARM64 CI 只构建和打包。
