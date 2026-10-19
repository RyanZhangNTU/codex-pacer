import SwiftUI
import PacerCore

/// Explicitly labeled destination for demo clicks; never opens a real thread or app.
struct DemoConversationView: View {
    let heading: String
    let title: String
    let status: String?
    let detail: String
    let onReturn: () -> Void
    init(activity: SessionActivity, onReturn: @escaping () -> Void) {
        heading = L10n.text("demo.chat_heading"); title = activity.title ?? activity.project
        status = activity.detail(at: Date()); detail = L10n.text("demo.chat_detail"); self.onReturn = onReturn
    }
    init(application provider: AgentProvider, onReturn: @escaping () -> Void) {
        heading = L10n.text("demo.app_heading"); title = provider.displayName
        status = nil; detail = L10n.text("demo.app_detail", provider.displayName); self.onReturn = onReturn
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(heading, systemImage: "arrow.up.right.square").foregroundStyle(.secondary)
            Text(title).font(.system(size: 26, weight: .semibold))
            if let status { Label(status, systemImage: "circle.fill").foregroundStyle(.mint) }
            Text(detail)
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("demo.return"), action: onReturn).buttonStyle(.borderedProminent)
        }.padding(32).frame(width: 560, height: 320).preferredColorScheme(.dark)
    }
}
