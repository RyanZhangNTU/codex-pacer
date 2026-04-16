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

后续的公开发布准备流程应以这两个脚本为入口：

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.0.0
```

这两个脚本代表未来稳定发布工作流的入口。如果你当前本地仓库里还没有这些脚本，应把它们理解为计划中的接口，而不是已经完成的自动化承诺。

在这些辅助脚本落地之前，请先使用当前可执行的回退流程：

```bash
npm install
npm run lint
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

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

## 面向用户应统一传达的内容

面向外部文档和公告时，请保持以下表述一致：

- 官方分发渠道：GitHub Releases
- 官方发布资产：已签名并完成 notarization 的 macOS Apple Silicon DMG
- 当前稳定版本线：`v1.0.0`

## 相关文档

- [快速开始](./getting-started.md)
- [在 macOS 上安装](./installing-on-macos.md)
- [v1.0.0 发布说明](./release-notes-v1.0.0.md)
