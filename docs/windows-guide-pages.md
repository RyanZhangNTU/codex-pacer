# Windows 欢迎、更新记录与帮助页面

Windows 外壳提供两步欢迎窗口、What's New 窗口，以及 Settings 中的更新历史、Help 和 Support Pacer。界面读取现有中英文目录，更新条目直接来自 `WhatsNew.releases`，支持链接与二维码来自 `ProjectSupport`。窗口不自行维护发布清单，也不请求项目网站或检查 Star 状态。

## 何时显示与记录

`guidePages` 是本地引擎的只读查询，返回页面选择、更新条目、格式化标题、公共链接和单调递增的版本记录。`WhatsNew.pending(current:seen:)` 复用原有筛选规则；Mac 的 UserDefaults 入口转调这个重载，参数与结果不变。独立的 EngineSupport 通过 package 权限复用现有 `WhatsNew.newer` 比较器，算法不变。

- 首次启动或进入新主版本时显示欢迎窗口。打开时记录当前更新版本，关闭时记录 `welcomeGuideVersion`。当前主版本直接使用 `WelcomeGuide.currentMajor`。
- 同一主版本内只展示尚未确认的更新条目，关闭时写 `whatsNewVersion`。没有条目的版本安静记录；运行旧版本不会降低记录。
- demo 和 `--settings` 启动不自动弹出。`--welcome`、`--whats-new` 可强制展示；只有 demo 不记录。非 demo 的 `--settings --welcome` 打开时记录更新版本、关闭时记录欢迎主版本；`--settings --whats-new` 关闭时记录更新版本。预览导出不会额外弹出窗口。
- Settings 的历史包含运行版本之前的全部 `WhatsNew.history(upTo:)`，不受已读版本或定向介绍条件限制，也不写已读版本。

记录使用既有偏好提交与原子保存。保存失败保留此前记录；读取失败的生产偏好不会被欢迎流程覆盖。关闭窗口直接使用引擎已确认的版本结果，无需再发一次查询；若偏好中的版本已变更，则重新确认，避免旧结果覆盖新记录。

记录使用 schema 2，键名为 Mac 的 `welcomeGuideVersion` 和 `whatsNewVersion`，默认值分别是 0 和未设置。读入 schema 1 不改写文件，成功编辑时沿用统一迁移；详细映射见 [Windows 偏好](windows-preferences.md)。两种强制 Settings 组合都用新进程验证关闭后的记录。

## 欢迎窗口

第一步显示收起栏、运行/待处理/结束三种徽章、组件图例和手势说明。All Marks 打开 Help。示例复用 `ActivityBadge`、`CompactQuotaGlyph` 和 `WarningMark`，只使用合成值，不读取任务内容。

第二步提供三家模块卡片。开关提交显式 enabled/disabled，automatic 的检测结果仍有说明；状态及唯一动作随安装、账户、工作区和余额状态变化。动作进入现有提供商设置与连接协调器，继续使用原有登录、工作区选择或粘贴密钥界面。折叠栏入口打开对应设置页，通知和登录启动分别复用 `NotificationSession` 与 OS 注册服务。引导不创造登录启动偏好。

Next、Back 和 Done 可用键盘操作。欢迎窗口关闭后释放内容；重开从第一步开始。

## What's New 与只读页面

更新窗口使用 Mac 的 460 点内容宽度。内容高度取自然高度、640 点、当前屏幕工作区高度减标题栏与 48 点边距三者的最小值。仅更新条目滚动，标题与底部动作固定；DPI 或所在屏幕变化后重新计算。

历史中的 Open at Login 和 App Buttons 控件使用现有服务及偏好，登录启动提示复用现有 Windows 目录中的说明。旧的合并内嵌会话开关与 Mac 一致：两家都开启时选中，一次操作同时写入 Codex 和 Claude 的独立偏好；不修改更新记录。开关保留条目标题作为 UIA 名称、条目说明作为帮助文字。

C 的剩余功能分支只补齐组合控件及其所需的 `ShowEmbeddedClaudeSessions` 偏好属性/配置字段，后两行与 #156 完全相同。没有在此复制 #156 的采集和过滤实现，也没有跟进 develop。单元测试覆盖四种独立初始状态、两种写入值、schema 2 重开、无关偏好保留及保存失败回滚；实际两端会话过滤和 UIA 操作等集成 #156 后统一验证。

Help 提供通用图例与三家模块详情切换，复用徽章、额度环、提醒、DeepSeek 时钟和速率绘图组件。重开欢迎窗口、按语言选择用户手册和 issues 都是显式动作。Help 与 Support 的导航和页内选择均不保存偏好。

Support 提供 Star、feature/bug 表单、捐赠链接、复制项目链接及微信二维码。HTTPS 链接交给默认浏览器，页面不联网；复制只写公共项目地址，显示两秒“已复制”反馈。二维码使用随应用打包的图片，只在点击后打开。Esc 或关闭按钮先关闭弹层，再处理 Settings 的关闭动作。

## 本机验证与边界

自动化覆盖显示条件、定向版本基线、记录不回退、demo/Settings 安静启动、保存失败、真正的新进程读回，以及公共链接的动作分派与非法地址拒绝。

相关展示组覆盖中英文 × 浅深色：两步窗口、显式模块选择与失败回滚、工作区动作、通知与登录启动注入服务、固定页头/页脚、滚动、历史列表、只读页面、二维码、键盘和 UIA。测试只使用合成数据，浏览器和剪贴板边界均注入替身，不读取用户剪贴板，不登录，也不更改 OS 设置。截图位于忽略目录 `output/windows/presentation/pages-*.png`，不提交到仓库。

本机只跑相关测试、完整引擎/共享测试、Release 构建和相关展示组，不重复完整展示矩阵、打包、安装或 CPU 采样。coverage 的四项 previewStatus 只记为 partial。

schema 2 接入基于包含 #155 的 #152 提交 `114c30f`，沿用独立的 Core/EngineSupport 目标和测试分组。本地化条目位于 `windows/EngineSupport/Resources/Localization`，摘要由现有脚本生成。叠加后 947 项完整引擎/共享测试、147 文件独立 Core 编译、偏好与引导定向检查通过，Release 编译警告为 0。四组相关页面展示检查已在前一基线通过；按新的统一集成流程，机械重放后不再重复展示检查。28 张合成 PNG（含原生 DPI 副本）留在本机忽略目录，测试窗口与进程已关闭。

待用户 Windows 实机验收：生产首次启动/升级的窗口顺序、真实提供商登录与工作区流程、实际默认浏览器、OS 通知/登录启动状态、不同屏幕和缩放下的窗口位置，以及手机扫描二维码。Windows 分享面板尚未接入，当前可复制公共链接。

## 待 Mac 实机检查

本次未修改 Mac 窗口或偏好格式。共享 `WhatsNew.pending` 新增纯值入口，原 UserDefaults 入口保持原语义；待 Mac 检查同主版本更新弹窗、定向介绍基线与历史列表。Windows 本机无法完成这项检查。
