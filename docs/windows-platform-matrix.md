# Windows 平台矩阵

支持目标为 Windows 10 build 19041 及以上、Windows 11，提供 x64 和 ARM64 构建。Glass 仍要求 build 22621 及以上；较旧系统使用 Black，保留用户的 Glass 偏好。支持目标与实际验证分开记录，不能把一台 Windows 11 x64 的结果推广到 ARM64 或 Windows 10。

| 范围 | 构建覆盖 | 当前实际验证 |
| --- | --- | --- |
| Windows 11 x64 | 引擎、WPF、Swift Bridge、Composition DLL、维护程序和安装器的既有构建链 | 本机 Debug 零警告编译、定向引擎/桌面单元测试；本轮未跑 Release、打包、展示或安装验收。 |
| Windows 11 ARM64 | 新增原生 `windows-11-arm` CI 作业，构建并打包应用和安装器，上传与 x64 对称的产物 | 构建路径与 CI 定义已覆盖，CI 留到集成阶段执行；实机运行待验证。本机只检查架构选择、MSBuild 求值和 PE 校验逻辑，未生成或运行 ARM64 产品。 |
| Windows 10 19041+ | 两种架构共用最低版本声明、入口检查和能力降级；构建路径已覆盖 | 通过注入版本/API 失败的定向测试与代码审查；真实 Windows 10 编译环境、启动、通知、显示器和安装实机待验证。 |

## 架构接口和依赖

MSBuild 统一使用 `PacerArchitecture=x64|arm64`，脚本使用 `-Architecture x64|arm64`，进程内向下传递 `PACER_ARCHITECTURE`。默认 x64，原来的输出位置和命令仍可用。ARM64 桌面和 Composition 中间产物单独存放，Swift triple、缓存、引擎收据、.NET RID、维护程序、依赖选择、ZIP 元数据和安装器名称都使用同一个选择值。

ARM64 CI 采用 [GitHub 的原生 Windows ARM64 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)，避免在 x64 主机上混用宿主 Swift runtime。Swift 安装器分别固定官方 x64/ARM64 下载的 SHA-256，并保留 Apple 发布者签名检查；本机没有安装、解包或修改工具链。Swift 官方说明见 [Windows 工具链安装](https://www.swift.org/install/windows/manual/)。开发者的 x64 主机可以求值 ARM64 MSBuild 配置，但完整 ARM64 包由原生 ARM64 CI 构建，不声称本机交叉打包已通过。

Claude 的嵌入式 Python 也按架构选择官方固定版本、散列和签名文件清单；运行库缓存以版本和散列隔离。ARM64 pin 来自 [Python 官方 ARM64 归档](https://www.python.org/ftp/python/3.14.10/python-3.14.10-embed-arm64.zip)，没有执行归档中的程序。Swift 安装辅助程序编译时选择对应 pin，x64 的既有 pin 和断言不变。

WinSparkle 的 DLL、固定版本和验证由 B 通道负责。本构建链把 `PacerArchitecture` 传给 MSBuild；B 的 `setup-winsparkle.ps1 -Architecture <x64|arm64>` 接入后沿用该值。C 不复制 DLL、不改更新信任密钥或 feed。打包前的 PE 校验会检查所有 EXE/DLL，包括 WinSparkle：接受目标架构及中立托管程序集，拒绝混入其他架构的原生库。产品主程序、Swift 程序、Composition、维护程序和 Python 必须是目标原生架构。

Inno 使用相同 payload 的架构和最低系统元数据，ARM64 采用 `arm64`，x64 保留 `x64compatible`。这与 [Inno 的架构规则](https://jrsoftware.org/ishelp/topic_setup_architecturesallowed.htm) 一致。安装器引导器本身由现有 Inno 编译器生成，其内部应用 payload 为目标架构；不把引导器的 PE 类型当成应用的架构。

## Windows 10 能力审查

| 功能 | 最低版本/能力边界 | 降级与证据 |
| --- | --- | --- |
| 应用、引擎与安装 | 工具链/包元数据、.NET TFM 和 `SupportedOSPlatformVersion`、Inno `MinVersion` 统一为 19041。Win32 manifest 声明 Windows 10 兼容系列，具体 build 由程序入口检查。 | 旧系统在加载采集来源之前退出并说明最低版本；C# 与 Swift 定向测试覆盖前一 build、边界、Windows 10 和 Windows 11。 |
| Glass | 现有 `BackdropPolicy` 先检查 22621，再检查系统透明效果、高对比度和 API/设备状态。 | 在 19041、19045、22000、22620 上连创建材质 DLL 的工厂都不调用，回退 Black 并保留偏好。缺失 DLL/入口、COM 和设备丢失沿用既有释放和恢复规则。 |
| 通知 | 在 19041+ 调用 SDK 的 `IsSupported`，不把 Windows 11 当成唯一条件。 | 能力拒绝或 COM、类型、DLL、入口缺失等失败返回 Unsupported，界面沿用现有状态和系统设置入口。合成测试不注册或发送系统通知。 |
| Composition 与窗口 | 路线 B 的 DispatcherQueue、桌面 Composition、几何裁剪、每屏 DPI 和点击命中 API 均属于目标 Windows 10 API 范围。可选的 DWM 圆角属性忽略失败，材质主体另有版本门槛。 | 本轮核对调用位置和失败捕获；实际驱动、显示器和 Windows 10 HWND 行为留给实机验收。 |
| WebView2 | 沿用运行时发现和缺失引导；不因平台矩阵读取外部浏览器状态。 | 浏览器/账户验收及运行时安装由用户完成，本轮没有登录、安装运行时或改系统设置。 |

## 验证和集成

本机定向检查为 `WindowsArchitectureTests`、`WindowsLocalizationTests`、桌面的 `--platform-only`，以及引擎的 `WindowsPlatformCompatibilityTests`、`WindowsClaudeRuntimeTests`。PE 用合成头验证目标、错误架构、AnyCPU、32 位必需标志、缺失/损坏头和混入的原生依赖，不执行测试二进制。PowerShell 只做解析和架构选择检查。

ARM64 CI 只执行工具链准备、Release 构建、包散列/PE 检查和安装器编译，不执行引擎、展示、通知、安装或实际产品启动测试。x64 现有验收入口不删减，ARM64 的 build-only 分支也不能用于跳过 x64 预览验收。没有在开发阶段运行新 CI；统一集成后再确认四个作业及四类 Windows 产物。

与 B 集成时核对 WinSparkle 的架构内容和包许可证；与 A 集成时统一合并 CI、入口、资源摘要及 lock 文件。此文档不代替正式发布步骤，正式发布仍遵循 [发布流程](releasing.md)。
