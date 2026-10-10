Codex Pacer 3.0.0 build 48 是支持 Codex 与 Claude Code 的开发候选版。展开后上方统一展示任务，以颜色区分服务；并排双圆环同时显示两个模块的剩余额度与时间，额度标题旁的微型 5h / 7d 标签切换周期。圆环布局下，单模块同时显示两个周期，确认账户仅有每周限制时使用 PRO 占位。仅启用 Codex，且主账户已返回额度限制但没有 5h 窗口时，恢复原来的额度条形展示，保留全部实际窗口，包括非标准或未知时长的限制。历史曲线与完整额度详情仍在设置中。圆环使用更细的线条，环内只突出额度数字与简短倒计时，正常来源和更新时间移到悬停提示及设置，过期和错误状态仍明确显示。折叠时以一个动态活动徽标合并状态与任务数，并显示可用 TPS，额度百分比仅用服务颜色区分。成功打开的完成卡在正常重启后仍保持已读。Claude 任务可根据当前 Claude Code 遥测显示请求速度与首输出时间；Pacer 的 hook 启动更快，不再拖慢流式输出。界面采用统一的状态图标、两行式任务行（速度与首输出指标右对齐）和侧边栏式设置窗口。

设置可独立启用或关闭模块。自动模式检测已安装的应用与 CLI，手动选择会保留。Claude 支持本机来源与配置的 SSH 别名；经 Desktop 元数据确认的 SSH/WSL 日志镜像会从默认本机来源排除，SSH 状态通过有界传输即时更新。可选监测配置以追加方式加入 hooks 和数值遥测，保留已有设置。匹配的 OTLP 请求证据提供准确的请求时间；确认停止后的 transcript 窗口可提供吞吐率估算。首输出时间需要有明确轮次归属的流式显示回调或服务报告的 TTFT；Desktop SDK / `-p` 仅发送最终消息时不能据此推算。Claude 通过已验证 Desktop 映射或真实 Terminal resume 会话打开；只有成功打开已验证 Desktop 目标才清除对应完成卡。

Codex Remote Control 通过已连接的 Desktop owner stream 加入统一任务列表，在 Codex 数据来源中有独立开关。Codex 桌面端必须保持开启、连接远程主机，并由 stream owner 加载对应会话；Pacer 不为此新增独立远端发现或日志兜底。缓存计数不会建立新测量，也不能补出未观测到的首输出时间。继承的请求中途接入 TPS 兜底仍是近似值，可能出现偏高估算。参见[上游 PR #77](https://github.com/RyanZhangNTU/codex-pacer/pull/77)与[来源及计量边界](development.md#codex-accounting-and-lifecycle)。

Claude 额度优先使用同账户新鲜 status-line 样本或 Pacer 独立 WebKit 会话。“登录 Claude”打开专用网页窗口，由用户完成登录和验证；多组织需要明确选择。生产环境不会读取其他应用的 Keychain 或 Safe Storage，cookie 仅由 WebKit 管理。自有 OAuth 缓存、环境变量与文件来源仅作安静的兼容回退。网页会话过期后需重新登录，缺少重置日期及服务未提供的 Credit / banked reset 详情保持不可用。

适用于 macOS 14 及以上，通用构建支持 Apple Silicon 和 Intel。本说明不表示已经公开发布、安装或完成手动验收。

手动安装候选版时先退出旧应用，再将 DMG 中的 Codex Pacer 拖入 Applications。未签名候选版如被 macOS 阻止，请在“系统设置 → 隐私与安全性 → 安全性”选择“仍要打开”，再重新打开安装包或应用。打包与发布遵循[发布流程](releasing.md)。
