# Windows 每用户安装

Windows CI 保留便携 ZIP（windows-app-x64-unsigned），并提供未签名安装器（windows-installer-x64-unsigned）。这些是 develop 的测试产物，不是 GitHub Release。

安装器使用 Inno Setup，默认安装到 %LOCALAPPDATA%\Programs\Codex Pacer。注册项和开始菜单快捷方式属于当前用户，不申请管理员权限。这由 [PrivilegesRequired=lowest](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm) 指定。安装器向导目前使用英文；应用支持中英文。

安装包包含 .NET、Swift 和 VC 运行库。应用本体可离线启动，网页登录需要 Windows 提供的 WebView2 Runtime。安装过程不下载运行库、不安装系统服务，也不更改系统或显卡设置。

## 升级和修复

重新运行安装器，选择原安装位置即可覆盖升级或修复。同版本文件也会替换，可修复丢失或损坏的程序文件。偏好、历史、已读记录和登录资料放在应用目录外，覆盖安装保留这些数据。

安装器从自身取出新的独立维护程序，检查当前安装后再替换文件。即使已安装的 .NET 主程序集损坏，也能开始修复。维护只通知相同可执行文件路径、当前用户和当前会话中的应用退出，随后有界等待；不会按进程名关闭其他副本。文件仍被占用时，在覆盖前失败，不安排重启替换，也不强制结束别的应用。

请使用本地目录。网络路径、驱动器根目录和带重解析点的路径会被拒绝。不要把任务数据或其他应用的文件放进安装目录。

## 登录时打开

“设置 > 通用 > 登录时打开”管理当前安装位置的 HKCU Run 项。应用读回系统状态，不在偏好 JSON 中另存一个开关。带空格的路径保留引号；超过 Windows Run 命令长度限制的路径会显示失败。[Run 注册项约定](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys)

勾选表示已注册启动请求。Windows“启动应用”或策略仍可阻止它运行；设置页会显示禁用、策略阻止或无法确认的状态，并提供“打开启动应用”入口。应用不会改写 StartupApproved 来绕过系统禁用。更改失败时尝试恢复之前的注册值，再读回状态并显示错误。窗口重新激活时刷新，不做后台轮询。

StartupApproved 的二进制格式没有公开 API 契约。当前识别已观察到的 2/6（允许）和 3/7（禁用）状态；其他值或损坏数据显示“无法确认”。入口使用固定的 [ms-settings:startupapps](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings)。

## 卸载和数据

从 Windows“已安装的应用”卸载 Codex Pacer。确认卸载后，先关闭当前安装并清理注册，再删除程序文件。清理失败会中止文件删除；可先修复安装后重试。

卸载移除当前安装自有的安装登记、开始菜单快捷方式、启动项和通知注册。不同路径的启动项、其他应用的注册值，以及用户改过的快捷方式会保留。通知清理先核对激活程序路径，再调用 SDK 的 [UnregisterAll](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.appnotifications.appnotificationmanager.unregisterall)，并移除当前可执行文件的路径映射。

Claude 配置通过共享 ClaudeHookInstaller 的卸载规则处理：只移除 Pacer 自有的当前或旧版 hook 命令；status-line 仍是 Pacer 包装时恢复原值；只移除安装记录里由 Pacer 添加且未被用户修改的环境值。原有或后来添加的用户 hooks、status-line 和其他配置不删除。只处理当前本机的默认或已配置 Claude home，不处理远程 hooks。无安装记录时不推测归属。

偏好、历史、已读和登录资料保留。需要清除登录资料时，请在卸载前通过设置中的退出登录或删除 key 操作处理。共享卸载器也保留 Claude home 中的适配脚本与已清理的记账元数据；配置中不再引用这些脚本。

## 开发验证

编译器固定为 Inno Setup 6.7.4。脚本校验官方安装包的 SHA-256 和发布者签名，以便携方式放在工作树的 output 下，不创建系统安装登记。PACER_INNO_ROOT 可指向已验证的便携工具目录。

构建桌面应用后，依次运行：

    ./scripts/windows/package-preview.ps1 -SkipBuild
    ./scripts/windows/test-installer.ps1 -Archive <ZIP>
    ./scripts/windows/package-installer.ps1 -Archive <ZIP>

生命周期测试编译独立 QA 标识的安装器，使用中文路径、独立启动项、开始菜单目录和合成 Claude 配置。它验证安装、损坏修复、文件占用失败、运行中覆盖安装、合成偏好与已读文件保留、启动项、卸载清理和离线 demo；测试后卸载并清理测试目录。截图只包含 demo 数据。

使用屏幕前，测试确认没有原型或展示测试进程占用桌面；占用时每分钟检查一次，最多等 30 分钟。测试只关闭自己安装位置的应用。可选 ProtectedProcessId 参数只检查指定进程仍存在，不向它发送消息。

这些检查不代替重新登录、干净系统、其他 Windows 设备或 ARM64 的验收。以 coverage 中记录的实机范围为准。
