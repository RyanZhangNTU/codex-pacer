# Codex Pacer v1.1.2

## 概要

`v1.1.2` 修复 Codex 状态重置、会话文件重放或进程重启后可能出现的 token 重复计数问题。

相比 `v1.1.1`，这个版本也包含已经推进到 `main` 的数据库查询重构、pricing 刷新、自定义时间范围控制，以及 Windows 兼容性基础工作。

## 版本亮点

- token 导入现在把每个 session 的累计用量快照视为单调高水位
- 重放或回退的 token 总量不会再把当前累计总量重复计入
- 组成项计数器回退时会被安全截断，同时保留合法的 total token 增长
- 已经出现异常的历史 token 使用行会在下一次扫描时执行一次修复
- 无法修复的源文件会被记录为待重试文件，避免反复强制重导全部 session
- 数据库查询 SQL 拆分为版本化文件，同步设置、订阅数据和 rate-limit 样本持久化也拆成更小的模块
- 自定义 dashboard 日期范围选择，便于查看指定本地使用周期
- API 等价 pricing 使用刷新后的 Standard 短上下文价格，并稳定选择对应 pricing 行
- dashboard 分布控制的按钮行为和换行表现更清晰
- Windows 兼容性脚本和文档已提供用于源码验证，但本版本仍暂缓发布 Windows 安装包

## 打包形态

当前稳定公开发布资产：

- 通过 GitHub Releases 分发的、已签名的 macOS Apple Silicon DMG

本版本暂缓发布 Windows 安装包。Windows 兼容性仍应通过源码或 Windows 构建机检查，但 `v1.1.2` 不附加 Windows setup EXE。

GitHub Releases 仍是 Codex Pacer 的公开发布边界：每个 release 对应一个 Git tag，承载面向用户的发布说明，并托管用户应下载和安装的平台安装包及 checksum。

## 说明

- `v1.1.2` 是当前稳定发布线。
- Intel macOS、universal 构建、Linux 打包产物、macOS notarization、Windows code signing、Windows 稳定支持、Windows 安装包发布，以及自动更新交付目前都不承诺作为官方发布资产。
- Codex Pacer 保持本地优先，不依赖云端同步服务即可运行。
