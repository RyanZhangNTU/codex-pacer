# Codex Pacer 2.0.0（未签名版）

Codex Pacer 2.0 改为 SwiftUI/AppKit 原生 macOS 灵动岛，将任务进度、输出速度和账户额度集中在一个可展开的面板中。

**本版本未使用 Developer ID 签名，也未经 Apple 公证。** 应用保留 Apple Silicon 运行所需的本地 ad hoc 签名；它不代表通过 Apple 的开发者身份验证或恶意软件检查。

[下载 Apple Silicon / Intel 通用安装包](https://github.com/RyanZhangNTU/codex-pacer/releases/download/v2.0.0/Codex-Pacer-2.0.0-universal-unsigned.dmg)

- 本机与已启用 SSH 来源的任务状态、合计输出速度估算和会话跳转。
- 短期及七天额度、配速、重置倒计时与当前周期曲线；周期内即将到期的重置券标记与具体日期；账户 Credit 余额。
- 本轮结束卡片保留与折叠提醒，可调整保留时间和系统通知。
- Liquid Glass、显示器与隐私设置；可选菜单栏显示；灵动岛及设置中均可退出。
- 移除应用内数据与计算说明，相关内容集中在开发文档。
- 删除旧 React/Tauri/Windows 构建链、旧版测试与实验文档，保留原生回归测试；原生预览版偏好与缓存延续。

## 安装与首次打开

支持 Apple Silicon 和 Intel，macOS 14 或更新；Liquid Glass 需要 macOS 26 或更新。

1. 下载 `Codex-Pacer-2.0.0-universal-unsigned.dmg`，打开后拖入“应用程序”。更新前先退出旧版。
2. 双击 Codex Pacer；遇到无法验证开发者或无法检查恶意软件的提示时，先关闭提示框。
3. 打开 **系统设置 → 隐私与安全 → 安全性**，在 Codex Pacer 的拦截提示旁选择 **“打开”或“仍要打开”**。
4. 按确认框提示继续 **“仍要打开 / 打开”** 并验证登录身份，以后即可正常启动。

请确认安装包来自本 Release，并用附带的 `SHA256SUMS.txt` 校验。若没有看到相应按钮，请重新尝试启动后返回设置；该入口在尝试打开后约一小时内可用。操作依据 [Apple 官方文档](https://support.apple.com/zh-cn/guide/mac-help/mh40616/mac)和[安全打开 App 说明](https://support.apple.com/zh-cn/102445)。

需要已登录的 Codex 与 Python 3。SSH 监听沿用现有配置与免交互认证。实时事件可用性取决于 Codex 客户端/协议，必要时使用日志兜底；输出速度为生成期间估算值。

2.0 主分支仅维护原生 macOS。Windows 与 React/Tauri 1.x 仍可通过旧 Release 和 Git 历史使用。

本版通过 123 项原生回归测试，包含 arm64 与 x86_64 两种架构；本机验证在 Apple Silicon/macOS 27 上完成，Intel 和更早 macOS 未进行实机验证。横版与竖版中文宣传图随本 Release 提供。
