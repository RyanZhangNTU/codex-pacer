import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    let onClose: () -> Void
    @State private var executable = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
    @State private var home = UserDefaults.standard.string(forKey: "codexHome") ?? ""
    @State private var floating = UserDefaults.standard.bool(forKey: "floatingIsland")
    @State private var fullscreen = UserDefaults.standard.bool(forKey: "showInFullscreen")
    @State private var displayID = UserDefaults.standard.integer(forKey: "displayID")
    @State private var metric = UserDefaults.standard.string(forKey: "compactMetric") ?? "remaining"
    @State private var windowID = UserDefaults.standard.string(forKey: "quotaWindowID") ?? "auto"
    @State private var lowReminder = UserDefaults.standard.bool(forKey: "lowQuotaReminder")
    @State private var inputReminder = UserDefaults.standard.bool(forKey: "inputReminder")
    @State private var completionReminder = UserDefaults.standard.bool(forKey: "completionReminder")
    @State private var systemNotifications = UserDefaults.standard.bool(forKey: "systemNotifications")
    @State private var hideProjects = UserDefaults.standard.bool(forKey: "hideProjects")
    @State private var validation: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex Pacer").font(.system(size: 23, weight: .semibold))
            Form {
                Section("显示") {
                    Toggle("使用悬浮胶囊", isOn: $floating)
                    Toggle("在全屏空间显示", isOn: $fullscreen)
                    Picker("显示器", selection: $displayID) {
                        Text("主显示器").tag(0)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                            Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)
                        }
                    }
                    Picker("收起时的百分比", selection: $metric) {
                        Text("剩余额度").tag("remaining")
                        Text("配速百分比").tag("pace")
                    }
                    Picker("额度窗口", selection: $windowID) {
                        Text("自动，优先 7 天窗口").tag("auto")
                        ForEach(model.quota?.buckets ?? []) { bucket in
                            ForEach(bucket.windows) { window in
                                Text(window.label + ((model.quota?.buckets.count ?? 0) > 1 ? " · " + (bucket.name ?? bucket.id) : "")).tag(window.id)
                            }
                        }
                    }
                }
                Section("提醒") {
                    Toggle("低额度提醒", isOn: $lowReminder)
                    Toggle("等待回复提醒", isOn: $inputReminder)
                    Toggle("本轮结束或中断提醒", isOn: $completionReminder)
                    Toggle("同时使用系统通知", isOn: $systemNotifications)
                }
                Section("隐私") {
                    Toggle("隐藏项目名称", isOn: $hideProjects)
                }
                Section("Codex 数据来源") {
                    HStack {
                        TextField("CLI 路径", text: $executable, prompt: Text("自动查找"))
                        Button("选择…") { choose(directory: false) }
                    }
                    HStack {
                        TextField("Codex 目录", text: $home, prompt: Text("CODEX_HOME 或 ~/.codex"))
                        Button("选择…") { choose(directory: true) }
                    }
                }
                Section {
                    DisclosureGroup("数据与计算说明") {
                        Text("任务状态来自本机日志。三分钟没有新事件时，状态转为未确认。")
                        Text("token/s 合计运行中任务的输出增量，排除 autoreview。缺少样本或超过 15 秒未更新时显示不可用。")
                        Text("配速 = 剩余额度比例 ÷ 剩余时间比例 × 100。100% 为均匀配速，低于 85% 需放慢，高于 115% 较充裕。")
                        Text("额度进度条显示剩余额度；灰条显示已过时间。倒计时按服务返回的重置日期计算。")
                        Text("重置次数和券到期时间来自账户明细。credit 读取服务余额，不按 API 价格换算。")
                        Text("曲线只保存当前七天窗口。额度重置或切换账户后重新记录，虚线为配速参考。")
                        Text("系统通知需授权。关闭时，提醒显示在状态岛。")
                        if let message = model.errorMessage { Text(message).foregroundStyle(.orange) }
                        if let warning = model.historyWarning { Text(warning).foregroundStyle(.orange) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(saving)
            if let validation { Text(validation).foregroundStyle(.orange).font(.system(size: 12)) }
            HStack {
                Text("2.0.0-preview.2").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "正在保存" : "保存", action: save).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24)
        .frame(width: 480, height: 670)
        .onAppear {
            if windowID != "auto", !((model.quota?.windows ?? []).contains { $0.id == windowID }) { windowID = "auto" }
        }
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = directory ? "选择 Codex 数据目录" : "选择 Codex 可执行文件"
        if panel.runModal() == .OK, let path = panel.url?.path {
            if directory { home = path } else { executable = path }
        }
    }
    private func save() {
        let cli = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = home.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cli.isEmpty {
            let path = (cli as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                validation = "CLI 路径必须指向可执行的 Codex 文件。"; return
            }
        }
        if !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                validation = "请选择现有的 Codex 目录，使用绝对路径或 ~/ 路径。"; return
            }
        }
        saving = true
        Task { @MainActor in
            let allowed = systemNotifications ? await NotificationDelivery.requestPermission() : false
            let requestedSystem = systemNotifications
            let defaults = UserDefaults.standard
            let sourceChanged = cli != (defaults.string(forKey: "codexExecutable") ?? "") || directory != (defaults.string(forKey: "codexHome") ?? "")
            defaults.set(cli, forKey: "codexExecutable")
            defaults.set(directory, forKey: "codexHome")
            defaults.set(floating, forKey: "floatingIsland")
            defaults.set(fullscreen, forKey: "showInFullscreen")
            defaults.set(displayID, forKey: "displayID")
            defaults.set(metric, forKey: "compactMetric")
            defaults.set(windowID, forKey: "quotaWindowID")
            defaults.set(lowReminder, forKey: "lowQuotaReminder")
            defaults.set(inputReminder, forKey: "inputReminder")
            defaults.set(completionReminder, forKey: "completionReminder")
            defaults.set(allowed, forKey: "systemNotifications")
            defaults.set(hideProjects, forKey: "hideProjects")
            model.applySettings(sourceChanged: sourceChanged)
            saving = false
            systemNotifications = allowed
            if requestedSystem && !allowed {
                validation = "其他设置已保存。系统通知未授权，状态岛提醒仍可使用。"
            } else { onClose() }
        }
    }
}
