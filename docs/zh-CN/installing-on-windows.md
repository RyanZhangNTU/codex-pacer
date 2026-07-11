# 在 Windows 上安装

## Windows 测试阶段状态

`v1.2.0` 暂缓发布 Windows 安装包。当前稳定版 GitHub Release 不附加 Windows setup `.exe`。

Windows 支持目前仍处于测试阶段。后续某个版本如果包含 Windows 安装包，除非该版本单独配置了 Windows code signing，否则安装包默认未签名，Windows SmartScreen 可能会提示发布者未知。

## 源码验证流程

1. 从 GitHub 仓库检出对应 release tag。
2. 安装 Windows Tauri 前置依赖。
3. 运行 `npm ci`。
4. 运行 `npm run lint`、`npm run build` 和 `cargo test --manifest-path src-tauri/Cargo.toml --locked`。
5. 仅用于本地安装包验证时，在 Windows 上运行 `.\scripts\release\build-windows-release.ps1 1.2.0`。

## 安装后

测试本地 Windows 构建时，首次运行建议完成这些步骤：

1. 确认 Codex home 路径（Windows 默认 `~\.codex`），或选择自定义 `CODEX_HOME`。
2. 确认该路径下已经有本地 Codex CLI 会话与 rate-limit 数据。
3. 运行首次扫描 / 导入。
4. 等待本地索引建立完成。
5. 查看总览和节奏分析视图。

## 说明

- GitHub Releases 是官方分发渠道。
- `v1.2.0` 只发布 macOS Apple Silicon DMG 资产。
- 任何本地构建的 Windows setup `.exe` 仍是测试阶段的 NSIS 安装包。
- Windows 安装包不会安装 Codex CLI，也不会创建 Codex 使用历史。
- Windows 稳定支持、Windows code signing 和自动更新交付目前都不承诺。
