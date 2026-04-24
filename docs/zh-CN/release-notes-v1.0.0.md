# Codex Pacer v1.0.0

## 概要

`v1.0.0` 是 **Codex Pacer** 的首个稳定公开版本。

这个版本正式确立了产品的公开发布线：一个本地优先的桌面应用，用来把 Codex 使用情况转化为额度节奏、API 等价价值，以及会话级别的使用分析。

## 版本亮点

- Codex Pacer 的首个稳定公开版本
- 从 `~/.codex` 或自定义 `CODEX_HOME` 导入本地 Codex 使用数据
- 使用本地 SQLite 建立索引，支持总览分析和下钻查看
- API 等价价值估算与订阅回报追踪
- 在可用时支持 `5小时`、`7天` 等滚动额度窗口节奏分析
- 按 root session、subagent、模型和 token 指标拆解会话级使用情况
- 提供 macOS 菜单栏快速额度快照体验
- 补齐稳定版发布所需的中英文安装、打包和发布说明文档

## 打包形态

当前官方公开发布资产：

- 通过 GitHub Releases 分发的、已签名并完成 notarization 的 macOS Apple Silicon DMG

## 说明

- `v1.0.0` 是首个稳定发布线。当前稳定版本请查看最新发布说明。
- Intel macOS、universal 构建、Windows、Linux，以及自动更新交付目前都不承诺作为官方发布资产。
- Codex Pacer 保持本地优先，不依赖云端同步服务即可运行。
