# 在 macOS 上安装

## 官方安装路径

**Codex Pacer** 的官方公开安装包，是通过 GitHub Releases 发布的、已签名并完成 notarization 的 **Apple Silicon DMG**。

## 标准安装流程

1. 打开 `codex-pacer` 的最新 GitHub Releases 页面。
2. 下载最新的 Apple Silicon DMG。
3. 打开下载得到的 DMG。
4. 将 **Codex Pacer.app** 拖入 `Applications`。
5. 从 `Applications` 启动 **Codex Pacer**。

## 如果首次启动被 Gatekeeper 拦截

如果 macOS 在第一次启动时阻止应用打开，请先走一次这个回退路径：

1. 打开 `Applications`。
2. 右键 **Codex Pacer.app**。
3. 选择 **Open**。
4. 在弹窗中确认打开。

完成这次人工确认后，后续启动通常就会恢复正常。

## 如果系统仍然阻止打开

请使用系统级放行路径：

1. 打开 **System Settings**。
2. 进入 **Privacy & Security**。
3. 找到关于 **Codex Pacer.app** 被阻止的提示。
4. 点击 **Open Anyway**。
5. 确认后续弹窗，然后再次启动应用。

## 安装后

首次运行建议完成这些步骤：

1. 确认 Codex home 路径（默认 `~/.codex`），或选择自定义 `CODEX_HOME`。
2. 运行首次扫描 / 导入。
3. 等待本地索引建立完成。
4. 查看总览和节奏分析视图。

## 说明

- 当前官方打包版本面向 Apple Silicon macOS。
- GitHub Releases 是官方分发渠道。
- Intel、universal、Windows、Linux，以及自动更新交付目前都不承诺作为公开发布选项。
