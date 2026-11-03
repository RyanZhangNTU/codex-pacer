# Windows Claude 本机运行时

Windows 包附带官方 CPython 3.14.10 x64 embeddable runtime。Claude hook 和 status-line 不再依赖用户安装的 Python、PATH 中的 python3 或 Microsoft Store 别名。遥测继续使用共享引擎中的本机 loopback HTTP 服务，不启动另一个 Python 服务。

采用嵌入式 Python，是为了复用原有共享 helper 的事件、归属、额度和隐私规则。共享 claude_hook.py 的内容保持不变；Windows 适配层处理文件安全检查、锁和原 status-line renderer 的执行器。文件按句柄检查所有者、重解析点和硬链接，检查通过后才能截断；锁使用最多等待 2 秒的 Windows 内核 mutex，不轮询。

## 路径与升级

第一次启用本机 Claude 模块时，将已校验的运行时部署到：

    %LOCALAPPDATA%\CodexPacer\ClaudeRuntime\3.14.10-90905e64a840\

所有 Claude home 共用这个用户级目录。每个 home 仍只保留与 Mac 对等的 hook 脚本和记账文件。移动应用、切换安装目录或使用便携包不会改变已写入的运行时路径。

Windows 上，Claude Code 的 hook 和 statusLine 默认经 Git Bash 执行；未安装 Git Bash 时改用 PowerShell。[hook 文档](https://code.claude.com/docs/en/hooks#command-hook-fields)、[statusLine 文档](https://code.claude.com/docs/en/statusline#windows-configuration) 因此启动命令按以下顺序选择：

1. Python、脚本和 home 的绝对路径只含可直接传递的字符时，写入不带引号的 `C:/.../python.exe -S C:/.../pacer/hook.py hook C:/...`。这些参数没有空格或 shell 特殊字符，也不以 POSIX 的斜杠开头。
2. 否则调用 `GetShortPathNameW`，仅在 Python 和 home 都能取得安全的 8.3 路径时直接启动。卷禁用 8.3、短名称不存在或返回值仍含特殊字符时，不使用这一档；不修改卷设置。
3. 最后才使用 Windows 自带 PowerShell 的 `-File` 入口。PowerShell 通过 Win32 系统目录定位，不从 PATH 查找。Python、脚本和 home 全部加双引号；薄脚本随自有运行时存放，按字节转发 stdin/stdout/stderr，不解析事件或计算额度。这个子进程使用 `RemoteSigned`，不更改全局执行策略；企业组策略仍可能阻止执行。

第三档每次工具事件都会多启动一个 PowerShell，通常额外需要 150 至 400 毫秒。设置页会提示这一开销，普通路径和可用的短路径不经过 PowerShell。`test-claude-runtime.ps1` 输出每档、每种执行器下五次实际 hook 调用的耗时。本机与 CI 同时验证 hook、statusLine 和本机 HTTP telemetry；测试会清除 MSYS 参数转换的豁免变量。旧 `cmd.exe /D/C` 包装会被迁移，因为 Git Bash 可把这个开关改成 `D:/C`。[MSYS2 参数转换说明](https://www.msys2.org/docs/filesystem-paths/#process-arguments)

转发用户原 status-line 时，Windows 适配层优先使用 `CLAUDE_CODE_GIT_BASH_PATH`，否则查找 Git for Windows 的标准安装位置；没有可用 Git Bash 时使用系统 PowerShell。显式指定但不可用的 Bash 路径也使用 PowerShell。原命令不会交给 Python `shell=True` 默认选择的 cmd.exe。stdin/stdout 按字节转发，保留 10 秒超时；普通 hook 不加载这层 subprocess 适配。测试分别执行 Bash 和 PowerShell 专用 renderer，并断言 UTF-8 输入原样返回。编译前的快速诊断只报告固定布尔值、字节数和错误码。

根目录和每个版本目录都有 .pacer-owned.json 所有权标记。写入、修复和删除前检查文件所有者与路径上的重解析点；非空但无标记的目录不会被接管。修复只替换标记内的文件，额外文件会阻止操作。

根标记记录 Pacer 曾连接的 Claude home，最多 128 个。升级后先扫描这些 home 的 settings.json 和安装记录中的原 status-line；长路径或 8.3 路径仍引用旧版本时，都保留该版本，包括用户 hook 和被包装的用户 renderer。配置无效、过大、不可读或目录含未知文件时保留运行时。新旧 Windows 命令按完整参数匹配归属，包括旧 `python3`、旧 cmd 包装、直接调用、短路径和 PowerShell 回退。只按文件清单删除已确认归属、内容未变且未被引用的旧版本，不递归删除目录。

应用启动、模块开关和 home 变更触发一次异步安装或移除。helper 请求有 5 秒超时，失败可在 Claude 设置页重试；无空闲轮询。Demo 和只读引擎不会安装 hook。停用模块移除当前 home 的 Pacer 条目；退出应用保留 hook。

完整卸载通过共享 ClaudeHookInstaller 先清理所有已记录 home 的 Pacer hooks、环境值和 status-line 包装，恢复用户原配置，再删除无引用的自有运行时。预检失败时沿用安装器的重试、继续或取消流程；继续卸载会保留无法安全清理的运行时和配置。详见 [Windows 安装说明](windows-installation.md)。

## 固定依赖与安全更新

固定信息在 windows/InstallerSupport/Resources/python-runtime-lock.json：版本、官方 ZIP 地址、SHA-256、发布者和需检查签名的文件。构建脚本校验 ZIP 哈希、四个可执行文件/库的 Python Software Foundation Authenticode 签名，并逐文件生成部署清单。包内保留官方 LICENSE.txt；官方 Python 部分为 37 个文件，共 24,450,611 字节，约 23.3 MiB，压缩包约 12 MB；另附 Pacer 自有的 `pacer-launch.ps1`，同样受文件哈希清单、修复和卸载检查保护。[Python 发行说明](https://www.python.org/downloads/release/python-31410/)、[嵌入式发行包说明](https://docs.python.org/3/using/windows.html#the-embeddable-package)

安全更新时，从 Python 官方取得修复版本，核对官方来源及签名，再更新锁文件中的版本、URL、哈希和签名文件名。使用干净构建生成新包，运行共享测试、无用户 Python 的三种 shell 测试和安装生命周期测试。新版本部署到新的哈希目录，共享安装器迁移自有命令；旧版本仅在全部已记录 home 不再引用时回收。不覆盖正在使用的解释器，也不自动下载运行时。

应用与安装器仍未签名。Python 的原签名保留，不能代替应用签名；SmartScreen、企业策略或杀软仍可能阻止运行。本步骤不修改系统安全设置、不添加排除项。

## 验证与限制

测试全部使用合成 stdin、隔离 HOME/CLAUDE_CONFIG_DIR/LOCALAPPDATA 和不含 Python 的 PATH，不改用户真实 Claude 配置。脚本 scripts/windows/test-claude-runtime.ps1 覆盖配置命令、事件归属、并发写入、锁超时、隐私、status-line 转发、修复、应用移动和跨 home 卸载。原遥测测试继续验证本机 HTTP、gzip、端口占用和停止清理。

当前支持本地驱动器路径。含控制字符或 shell 展开/控制字符（双引号、美元符号、反引号、百分号、感叹号、插入符号、与号、竖线、尖括号）的路径会安全拒绝，不写入不可用命令。空格和中文已验证。命令长度上限为 7,000 个 UTF-16 单元。

回收范围是 Pacer 记录的 home；手动复制到未登记 home 的命令不会被自动发现。已运行的 Claude 进程也可能缓存旧配置；若旧解释器仍被占用，清理保留它供之后重试。实际 Claude Code 版本、其他 Windows 设备和 ARM64 仍需验收。

本机 Codex 进程树的 HKCU 与真实交互用户视图隔离，树内注册表测试只证明隔离视图。安装登记、Run、StartupApproved、通知注册及卸载的真实系统行为，由 GitHub CI 和进程树外的当前用户临时交互计划任务检查；测试任务及安装在结束后移除。
