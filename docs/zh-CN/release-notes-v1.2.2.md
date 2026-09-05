# Codex Pacer v1.2.2

## 概要

1.2.2 修复了大型 Codex 历史记录下反复大量读取磁盘的问题。常规的一分钟自动刷新现在只检查 active、发生变化或等待修复的少量文件，不再遍历全部 archive。Dashboard 与额度查询只读取所选窗口，对话历史也改为分页加载。

这个版本同时适配不再提供 5 小时额度的 Codex 账号。程序默认打开 7 天视图，保留 7 天额度，并用同一个 7 天窗口计算菜单栏的 API 等价值。

## 本次更新

- 默认打开当前 7 天窗口
- 没有 5 小时额度时仍正常显示 7 天额度
- 菜单栏 API 等价值自动改用当前 7 天窗口
- 常规扫描使用增量发现和持久化解析检查点
- archived session 改由受限的维护任务校正，不再每次自动刷新都遍历
- 额度趋势只查询精确的归一化窗口，并在每个图表时间段保留一个点
- overview 数据使用缓存，并在 usage、quota 或订阅设置变化时立即失效
- 对话列表使用 SQL 分页，选中对话后才读取 turn 详情
- 移除切换视图和搜索条件时的重复 dashboard 读取
- 没有 import state 的 pending repair 文件也会被直接重试

## 资源验证

测试时把自动扫描间隔设为一分钟。连续 30 分钟采样中，Codex Pacer 共读取 34.41 MiB，平均占用约 0.14% 单核 CPU，trace 中没有再次出现周期性全量 archive 扫描。另一次对打包应用进行的 130 秒 smoke test 在启动后记录到 4 KiB 读取。

这些数字来自发布测试机器及其本地 Codex 历史。实际结果会受 active session、数据库大小和定期校正任务影响。

## 从 1.2.0 升级

直接覆盖安装 1.2.2 即可。不要卸载旧版本，也不要删除本地数据库。

应用名称、bundle identifier 和数据位置保持不变。已有 conversation、token usage、quota 样本、订阅设置、菜单栏偏好和自定义 Codex 路径都会保留。

## 发布形式

公开 macOS 资产是通过 GitHub Releases 分发的 Apple Silicon DMG，并附带 SHA-256 checksum。发布前会完成 Developer ID 签名、Apple notarization、staple 和 Gatekeeper 检查。

本版本仍暂缓发布 Windows 安装包。
