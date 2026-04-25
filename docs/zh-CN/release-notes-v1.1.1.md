# Codex Pacer v1.1.1

## 概要

`v1.1.1` 是一个稳定性版本，重点修复 live quota 刷新和 macOS 菜单栏弹窗定位。

这个版本让 Codex Pacer 在 Codex app-server 仍在初始化、提前退出，或暂时无法返回 live rate limits 时更稳。

## 版本亮点

- live quota 刷新现在会等待 Codex app-server 的 `initialize` 响应，再请求 rate limits
- live quota 主动刷新失败时，会尝试刷新 Codex 历史记录，并读取最新的会话来源额度样本
- 如果没有会话来源额度样本，仍可继续回退到较旧的持久化 live 样本或内存缓存
- 外接显示器场景下，菜单栏弹窗现在会保留在点击菜单栏图标所在的屏幕上
- 错误路径现在能更清楚地区分初始化超时、app-server 提前关闭和 rate-limit 查询失败

## 打包形态

当前稳定公开发布资产：

- 通过 GitHub Releases 分发的、已签名并完成 notarization 的 macOS Apple Silicon DMG

Windows 在此版本中作为测试阶段资产提供：

- 通过 GitHub Releases 分发的、未签名的 Windows NSIS setup EXE

Windows 安装包用于兼容性测试和早期验证。它目前没有 code signing，不会安装 Codex CLI，并且可能触发 Microsoft SmartScreen 的 unknown publisher 提示。

GitHub Releases 仍是 Codex Pacer 的公开发布边界：每个 release 对应一个 Git tag，承载面向用户的发布说明，并托管用户应下载和安装的平台安装包及 checksum。

## 说明

- `v1.1.1` 是当前稳定发布线。
- Intel macOS、universal 构建、Linux 打包产物、Windows code signing、Windows 稳定支持，以及自动更新交付目前都不承诺作为官方发布资产。
- Codex Pacer 保持本地优先，不依赖云端同步服务即可运行。
