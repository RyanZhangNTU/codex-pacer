import SwiftUI
import PacerCore

/// Explicitly labeled destination for demo clicks; never opens a real thread.
struct DemoConversationView: View {
    let activity: SessionActivity
    let onReturn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(L10n.text("demo.chat_heading"), systemImage: "arrow.up.right.square").foregroundStyle(.secondary)
            Text(activity.title ?? activity.project).font(.system(size: 26, weight: .semibold))
            Label(activity.detail(at: Date()), systemImage: "circle.fill").foregroundStyle(.mint)
            Text(L10n.text("demo.chat_detail"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("demo.return"), action: onReturn).buttonStyle(.borderedProminent)
        }.padding(32).frame(width: 560, height: 320).preferredColorScheme(.dark)
    }
}
