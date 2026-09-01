# 在 Windows 上安装

## Windows 测试阶段状态

`v1.2.2` 暂缓发布 Windows 安装包。当前稳定版 GitHub Release 不附加 Windows setup `.exe`。

Windows 支持目前仍处于测试阶段。后续某个版本如果包含 Windows 安装包，除非该版本单独配置了 Windows code signing，否则安装包默认未签名，Windows SmartScreen 可能会提示发布者未知。

## 本地验证结果

`v1.2.2` 源码已在 Windows x64 build 26200、WebView2 151.0.4129.107 环境完成本地验证：

- 前端 lint、构建和测试全部通过
- 416 个启用的 Rust 测试全部通过，另有 2 个测试按设计保持 ignored
- 发布脚本成功生成 NSIS 安装程序和 SHA-256 校验文件
- 安装程序使用默认的当前用户目录完成安装，正确登记卸载程序并创建桌面快捷方式
- 安装后的应用可以正常启动、导入现有 Codex 本地历史，并显示累计用量和对话数据

这份已验证的安装程序仍未签名，也不属于公开的 `v1.2.2` GitHub Release 资产。

## 源码验证流程

1. 从 GitHub 仓库检出对应 release tag。
2. 安装 Windows Tauri 前置依赖。
3. 运行 `npm ci`。
4. 运行 `npm run lint`、`npm run build` 和 `cargo test --manifest-path src-tauri/Cargo.toml --locked`。
5. 仅用于本地安装包验证时，在 Windows 上运行 `.\scripts\release\build-windows-release.ps1 -Version 1.2.2`。

## 安装后

测试本地 Windows 构建时，首次运行建议完成这些步骤：

1. 确认 Codex home 路径（Windows 默认 `~\.codex`），或选择自定义 `CODEX_HOME`。
2. 确认该路径下已经有本地 Codex CLI 会话与 rate-limit 数据。
3. 运行首次扫描 / 导入。
4. 等待本地索引建立完成。
5. 查看总览和节奏分析视图。

## 说明

- GitHub Releases 是官方分发渠道。
- `v1.2.2` 只发布 macOS Apple Silicon DMG 资产。
- 任何本地构建的 Windows setup `.exe` 仍是测试阶段的 NSIS 安装包。
- Windows 安装包不会安装 Codex CLI，也不会创建 Codex 使用历史。
- Windows 稳定支持、Windows code signing 和自动更新交付目前都不承诺。
