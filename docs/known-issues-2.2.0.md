# Known issues in 2.2.0 / 2.2.0 已知问题

The release retains the accepted build 27 runtime behavior; build 28 updates release metadata only. The following edge cases were reproduced during review and are deferred for a later fix. They are not claims that every installation experiences these failures.

本次发布保留已验收 build 27 的运行逻辑，build 28 仅调整发布元数据。以下边界已在审查中复现，按当前发布决定留待后续修复，不代表每台用户电脑都会触发。

| Case | User-visible effect | 情况与影响 |
| --- | --- | --- |
| An older idle metadata reply arrives after a new turn starts | A running task can disappear until fresh lifecycle evidence arrives | 新轮次开始后收到旧空闲元数据，运行任务可能暂时不显示 |
| A native Desktop batch exceeds 512 queued events | Earlier valid events in that batch, including completion, can be lost | 本地批次超过 512 条时，可能丢失其中已排队的完成事件 |
| An SSH subscription request fails after active metadata was observed | Log fallback can remain excluded and miss later state changes | SSH 订阅失败后，日志兜底可能仍被排除，影响后续状态识别 |
| The remote clock is ahead of the Mac clock | A live completion can be rejected as a future event and its reminder missed | 远端时钟偏快时，实时完成可能被当作未来事件，漏掉提醒 |
| A quota reset deadline is postponed by a small correction | The curve can be cleared at the former deadline | 额度重置时间小幅推迟后，曲线可能按原截止时间提前清空 |

Short-lived memory allocation peaks also remain under investigation. Short samples do not establish a long-term resource ceiling. Completion notifications still require the user's notification setting and macOS permission. An abnormal exit may lose up to thirty minutes of local curve updates, without changing service quota.

短时内存分配峰值仍需后续分析，短窗口采样不能证明长期占用上限。系统完成通知仍受用户设置与 macOS 权限控制。异常退出可能丢失最后三十分钟的本地曲线更新，不影响服务端额度。
