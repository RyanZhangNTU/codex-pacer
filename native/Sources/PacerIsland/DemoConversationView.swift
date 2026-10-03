import SwiftUI
import PacerCore

/// Explicitly labeled destination for demo clicks; never opens a real thread.
struct DemoConversationView: View {
    let activity: SessionActivity
    let onReturn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("会话跳转演示", systemImage: "arrow.up.right.square").foregroundStyle(.secondary)
            Text(activity.title ?? activity.project).font(.system(size: 26, weight: .semibold))
            Label(activity.detail(at: Date()), systemImage: "circle.fill").foregroundStyle(.mint)
            Text("正式模式中，点击任务会在 Codex 中打开对应会话，继续查看进度或回复。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Button("返回状态岛", action: onReturn).buttonStyle(.borderedProminent)
        }.padding(32).frame(width: 560, height: 320).preferredColorScheme(.dark)
    }
}
