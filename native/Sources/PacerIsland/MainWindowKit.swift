import AppKit
import PacerCore
import SwiftUI

/// The main window's own look: a calm page, small gray section labels and
/// rounded cards of 44-point rows, the way the design drafts draw it. Colors
/// adapt to light and dark; the island's components sit on `islandSurface`,
/// which stays dark like the island itself.
enum MainPalette {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let page = dynamic(dark: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1),
                              light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1))
    static let card = dynamic(dark: NSColor(srgbRed: 0.141, green: 0.141, blue: 0.157, alpha: 1), light: .white)
    static let cardBorder = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.08))
    static let separator = dynamic(dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 0, alpha: 0.07))
    static let fill = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.05))
    static let selectedFill = dynamic(dark: NSColor(white: 1, alpha: 0.16), light: .white)
    static let button = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.07))
    static let infoFill = dynamic(dark: NSColor(white: 1, alpha: 0.05), light: NSColor(white: 0, alpha: 0.04))
    /// The island is always dark, so its components keep a dark card.
    static let islandSurface = Color(red: 0.141, green: 0.141, blue: 0.157)
    static let positive = Color(red: 0.2, green: 0.84, blue: 0.29)
    static let attention = PacerPalette.attention
}

/// A scrolling page with its content in one centered column.
struct MainPage<Content: View>: View {
    var maxWidth: CGFloat = 640
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(MainPalette.page)
    }
}

/// The page title with an optional line under it, a leading tile and a
/// trailing control.
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension PageHeader where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A gray label, a card of rows divided by hairlines, and an optional note.
/// Each child of `content` is one row of at least 44 points.
struct MainCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var padding: CGFloat = 14
    /// Shown at the end of the title line, such as column names.
    var titleTrailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || titleTrailing != nil {
                HStack(spacing: 0) {
                    if let title {
                        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    if let titleTrailing { titleTrailing }
                }
                .padding(.leading, 4).padding(.trailing, padding + 1)
            }
            _VariadicView.Tree(CardRows()) { content }
                .padding(.horizontal, padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mainCardSurface()
                .toggleStyle(CardSwitchStyle())
                .labeledContentStyle(CardLabeledContentStyle())
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

private struct CardRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let first = children.first?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                if child.id != first { Rectangle().fill(MainPalette.separator).frame(height: 1) }
                child.padding(.vertical, 8).frame(minHeight: 44, alignment: .leading)
            }
        }
    }
}

extension View {
    /// The card surface the drafts use.
    func mainCardSurface(radius: CGFloat = 12) -> some View {
        background(MainPalette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(MainPalette.cardBorder))
    }

    /// A dark card for the island's own components.
    func islandSurface(radius: CGFloat = 14) -> some View {
        background(MainPalette.islandSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
            .environment(\.colorScheme, .dark)
    }
}

/// The label on the left and the switch at the row's end.
struct CardSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch)
        }
    }
}

struct CardLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(.system(size: 13))
            Spacer(minLength: 8)
            configuration.content.foregroundStyle(.secondary)
        }
    }
}

/// One row: a title with an optional ⓘ that opens a short explanation under
/// it, then whatever the row holds at its end.
struct CardRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var info: String? = nil
    @ViewBuilder var trailing: Trailing
    @State private var showsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 13))
                        if info != nil { InfoButton(title: title, isOn: $showsInfo) }
                    }
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            if showsInfo, let info { InfoBox(text: info) }
        }
    }
}

extension CardRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, info: String? = nil) {
        self.init(title: title, detail: detail, info: info, trailing: { EmptyView() })
    }
}

/// A switch row with an optional explanation behind ⓘ.
struct CardToggle: View {
    let title: String
    var detail: String? = nil
    var info: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        CardRow(title: title, detail: detail, info: info) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// The progress ring switch for a service Pacer sets up a reporting tool
/// for: what the setup did under the title, and Retry when it failed.
struct ProgressRingToggle: View {
    var info: String
    @Binding var isOn: Bool
    var status: String? = nil
    var canRetry = false
    var retry: () -> Void = {}

    var body: some View {
        CardRow(title: L10n.text("main.claude.ring"), detail: status, info: info) {
            HStack(spacing: 8) {
                if canRetry { Button(L10n.text("connections.retry"), action: retry).buttonStyle(.main) }
                Toggle(L10n.text("main.claude.ring"), isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

/// A menu choice at the row's end.
struct CardPicker<Value: Hashable>: View {
    let title: String
    var info: String? = nil
    @Binding var selection: Value
    /// Each choice and what it shows, in menu order.
    let options: [(Value, String)]

    var body: some View {
        CardRow(title: title, info: info) {
            OutlineMenu(title: title, selection: $selection, options: options)
        }
    }
}

/// A menu drawn as a line: the current choice and a chevron in a hairline
/// frame instead of the filled pop-up button. The menu itself stays the
/// system's, with a check by the current choice.
struct OutlineMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var hovering = false

    private var current: String { options.first { $0.0 == selection }?.1 ?? "—" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Menu {
            // One checkable item per choice. The menu takes the card's switch
            // style unless reset, which split each item in three and greyed it.
            ForEach(options.indices, id: \.self) { index in
                let value = options[index].0
                Toggle(options[index].1, isOn: Binding(get: { selection == value }, set: { if $0 { selection = value } }))
            }
            .toggleStyle(.automatic)
        } label: {
            HStack(spacing: 6) {
                Text(current).font(.system(size: 12.5)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(shape.fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .overlay(shape.strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.16)))
            .contentShape(shape)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

/// A row that only reports: a colored dot and its state, then any action.
struct CardStatusRow<Action: View>: View {
    let title: String
    let state: String
    let tint: Color
    var help: String? = nil
    var detail: String? = nil
    @ViewBuilder var action: Action

    var body: some View {
        CardRow(title: title, detail: detail) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(state).font(.system(size: 12.5))
                    .foregroundStyle(tint == MainPalette.attention || tint == .orange ? MainPalette.attention : Color.secondary)
                    .lineLimit(1)
                action
            }
            .help(help ?? "")
        }
    }
}

extension CardStatusRow where Action == EmptyView {
    init(title: String, state: String, tint: Color, help: String? = nil, detail: String? = nil) {
        self.init(title: title, state: state, tint: tint, help: help, detail: detail, action: { EmptyView() })
    }
}

/// The ⓘ beside a title; it toggles the explanation under the row.
struct InfoButton: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Image(systemName: "info.circle").font(.system(size: 12.5))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("main.info", title))
        .accessibilityValue(L10n.text(isOn ? "main.info_shown" : "main.info_hidden"))
    }
}

struct InfoBox: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).lineSpacing(2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MainPalette.infoFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .transition(.opacity)
    }
}

/// A folding section's header row: chevron, title and a summary at the end.
struct CardDisclosure: View {
    let title: String
    var summary: String? = nil
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if let summary { Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(L10n.text(isExpanded ? "main.info_shown" : "main.info_hidden"))
    }
}

/// The drafts' small gray button.
struct MainButtonStyle: ButtonStyle {
    var prominent = false
    /// 24 in rows; a card's own call to action is taller, and a window's
    /// main button (32 or more) is larger still.
    var height: CGFloat = 24
    /// A prominent button in another color, such as a service's own.
    var fill: Color? = nil
    var label: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        MainButtonBody(configuration: configuration, prominent: prominent, height: height, fill: fill, label: label)
    }

    private struct MainButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let height: CGFloat
        let fill: Color?
        let label: Color?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.pacerAccent) private var accent
        var body: some View {
            let large = height >= 32
            let shape = RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
            configuration.label
                .font(.system(size: large ? 13.5 : height > 24 ? 12.5 : 12, weight: large && prominent ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(label ?? (prominent ? Color.white : Color.primary))
                .padding(.horizontal, large ? 16 : 11).frame(height: height)
                .background(fill ?? (prominent ? accent : MainPalette.button), in: shape)
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(shape)
        }
    }
}

extension ButtonStyle where Self == MainButtonStyle {
    static var main: MainButtonStyle { MainButtonStyle() }
    static var mainProminent: MainButtonStyle { MainButtonStyle(prominent: true) }
}

/// The drafts' segmented control: a gray track with the choice raised.
struct MainSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String = ""
    var expands = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12).frame(maxWidth: expands ? .infinity : nil).frame(height: 24)
                        .background(selected ? MainPalette.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(MainPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A text field with a chooser, for custom locations.
struct CardPathField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    var issue: String? = nil
    var focus: FocusState<TextSetting?>.Binding? = nil
    var field: TextSetting? = nil
    let commit: () -> Void
    let choose: () -> Void
    var extra: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13)).frame(width: 96, alignment: .leading)
                textField
                if let extra { extra }
                Button(L10n.text("common.choose"), action: choose).buttonStyle(.main)
            }
            if let issue { Text(issue).font(.system(size: 11.5)).foregroundStyle(MainPalette.attention) }
        }
    }

    @ViewBuilder private var textField: some View {
        let base = TextField(title, text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
            .font(.system(size: 12.5)).onSubmit(commit)
        if let focus, let field { base.focused(focus, equals: field) } else { base }
    }
}
