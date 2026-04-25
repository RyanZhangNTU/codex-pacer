# 在 Windows 上安装

## Windows 安装路径

**Codex Pacer** 的 Windows 公开安装包，是通过 GitHub Releases 发布的 NSIS setup `.exe`。

Windows 安装包当前默认未签名，除非某次发布单独配置了 Windows code signing。Windows SmartScreen 可能会提示发布者未知。

## 标准安装流程

1. 打开 `codex-pacer` 的最新 GitHub Releases 页面。
2. 下载最新的 Windows NSIS setup `.exe`。
3. 运行下载得到的 setup 文件。
4. 如果 SmartScreen 提示发布者未知，请先确认文件来自项目 GitHub Release，再继续安装。
5. 安装后从 Start menu 启动 **Codex Pacer**。

## 安装后

首次运行建议完成这些步骤：

1. 确认 Codex home 路径（Windows 默认 `~\.codex`），或选择自定义 `CODEX_HOME`。
2. 确认该路径下已经有本地 Codex CLI 会话与 rate-limit 数据。
3. 运行首次扫描 / 导入。
4. 等待本地索引建立完成。
5. 查看总览和节奏分析视图。

## 说明

- GitHub Releases 是官方分发渠道。
- Windows setup `.exe` 是 NSIS 安装包。
- 安装包不会安装 Codex CLI，也不会创建 Codex 使用历史。
- Windows code signing 和自动更新交付目前都不承诺。
