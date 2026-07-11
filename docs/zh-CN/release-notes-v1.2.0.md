# Codex Pacer v1.2.0

## 概要

1.2.0 主要改善后台刷新稳定性和资源占用。token 统计与在线额度现在由独立 worker 刷新：本地扫描变慢时不会阻塞在线额度，请求在线额度时也不会延迟 token 导入。

导入器现在只读取增长中 session 文件已经写完整的尾部内容。usage 与 quota 历史改为原位追加或校正，不再反复重建未变化的数据。菜单栏数值直接通过 SQLite 聚合计算，渲染时不必把大量历史记录加载到内存。

## 本次更新

- 新增 GPT-5.6 Sol、Terra 和 Luna 识别及内置 Standard API 等价值 pricing
- macOS 可以自动发现 ChatGPT 桌面应用内置的 Codex CLI
- token 与在线额度分别调度刷新、重试和 freshness 状态
- 前端不再轮询刷新状态，改为接收后端事件
- 增长中的 JSONL session 文件使用持久化解析检查点
- 减少 usage 与 quota 历史的数据库重复写入
- 时间戳迁移改为小批量、可续跑的后台任务
- 修复 fork 和嵌套 fork 的 token 归属，包括单快照和父文件暂时不可用的情况
- 修复旧刷新结果覆盖新结果、listener 启动竞态、退出竞态和重试丢失
- 修复 JSONL 最后一条记录完整但没有换行符时被永久跳过的问题
- 减少 macOS 刷新后的临时内存滞留和 spool 文件体积

## 从 1.1.1 或 1.1.2 升级

直接覆盖安装 1.2.0 即可，不需要先卸载旧版本，也不要删除旧数据库。

Codex Pacer 的应用名称、bundle identifier 和本地数据位置保持不变。首次启动时，应用会在原数据库上增加新字段和索引。已有 conversation、token usage、quota 样本、订阅设置、菜单栏偏好和自定义 Codex 路径都会保留。

旧记录的时间戳会由一个小批量、可续跑的后台任务补齐。这个任务运行期间，token 与在线额度仍会分别刷新。兼容性测试使用 1.1.1 和 1.1.2 的原始 schema 建库并写入用户数据，再升级到 1.2.0，检查保存值和数据库完整性。

## 性能验证

release 构建的本地重启测试中，没有再出现此前启动和每次刷新约 53 MiB 的写入突发。清空开发缓存后启动 75 秒（包含一次后台刷新）共写入 1.68 MiB。四分钟采样平均占用约 1.53% 单核 CPU，读取 0.18 MiB、写入 5.30 MiB；刷新结束后的物理内存回落到约 136–142 MiB。

这些数字来自本次 release 测试机器和数据集，实际结果会随 session 历史和刷新活动变化。

## 发布形式

公开 macOS 资产是通过 GitHub Releases 分发的 Apple Silicon DMG，并附带 SHA-256 checksum。发布前会完成 Developer ID 签名、Apple notarization、staple 和 Gatekeeper 检查。

本版本仍暂缓发布 Windows 安装包。
