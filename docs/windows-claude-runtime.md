# Windows Claude 本机运行时

Windows 包附带官方 CPython 3.14.10 x64 embeddable runtime。Claude hook 和 status-line 不再依赖用户安装的 Python、PATH 中的 python3 或 Microsoft Store 别名。遥测继续使用共享引擎中的本机 loopback HTTP 服务，不启动另一个 Python 服务。

采用嵌入式 Python，是为了复用原有共享 helper 的事件、归属、额度和隐私规则。共享 claude_hook.py 的内容保持不变；Windows 适配层只替换文件安全检查与锁。文件按句柄检查所有者、重解析点和硬链接，检查通过后才能截断；锁使用最多等待 2 秒的 Windows 内核 mutex，不轮询。

## 路径与升级

第一次启用本机 Claude 模块时，将已校验的运行时部署到：

    %LOCALAPPDATA%\CodexPacer\ClaudeRuntime\3.14.10-90905e64a840\

所有 Claude home 共用这个用户级目录。每个 home 仍只保留与 Mac 对等的 hook 脚本和记账文件。命令包含带完整双引号的 python.exe、脚本及 home 的绝对路径，并通过 Windows cmd 启动；实际测试覆盖 cmd、Git Bash、PowerShell、中文路径、空格路径和 UTF-8 stdin。移动应用、切换安装目录或使用便携包不会改变已写入的运行时路径。

根目录和每个版本目录都有 .pacer-owned.json 所有权标记。写入、修复和删除前检查文件所有者与路径上的重解析点；非空但无标记的目录不会被接管。修复只替换标记内的文件，额外文件会阻止操作。

根标记记录 Pacer 曾连接的 Claude home，最多 128 个。升级后先扫描这些 home 的 settings.json 和安装记录中的原 status-line；任何字符串仍引用旧版本时，都保留该版本，包括用户 hook 和被包装的用户 renderer。配置无效、过大、不可读或目录含未知文件时保留运行时。只按文件清单删除已确认归属、内容未变且未被引用的旧版本，不递归删除目录。

应用启动、模块开关和 home 变更触发一次异步安装或移除。helper 请求有 5 秒超时，失败可在 Claude 设置页重试；无空闲轮询。Demo 和只读引擎不会安装 hook。停用模块移除当前 home 的 Pacer 条目；退出应用保留 hook。

完整卸载通过共享 ClaudeHookInstaller 先清理所有已记录 home 的 Pacer hooks、环境值和 status-line 包装，恢复用户原配置，再删除无引用的自有运行时。预检失败时沿用安装器的重试、继续或取消流程；继续卸载会保留无法安全清理的运行时和配置。详见 [Windows 安装说明](windows-installation.md)。

## 固定依赖与安全更新

固定信息在 windows/InstallerSupport/Resources/python-runtime-lock.json：版本、官方 ZIP 地址、SHA-256、发布者和需检查签名的文件。构建脚本校验 ZIP 哈希、四个可执行文件/库的 Python Software Foundation Authenticode 签名，并逐文件生成部署清单。包内保留官方 LICENSE.txt；当前运行时 37 个文件，共 24,450,611 字节，约 23.3 MiB，压缩包约 12 MB。[Python 发行说明](https://www.python.org/downloads/release/python-31410/)、[嵌入式发行包说明](https://docs.python.org/3/using/windows.html#the-embeddable-package)

安全更新时，从 Python 官方取得修复版本，核对官方来源及签名，再更新锁文件中的版本、URL、哈希和签名文件名。使用干净构建生成新包，运行共享测试、无用户 Python 的三种 shell 测试和安装生命周期测试。新版本部署到新的哈希目录，共享安装器迁移自有命令；旧版本仅在全部已记录 home 不再引用时回收。不覆盖正在使用的解释器，也不自动下载运行时。

应用与安装器仍未签名。Python 的原签名保留，不能代替应用签名；SmartScreen、企业策略或杀软仍可能阻止运行。本步骤不修改系统安全设置、不添加排除项。

## 验证与限制

测试全部使用合成 stdin、隔离 HOME/CLAUDE_CONFIG_DIR/LOCALAPPDATA 和不含 Python 的 PATH，不改用户真实 Claude 配置。脚本 scripts/windows/test-claude-runtime.ps1 覆盖配置命令、事件归属、并发写入、锁超时、隐私、status-line 转发、修复、应用移动和跨 home 卸载。原遥测测试继续验证本机 HTTP、gzip、端口占用和停止清理。

当前支持本地驱动器路径。含控制字符或 shell 展开/控制字符（双引号、美元符号、反引号、百分号、感叹号、插入符号、与号、竖线、尖括号）的路径会安全拒绝，不写入不可用命令。空格和中文已验证。命令长度上限为 7,000 个 UTF-16 单元。

回收范围是 Pacer 记录的 home；手动复制到未登记 home 的命令不会被自动发现。已运行的 Claude 进程也可能缓存旧配置；若旧解释器仍被占用，清理保留它供之后重试。实际 Claude Code 版本、其他 Windows 设备和 ARM64 仍需验收。

本机 Codex 进程树的 HKCU 与真实交互用户视图隔离，树内注册表测试只证明隔离视图。安装登记、Run、StartupApproved、通知注册及卸载的真实系统行为，由 GitHub CI 和进程树外的当前用户临时交互计划任务检查；测试任务及安装在结束后移除。
