# Codex Pacer v1.1.0

## 概要

`v1.1.0` 改进了 macOS 菜单栏体验，并重新整理设置界面，让日常查看额度和价值更轻量。

这个版本重点让菜单栏弹窗更紧凑、更直观，并且会跟随用户在设置里选择显示的内容自动调整高度。

## 版本亮点

- 新增 macOS 选项：在菜单栏保留 Codex Pacer 的同时隐藏 Dock 图标
- 将设置界面重排为更清晰的单列结构，并把二元选项改为开关控件
- 更新菜单栏 logo、API 价值、弹窗、reset 时间条、自动扫描、刷新间隔和 fast-mode 行为的默认设置
- 将语言选项文案明确为 `简体中文 · Chinese` 与 `English · English`
- 将弹窗里的 7 天节奏文字改为可视化折线图，包含参考线、实际使用线、当前位置、速度标签和 7 天 API 价值标签
- 让弹窗里的额度圆环与折线图融入背景，不再使用单独卡片承载
- 弹窗高度会根据设置中实际显示的内容动态调整，仅在内容超过最大高度时滚动

## 打包形态

此版本的打包资产：

- 通过 GitHub Releases 分发的、已签名并完成 notarization 的 macOS Apple Silicon DMG

GitHub Releases 仍是 Codex Pacer 的公开发布边界：每个 release 对应一个 Git tag，承载面向用户的发布说明，并托管用户应下载和安装的打包资产及 checksum。

## 说明

- `v1.1.0` 是上一条稳定发布线。当前稳定版本请查看最新发布说明。
- Intel macOS、universal 构建、Linux 打包产物、Windows code signing，以及自动更新交付目前都不承诺作为官方发布资产。
- 当前 Windows 安装包支持以最新安装与发布文档为准。
- Codex Pacer 保持本地优先，不依赖云端同步服务即可运行。
