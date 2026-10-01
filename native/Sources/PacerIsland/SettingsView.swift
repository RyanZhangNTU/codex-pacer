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
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Codex Pacer").font(.system(size: 23, weight: .semibold))
            Text("实时状态与额度").foregroundStyle(.secondary)
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
                }
                Section("Codex 数据来源") {
                    TextField("CLI 路径", text: $executable, prompt: Text("留空自动查找"))
                    TextField("Codex 目录", text: $home, prompt: Text("留空使用 CODEX_HOME 或 ~/.codex"))
                    Text("读取当前本地 Codex 账户的额度。任务活动仅覆盖本机近期日志，状态过期时显示未确认。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section {
                    Text("预览版 2.0.0-preview.1 · macOS 原生界面")
                    Text("新版不计算 API 价值，也不保存历史统计。")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let validation { Text(validation).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        let cli = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = home.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cli.isEmpty, !FileManager.default.isExecutableFile(atPath: (cli as NSString).expandingTildeInPath) {
            validation = "CLI 路径必须指向可执行的 Codex 文件。"; return
        }
        if !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                validation = "请选择现有的 Codex 目录，使用绝对路径或 ~/ 路径。"; return
            }
        }
        let defaults = UserDefaults.standard
        let sourceChanged = cli != (defaults.string(forKey: "codexExecutable") ?? "") || directory != (defaults.string(forKey: "codexHome") ?? "")
        defaults.set(cli, forKey: "codexExecutable")
        defaults.set(directory, forKey: "codexHome")
        defaults.set(floating, forKey: "floatingIsland")
        defaults.set(fullscreen, forKey: "showInFullscreen")
        defaults.set(displayID, forKey: "displayID")
        model.applySettings(sourceChanged: sourceChanged)
        onClose()
    }
}
