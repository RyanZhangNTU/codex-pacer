Codex Pacer 4.0.0 加入 DeepSeek Harness，用余额代替额度窗口。

- **DeepSeek Harness 任务：** 本机的 Harness 会话与 Codex、Claude Code 任务排在同一个列表里，显示阶段、速度、本轮用时、模型与推理强度、等你处理的审批和提问，并有完成卡片和通知。点击会把 Harness 切到前台。
- **回合花费：** 每个 DeepSeek 任务显示这一回合的估算花费，例如 **≈¥0.42**，按 token 数和 DeepSeek 公布的单价计算，高峰时段按两倍计。以开放平台账单为准。
- **日环：** DeepSeek 的环是今天的 24 小时钟面，显示每个小时花了多少、单价翻倍的高峰时段，中间是余额。只开启 DeepSeek 时，面板还会显示余额够用几天，以及按价格拆分的近 7 天花费。
- **按你的方式连接余额：** 在 Pacer 自己的窗口里登录一次 DeepSeek 开放平台，或粘贴一个 API Key，跟随 Harness 的登录方式。Pacer 不读取 Harness 自己的登录信息。
- **余额偏低提醒：** 余额低于开放平台的提醒线，或 3 天内会用完时，折叠栏出现空心 **¥** 警告，也可以选择发系统通知。可选的 **×2** 标出高峰价时段。

### 安装

- **已有安装：** 通过“检查更新”原地升级，保留现有设置；入门引导会打开一次，介绍 DeepSeek 模块。
- **手动安装：** 先退出 Codex Pacer，再用新版替换“应用程序”中的副本，然后重新打开。
- 需要 macOS 14 及以上。追踪 DeepSeek 需要本机安装 DeepSeek Harness。

详见[使用指南](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
