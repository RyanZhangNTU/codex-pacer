# Windows 文案来源

通用文案来自 `native/Sources/PacerCore/Resources/{en,zh-Hans}.lproj/Localizable.strings`，与 Swift 界面共用。这里的 `en.json` 和 `zh-Hans.json` 只放 Windows 专属提示，键必须以 `windows.` 开头，不能覆盖共用键。

修改任一来源后运行：

```powershell
python scripts/windows/build-localization.py
python scripts/windows/build-localization.py --check
```

生成结果在 `windows/EngineSupport/Resources/Localization/Catalogs`，不手动编辑。脚本记录规范化换行后的来源 SHA-256，并检查两种语言的键和格式参数是否一致。printf 参数比较编号、类型和次数，.NET 参数比较编号和次数，译文可以调整参数顺序。Windows 测试入口和 CI 会拒绝过期结果。

修改 Windows 文案后还可运行定向检查：

```powershell
python scripts/windows/test_contract.py WindowsLocalizationTests
```

这组测试检查生成目录、界面直接引用的键、格式参数，以及设置/引导页面误用 Mac 专属说明的问题。历史更新记录保留原始平台背景，未按 Windows 改写。

引擎从 `PacerEngineSupport` 的资源 bundle 读取目录，通过 `WindowsResources` 向共享 `L10n` 注入 Windows 文案。WPF 在构建时从同一目录生成嵌入资源。共用字符串、格式占位符和业务数值格式化仍由 Core 负责；原有本地化测试同时覆盖两种语言。

共用目录中仍有面向 macOS 的原文。Windows 使用某个键前须检查其平台含义；系统设置、安装路径或启动项等文字应新增 `windows.*` 键，保留 Mac 原文。
