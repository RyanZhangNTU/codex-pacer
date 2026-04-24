# Codex Pacer v1.0.1

## 概要

`v1.0.1` 为 GPT-5.5 使用量统计更新了 Codex Pacer 的计价逻辑，并补充当前签名 DMG 发布流程说明。

这是一个聚焦维护版本，主要面向需要在 Codex 使用 GPT-5.5 后继续获得准确 API 等价价值估算的用户。

## 版本亮点

- 新增 GPT-5.5 官方价格，用于 API 等价价值估算
- 新增 GPT-5.5 Codex fast mode 成本处理，使用官方说明中的 `2.5x` 倍率
- 保持 GPT-5.4 fast mode 的 `2x` 计价逻辑
- 会话导入、重新计算、turn 时间线和 token 组成成本拆分统一使用按模型区分的 fast-mode 逻辑
- 更新新 GPT-5.4 / GPT-5.5 对话的默认 fast-mode 设置文案
- 更新打包文档，说明 GitHub Releases 为什么是版本化签名 DMG 安装包的正式分发入口

## 打包形态

当前官方公开发布资产：

- 通过 GitHub Releases 分发的、已签名并完成 notarization 的 macOS Apple Silicon DMG

GitHub Releases 是本项目的公开发布边界：每个 release 对应一个 Git tag，承载面向用户的发布说明，并托管用户应下载和安装的签名 DMG 及 checksum。

## 说明

- `v1.0.1` 是当前稳定发布线。
- Intel macOS、universal 构建、Windows、Linux，以及自动更新交付目前都不承诺作为官方发布资产。
- Codex Pacer 保持本地优先，不依赖云端同步服务即可运行。
