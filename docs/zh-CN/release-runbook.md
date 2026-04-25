# 发布 Runbook

## 目的

本文面向维护者，说明如何生成 **Codex Pacer** 的公开发布资产：

- 已签名并完成 notarization 的 Apple Silicon DMG
- 作为测试阶段资产的未签名 Windows NSIS setup EXE
- 通过 GitHub Releases 分发

本地发布入口：

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.1.1
```

```powershell
.\scripts\release\build-windows-release.ps1 1.1.1
```

macOS 发布流程继续使用 `./scripts/release/publish-github-release.sh 1.1.1` 上传 DMG 与 checksum。包含 Windows 的 release 还需要把 Windows setup EXE 与对应 checksum 附加到同一个 GitHub Release。

## macOS 发布要求

- 在 Apple Silicon macOS 上执行标准公开构建流程
- Apple Developer 账号，并在 login keychain 中安装有效的 **Developer ID Application** certificate
- 可用的 Xcode command line tools（`codesign`、`spctl`、`xcrun`）
- `npm`、`cargo` 和仓库依赖可用
- `gh` 已登录目标 GitHub 仓库
- `package.json` 与 `src-tauri/tauri.conf.json` 版本一致
- 发布前工作区保持 clean

构建前需要设置 `APPLE_SIGNING_IDENTITY`，并在 Apple ID notarization 或 App Store Connect API notarization 两条路径中选择一条。不要同时设置两组 notarization 凭据。

## Windows 发布要求

- 在 Windows PowerShell 或 Windows 上的 PowerShell 中执行
- `git`、`node`、`npm`、`cargo` 位于 `PATH`
- 已安装 Windows NSIS 构建所需的 Tauri 前置依赖
- 发布前工作区保持 clean；本地测试构建可显式传入 `-AllowDirty`
- Windows 支持仍处于测试阶段；默认未配置 Windows code signing，除非某次发布单独配置签名，否则 setup EXE 是未签名的

## macOS 构建

```bash
./scripts/release/build-macos-release.sh 1.1.1
```

脚本会校验版本，运行品牌审计、lint、前端构建和 Rust 测试，构建 app/dmg，执行 codesign、notarization 与 stapling，并写入 `<artifact>.dmg.sha256`。

## Windows 构建

```powershell
.\scripts\release\build-windows-release.ps1 1.1.1
```

脚本会校验版本，运行 `npm ci`、lint、前端构建和 Rust 测试，执行 `npm run tauri build -- --ci --bundles nsis -- --locked`，定位生成的 NSIS setup `.exe`，并写入 `<installer>.exe.sha256`。

不要默认把 Windows installer 描述为稳定、已签名、已 notarize 或已被 SmartScreen 信任。只有在某次发布明确配置了 Windows code signing 时，才可以说明签名状态。

## 发布到 GitHub Releases

1. 确认 release notes 文件存在。
2. 确认版本号一致。
3. 确认 `git status --short` 为空。
4. 构建 macOS DMG 与 checksum。
5. 如该版本包含 Windows，构建 Windows setup EXE 与 checksum。
6. 创建并 push `vVERSION` tag。
7. 发布 GitHub Release。
8. 上传已签名并完成 notarization 的 macOS DMG 与 checksum。
9. 如该版本包含 Windows，上传测试阶段的未签名 Windows NSIS setup EXE 与 checksum。
10. 在 release body 中说明 Windows installer 仍处于测试阶段且默认未签名，用户可能看到 SmartScreen unknown publisher 警告。

## macOS 手工验证

1. 打开生成的 DMG。
2. 确认 DMG 中显示 **Codex Pacer.app**。
3. 将 app 拖入 `Applications`。
4. 从 `Applications` 启动应用。
5. 确认 Gatekeeper 没有报告 app broken 或 unsigned。
6. 从默认 `~/.codex` 或已知可用的样本环境运行导入。
7. 确认总览页面加载，本地索引完成。
8. 确认 menu bar 弹窗仍在 macOS menu bar 下方打开。
9. 确认 macOS 专属 Dock 设置只作为 macOS 设置呈现。

## Windows 手工验证

1. 确认生成的 setup `.exe` 与 `.sha256` 文件存在。
2. 使用 `Get-FileHash` 校验 checksum。
3. 在 Windows 测试机上运行 setup `.exe`。
4. 如果 SmartScreen 提示 unknown publisher，确认这符合未签名安装包预期。
5. 从 Start menu 启动 **Codex Pacer**。
6. 确认应用读取默认 `~\.codex` 或自定义 `CODEX_HOME`。
7. 从已知可用的本地 Codex 环境运行导入。
8. 确认总览页面加载，本地索引完成。
9. 确认托盘弹窗在底部任务栏上方打开，并且显示可选模块后仍向上扩展。
10. 刷新 live quota 数据，确认不会弹出黑色命令行窗口。

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath "C:\path\to\Codex Pacer_1.1.1_x64-setup.exe"
```

## 相关文档

- [打包与发布](./packaging-and-release.md)
- [在 macOS 上安装](./installing-on-macos.md)
- [在 Windows 上安装](./installing-on-windows.md)
