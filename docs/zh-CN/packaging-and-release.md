# 打包与发布

## 官方发布范围

**Codex Pacer** 的稳定公开版本通过 **GitHub Releases** 分发。

当前官方打包资产为：

- 已签名并完成 notarization 的 **macOS Apple Silicon DMG**

以下内容**目前不承诺**作为官方发布资产提供：

- Intel macOS 构建
- universal macOS 构建
- Windows 安装包
- Linux 打包产物
- 自动更新交付

所有公开发布文案都应与这个范围保持一致，避免超出当前稳定工作流的支持边界。

## 稳定版发布流程

当前面向公开发布的目标流程是：

1. 确认公开品牌文案和文档已经准备完成。
2. 构建 macOS Apple Silicon 的签名发布产物。
3. 通过 GitHub Releases 发布 DMG。
4. 附上对应版本的发布说明。

## 本地发布准备

公开发布准备流程以这些脚本为入口：

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.1.1
./scripts/release/publish-github-release.sh 1.1.1
```

这些脚本是当前稳定公开发布准备的本地入口。构建脚本会校验版本，运行品牌审计、lint、前端构建和 Rust 测试，生成已签名并完成 notarization 的 DMG，并在旁边写入 checksum。发布脚本会继续校验 tag，并把 DMG 与 checksum 上传到 GitHub Releases。

## 发布前建议验证

- 确认 `package.json` 与 `src-tauri/tauri.conf.json` 的版本一致
- 确认发布说明与文档都指向稳定公开发布线
- 发布前先运行品牌 / 文档审计
- 确认生成的 DMG 能在 Apple Silicon macOS 上正常打开
- 确认已签名的应用可以从 `Applications` 正常启动

## 发布建议

- 为稳定版本创建 Git tag
- 基于该 tag 创建 GitHub Release
- 上传已签名并完成 notarization 的 Apple Silicon DMG
- 附上该版本对应的发布说明
- 发布后再次验证下载与安装流程

在当前工作流里，GitHub Releases 不只是文件托管位置。它是公开发布边界：一个经过确认的 Git tag、面向用户的发布说明、签名 DMG 和 checksum 在这里汇合。用户应把对应 tag release 下的 DMG 视为官方安装包；维护者则通过 tag 和 checksum 保持发布可追溯、可审计。

## 面向用户应统一传达的内容

面向外部文档和公告时，请保持以下表述一致：

- 官方分发渠道：GitHub Releases
- 官方发布资产：已签名并完成 notarization 的 macOS Apple Silicon DMG
- 当前稳定版本线：`v1.1.1`

## 相关文档

- [快速开始](./getting-started.md)
- [在 macOS 上安装](./installing-on-macos.md)
- [v1.1.1 发布说明](./release-notes-v1.1.1.md)
