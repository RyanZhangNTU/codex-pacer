**Claude 可以请 Codex 帮忙了**。在“设置 → 协作”（Beta）打开“Claude 调用 Codex”，然后直接跟 Claude 说，比如“让 Codex 审查一下这次改动”。Pacer 会按你的设置启动 Codex，每次运行都显示在发起它的 Claude 任务下面，带进度、速度和模型；鼠标移到正在运行的那一行上可以停止。Codex 工作时，折叠栏的任务圆环上会有一道绿光在走。Claude 这一轮结束后，Pacer 会把这些运行从 Codex 的历史里清掉，你的 Codex 历史只留你自己的对话。第一次打开“协作”页时，会有一段简短的引导告诉你怎么用；“帮助 → 协作”里也能再看。

**修复**。Stop 钩子出错但没有阻止结束时，Claude 任务不会再一直显示“输出回复”。Codex 在任务进行中崩溃或被关掉后，任务几分钟内就不再显示为运行中。“全部标为已读”和打开任务时，也会清掉状态未确认的任务。从脚本运行、不带你 Claude 设置的 Claude 任务（比如部分 `claude -p`）结束后，不会再一直显示运行中。任务在等自己的后台工作时，速度显示为 0 t/s，不再停在上一次的数值。

更多信息见[使用说明](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.zh-CN.md)和[完整更新记录](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md)。
