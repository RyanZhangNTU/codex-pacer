# 打包与发布

## 官方发布范围

**Codex Pacer** 的稳定公开版本通过 **GitHub Releases** 分发。

当前稳定公开打包资产为：

- 已签名并完成 Apple notarization 的 **macOS Apple Silicon DMG**

`v1.2.0` 暂缓发布 Windows 安装包。Windows 兼容性仍处于测试阶段，后续发布 Windows 安装包前应先在源码或 Windows 构建机上验证：

- 未签名的 **Windows NSIS setup EXE**，仅用于本地兼容性测试和早期验证

以下内容**目前不承诺**作为官方发布资产提供：

- Intel macOS 构建
- universal macOS 构建
- Linux 打包产物
- Windows 稳定支持
- Windows code signing
- 自动更新交付

所有公开发布文案都应与这个范围保持一致，避免超出当前稳定工作流承诺 Windows 稳定性、签名、notarization 或自动更新能力。

## 稳定版发布流程

当前面向公开发布的目标流程是：

1. 确认公开品牌文案和文档已经准备完成。
2. 构建并完成 macOS Apple Silicon DMG 的 notarization 与 staple。
3. 如果包含 Windows 相关改动，单独执行 Windows 兼容性检查；`v1.2.0` 不发布 Windows 安装包。
4. 通过 GitHub Releases 发布这些安装资产。
5. 附上对应版本的发布说明。

## 本地发布准备

公开发布准备流程以这些脚本为入口：

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.2.0
./scripts/release/publish-github-release.sh 1.2.0
```

```powershell
.\scripts\release\build-windows-release.ps1 1.2.0
```

这些脚本是当前稳定公开发布准备的本地入口。macOS 构建脚本会校验版本，运行品牌审计、lint、前端构建和 Rust 测试，生成已签名的 DMG，提交 Apple notarization，执行 staple，并在旁边写入 checksum。Windows 构建脚本在 Windows 上运行，会校验版本，运行 lint、前端构建和 Rust 测试，生成 NSIS setup EXE，并在旁边写入 checksum，供本地兼容性验证使用。Windows 安装包默认未签名且仍处于测试阶段，除非单独配置了 Windows code signing 和稳定 Windows 发布策略。发布脚本会继续校验 tag，并把 macOS DMG 与 checksum 上传到 GitHub Releases；`v1.2.0` 不上传 Windows EXE 资产。

## 平台隔离规则

macOS 和 Windows 差异应放在明确的平台边界后面，这样 `main`/`develop` 可以维持一条发布线，避免平台之间互相漂移：

- 原生层只属于单一系统的行为使用 Rust `#[cfg(...)]` 隔离
- 前端展示系统专属设置前先做能力判断，例如 macOS Dock 控制项
- 发布打包保持在平台专属脚本中（`build-macos-release.sh` 与 `build-windows-release.ps1`）
- 合并平台相关改动前，分别验证 macOS menu bar 行为和 Windows taskbar 行为

Windows 专属的托盘弹窗定位、隐藏子进程命令行窗口、未签名安装包说明，不应改变 macOS 的 Dock、menu bar、签名或 notarization 行为。

## 发布前建议验证

- 确认 `package.json` 与 `src-tauri/tauri.conf.json` 的版本一致
- 确认发布说明与文档都指向稳定公开发布线
- 发布前先运行品牌 / 文档审计
- 确认生成的 DMG 能在 Apple Silicon macOS 上正常打开
- 确认已签名的应用可以从 `Applications` 正常启动
- 确认 macOS menu bar 弹窗仍在 menu bar 下方打开，且 macOS 专属 Dock 设置不会出现在非 macOS
- 如果执行本地 Windows 验证，确认生成的 Windows setup EXE 可以在 Windows 上安装
- 如果执行本地 Windows 验证，确认 Windows 托盘弹窗在底部任务栏上方向上展开，显示可选模块后仍向上扩展，并且刷新 live quota 时不会弹出命令行窗口
- 如果执行本地 Windows 验证，确认 Windows 安装包 checksum，并注明除非另行配置签名，否则该安装包仍处于测试阶段且未签名

## 发布建议

- 为稳定版本创建 Git tag
- 基于该 tag 创建 GitHub Release
- 上传已签名、完成 notarization 并已 staple 的 Apple Silicon DMG
- `v1.2.0` 不上传 Windows NSIS setup EXE
- 附上该版本对应的发布说明
- 发布后再次验证下载与安装流程

在当前工作流里，GitHub Releases 不只是文件托管位置。它是公开发布边界：一个经过确认的 Git tag、面向用户的发布说明、平台安装包和 checksum 在这里汇合。用户应安装对应 tag release 下适合自己平台的资产；维护者则通过 tag 和 checksum 保持发布可追溯、可审计。

## 面向用户应统一传达的内容

面向外部文档和公告时，请保持以下表述一致：

- 官方分发渠道：GitHub Releases
- 稳定发布资产：已签名并完成 Apple notarization 的 macOS Apple Silicon DMG
- Windows 安装包：`v1.2.0` 暂缓发布
- 当前稳定版本线：`v1.2.0`

## 相关文档

- [快速开始](./getting-started.md)
- [在 macOS 上安装](./installing-on-macos.md)
- [在 Windows 上安装](./installing-on-windows.md)
- [发布 Runbook](./release-runbook.md)
- [v1.2.0 发布说明](./release-notes-v1.2.0.md)
