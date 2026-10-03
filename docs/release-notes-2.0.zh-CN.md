# Codex Pacer 2.0 正式版

Codex Pacer 2.0 改为 SwiftUI/AppKit 原生 macOS 状态岛，将任务进度、输出速度和账户额度集中在一个可展开的面板中。

- 本机与已启用 SSH 来源的任务状态、合计输出速度估算和会话跳转。
- 短期及七天额度、配速、重置倒计时与当前周期曲线；周期内即将到期的 banked reset 标记。
- 本轮结束卡片保留与折叠提醒，可调整保留时间和系统通知。
- Liquid Glass、显示器与隐私设置；可选菜单栏显示；状态岛及设置中均可退出。
- 移除应用内数据与计算说明，相关内容集中在开发文档。
- 删除旧 React/Tauri/Windows 构建链、旧版测试与实验文档，保留原生回归测试；原生预览版偏好与缓存延续。

**安装：** 下载 `Codex-Pacer-2.0.0-universal.dmg`，将应用拖入“应用程序”。支持 Apple Silicon 和 Intel，macOS 14 或更新；Liquid Glass 需要 macOS 26 或更新。安装包使用 Developer ID 签名，并经 Apple 公证与 stapling。

需要已登录的 Codex 与 Python 3。SSH 监听沿用现有配置与免交互认证。实时事件可用性取决于 Codex 客户端/协议，必要时使用日志兜底；输出速度为生成期间估算值。

2.0 主分支仅维护原生 macOS。Windows 与 React/Tauri 1.x 仍可通过旧 Release 和 Git 历史使用。
