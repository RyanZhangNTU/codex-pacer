# 快速开始

## Codex Pacer 是做什么的

**Codex Pacer** 是一个本地优先的桌面应用，用来把 Codex 使用情况转化为更容易行动的视角：额度节奏、API 等价价值，以及会话级别的使用分析。

它主要帮助你回答这些实际问题：

1. 我当前的额度窗口使用节奏是否合理，能不能在 reset 前把窗口用好？
2. 这份订阅目前已经换回了多少 API 等价价值？
3. 哪些会话、模型或 subagent 消耗最多？

## 环境要求

- 稳定打包版本面向 Apple Silicon macOS；Windows 安装包目前作为测试阶段资产提供
- 本地 Codex 数据位于 `~/.codex` 或自定义 `CODEX_HOME`

如果你要从源码开发，还需要：

- Node.js 20+
- Rust toolchain
- 当前平台所需的 Tauri 构建依赖

## 安装稳定版应用

官方公开下载方式均通过 GitHub Releases 提供：

- 已签名并完成 notarization 的 **macOS Apple Silicon DMG**
- 未签名的 **Windows NSIS setup EXE**，作为测试阶段资产

请先阅读：

- [在 macOS 上安装](./installing-on-macos.md)
- [在 Windows 上安装](./installing-on-windows.md)

## 克隆仓库并安装依赖

等公开 GitHub 仓库创建后，请直接从仓库页面复制 HTTPS 或 SSH 的克隆地址，再在本地执行克隆并安装依赖，避免文档中留下会失败的占位命令。

## 开发模式运行

### 完整桌面应用

```bash
npm run tauri dev
```

如果你需要真实的 Tauri 行为、本地数据库访问和 macOS 菜单栏体验，请使用这个模式。

### 浏览器预览

```bash
npm run dev
```

如果你只是调试 UI，可以使用这个模式。Tauri 专属能力在浏览器预览里会受限或被 mock。

## App 内首次设置

1. 在 macOS 从 `Applications` 启动 **Codex Pacer**，在 Windows 从 Start menu 启动。
2. 打开 **Settings**。
3. 确认 Codex home 路径（默认 `~/.codex`），或改成自定义 `CODEX_HOME`。
4. 运行首次扫描 / 导入。
5. 等待本地索引建立完成。
6. 查看总览、节奏指标和会话下钻结果。

## 核心概念

### API 等价价值

Codex Pacer 会根据 token 使用量和价格映射，估算“如果按 API 计费，这些使用量值多少钱”。它是对比信号，不是官方账单。

### 订阅回报

`API 等价价值 / 订阅成本`

这个指标帮助你判断当前订阅是没有用满、基本匹配，还是已经明显回本。

### 滚动额度窗口

当 live quota 数据可用时，Codex Pacer 会跟踪 `5小时`、`7天` 等滚动窗口，让你把剩余额度和剩余时间放在一起看。

### 建议节奏

Codex Pacer 会比较剩余额度与剩余时间，帮助你判断当前是消耗过快、节奏健康，还是在 reset 前保留了过多未使用容量。

## 你可以查看什么

- 当前时间窗口内的总览分析
- live window 可用时的额度节奏
- 对话、root session、subagent 级别拆解
- 模型构成与 token 组成
- macOS 菜单栏中的快速快照视图

## 从源码构建与基本校验

```bash
npm run lint
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

## 下一步文档

- [在 macOS 上安装](./installing-on-macos.md)
- [在 Windows 上安装](./installing-on-windows.md)
- [打包与发布](./packaging-and-release.md)
- [v1.1.1 发布说明](./release-notes-v1.1.1.md)
