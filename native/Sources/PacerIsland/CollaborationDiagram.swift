import AppKit
import PacerCore
import SwiftUI

/// Help → Collaboration: how Claude and Codex work together, as a sequence
/// diagram, through Pacer or the typical way. Both share one 420 × 422 grid,
/// as on Windows (`CollaborationDiagram.cs`), so You, Claude and Codex stay
/// put and only Pacer's lane comes and goes; the numbered marks are where the
/// two differ. The drawing is data, so tests can check its layout.
enum CollaborationDiagram {
    static let size = CGSize(width: 420, height: 422)
    static let you: CGFloat = 30, claude: CGFloat = 118, pacer: CGFloat = 240, codex: CGFloat = 370

    /// `good` is Codex's own color, for its work bar; notes, dots and crosses use the readable `goodNote` and `bad`.
    enum Ink: Equatable { case primary, secondary, good, goodNote, bad, card, waiting, idle }
    enum Anchor: Equatable { case start, middle, end }
    enum Weight: Equatable { case regular, semibold, bold }
    enum Participant: Equatable { case claude, pacer, codex }

    struct Label: Equatable {
        let text: String
        let x: CGFloat
        let baseline: CGFloat
        let size: CGFloat
        var ink = Ink.primary
        var weight = Weight.regular
        var anchor = Anchor.middle
    }

    enum Element: Equatable {
        case person(x: CGFloat)
        case icon(Participant, x: CGFloat)
        case lifeline(x: CGFloat, end: CGFloat)
        case arrow(from: CGFloat, to: CGFloat, y: CGFloat, dashed: Bool, both: Bool)
        case bar(x: CGFloat, y: CGFloat, height: CGFloat, ink: Ink)
        /// A thick line, such as a cross.
        case stroke(from: CGPoint, to: CGPoint, ink: Ink)
        /// One of Codex's leftover conversations.
        case sheet(x: CGFloat, y: CGFloat)
        case dot(center: CGPoint, ink: Ink)
        case label(Label)
    }

    /// The drawing for one view. `text` reads a `help.collaboration.` string.
    static func elements(throughPacer: Bool, text: (String) -> String = { L10n.text("help.collaboration." + $0) }) -> [Element] {
        var items: [Element] = []
        func label(_ x: CGFloat, _ baseline: CGFloat, _ words: String, _ size: CGFloat, _ ink: Ink = .primary,
                   _ weight: Weight = .regular, _ anchor: Anchor = .middle) {
            items.append(.label(Label(text: words, x: x, baseline: baseline, size: size, ink: ink, weight: weight, anchor: anchor)))
        }
        func arrow(_ from: CGFloat, _ to: CGFloat, _ y: CGFloat, dashed: Bool = false, both: Bool = false) {
            items.append(.arrow(from: from, to: to, y: y, dashed: dashed, both: both))
        }
        func labelled(_ from: CGFloat, _ to: CGFloat, _ y: CGFloat, _ key: String) {
            label((from + to) / 2, y - 8, text(key), 12); arrow(from, to, y)
        }
        func mark(_ x: CGFloat, _ y: CGFloat, _ number: String, _ key: String, _ tone: Ink) {
            items.append(.dot(center: CGPoint(x: x, y: y), ink: tone))
            label(x, y + 3.8, number, 10.5, .card, .bold)
            let lines = text(key).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                label(x + 13, y + 4 + (CGFloat(index) - CGFloat(lines.count - 1) / 2) * 13, line, 10.5, tone, .semibold, .start)
            }
        }
        func cross(_ x: CGFloat, _ y: CGFloat, _ halfWidth: CGFloat, _ halfHeight: CGFloat, _ tone: Ink) {
            items.append(.stroke(from: CGPoint(x: x - halfWidth, y: y - halfHeight), to: CGPoint(x: x + halfWidth, y: y + halfHeight), ink: tone))
            items.append(.stroke(from: CGPoint(x: x + halfWidth, y: y - halfHeight), to: CGPoint(x: x - halfWidth, y: y + halfHeight), ink: tone))
        }

        // The participants across the top: you, then each app by its own icon.
        items.append(.person(x: you))
        items.append(.icon(.claude, x: claude))
        if throughPacer { items.append(.icon(.pacer, x: pacer)) }
        items.append(.icon(.codex, x: codex))
        label(you, 66, text("you"), 12.5, .primary, .semibold)
        label(claude, 66, "Claude", 12.5, .primary, .semibold)
        if throughPacer { label(pacer, 66, "Pacer", 12.5, .primary, .semibold) }
        label(codex, 66, "Codex", 12.5, .primary, .semibold)

        if throughPacer {
            items += [.lifeline(x: you, end: 320), .lifeline(x: claude, end: 346), .lifeline(x: pacer, end: 388), .lifeline(x: codex, end: 362)]
            labelled(you, claude - 2, 106, "ask")
            // 1 Claude hands Pacer a task brief; Pacer starts Codex with your model and access.
            labelled(claude, pacer - 6, 148, "brief"); labelled(pacer + 6, codex - 6, 148, "start")
            mark(256, 172, "1", "pacer.1", .goodNote)
            // 2 Codex works in the background; you keep interacting with Claude; Pacer watches the subtask live.
            items += [.bar(x: pacer, y: 148, height: 132, ink: .primary), .bar(x: codex, y: 148, height: 128, ink: .good)]
            for y: CGFloat in [206, 246] {
                label((you + claude) / 2, y - 10, text("interact"), 10.5, .secondary); arrow(you, claude - 2, y, dashed: true, both: true)
            }
            label((pacer + codex) / 2, 200, text("progress"), 10.5, .secondary)
            for y: CGFloat in [208, 228, 248] { arrow(codex - 6, pacer + 6, y, dashed: true) }
            mark(136, 215, "2", "pacer.2", .goodNote)
            // Codex finishes; Pacer hands the result to Claude, who delivers it.
            labelled(codex - 6, pacer + 6, 276, "done"); labelled(pacer - 6, claude + 2, 276, "result")
            labelled(claude, you + 2, 310, "deliver")
            // 3 Only when the Claude conversation ends does Claude tell Pacer, and Pacer then clears Codex's session.
            items.append(.bar(x: pacer, y: 336, height: 44, ink: .primary))
            labelled(claude, pacer - 6, 342, "ended")
            labelled(pacer + 6, codex - 12, 374, "clear")
            cross(codex, 374, 7, 7, .goodNote)
            mark(256, 400, "3", "pacer.3", .goodNote)
        } else {
            items += [.lifeline(x: you, end: 320), .lifeline(x: claude, end: 320), .lifeline(x: codex, end: 362)]
            labelled(you, claude - 2, 106, "ask")
            // 1 Claude runs Codex itself: which model and what access are out of sight.
            labelled(claude, codex - 6, 148, "run")
            mark(256, 172, "1", "typical.1", .bad)
            // 2 Claude waits in the foreground and you can't interact; nothing shows the subtask's progress.
            items += [.bar(x: claude, y: 152, height: 128, ink: .waiting), .bar(x: codex, y: 148, height: 128, ink: .idle)]
            label(claude - 12, 190, text("waits"), 10.5, .secondary, .regular, .end)
            label((you + claude) / 2, 228, text("blocked"), 10.5, .secondary); arrow(you, claude - 30, 238, dashed: true)
            cross(claude - 21, 238, 5, 6, .bad)
            mark(146, 215, "2", "typical.2", .bad)
            // The result comes back and Claude delivers it.
            labelled(codex - 6, claude + 6, 276, "result")
            labelled(claude, you + 2, 310, "deliver")
            // 3 Every run's conversation stays in Codex.
            for index in 0..<3 { items.append(.sheet(x: codex - 14 + CGFloat(index) * 3, y: 368 + CGFloat(index) * 8)) }
            mark(256, 388, "3", "typical.3", .bad)
        }
        return items
    }

    // MARK: Colors

    enum Tone { case good, bad }
    /// How strongly a view's tone tints its figure over the card.
    static let tintOpacity: CGFloat = 0.1
    /// Normal text needs 4.5:1; the bold notes are too small to count as large.
    static let readableContrast = 4.5

    /// Codex's color in the window's tone (it follows the accent), or the warning amber.
    static func base(_ tone: Tone, light: Bool) -> NSColor {
        switch tone {
        case .good: NSColor(AgentProvider.codex.shade(light: light)).usingColorSpace(.sRGB) ?? .systemTeal
        case .bad: light ? NSColor(srgbRed: 178 / 255, green: 106 / 255, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 0.74, blue: 0.38, alpha: 1)
        }
    }
    /// The card the figure sits on (`MainPalette.card`).
    static func card(light: Bool) -> NSColor { light ? .white : NSColor(srgbRed: 0.141, green: 0.141, blue: 0.157, alpha: 1) }
    /// The figure's fill: the card with its tone laid over it.
    static func figure(_ tone: Tone, light: Bool) -> NSColor { mix(card(light: light), base(tone, light: light), tintOpacity) }
    /// The tone darkened (light) or lightened (dark) just enough to read on its figure.
    static func note(_ tone: Tone, light: Bool) -> NSColor {
        let start = base(tone, light: light), background = figure(tone, light: light), target: NSColor = light ? .black : .white
        for step in 0...40 {
            let candidate = mix(start, target, CGFloat(step) / 40)
            if contrast(candidate, background) >= readableContrast + 0.05 { return candidate }
        }
        return target
    }

    static func mix(_ first: NSColor, _ second: NSColor, _ amount: CGFloat) -> NSColor {
        let a = first.usingColorSpace(.sRGB) ?? first, b = second.usingColorSpace(.sRGB) ?? second
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * amount,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount, alpha: 1)
    }
    /// WCAG contrast between two opaque colors.
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> Double { let v = Double(value); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }

    static func summary(throughPacer: Bool) -> String {
        L10n.text(throughPacer ? "help.collaboration.pacer.summary" : "help.collaboration.typical.summary")
    }

    /// A label's box on the grid, from cap height to just under the baseline, as on Windows.
    static func bounds(_ label: Label) -> CGRect {
        let weight: NSFont.Weight = label.weight == .bold ? .bold : label.weight == .semibold ? .semibold : .regular
        let width = (label.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: label.size, weight: weight)]).width
        let left = label.anchor == .start ? label.x : label.anchor == .middle ? label.x - width / 2 : label.x - width
        return CGRect(x: left, y: label.baseline - label.size * 0.78, width: width, height: label.size * 0.95)
    }
}

/// The diagram drawn to fit its width; one picture to VoiceOver, named by its summary.
struct CollaborationDiagramView: View {
    let throughPacer: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let items = CollaborationDiagram.elements(throughPacer: throughPacer)
        Canvas { context, size in
            let grid = CollaborationDiagram.size
            context.scaleBy(x: size.width / grid.width, y: size.height / grid.height)
            for item in items { draw(item, in: &context) }
        } symbols: {
            ProviderAppIcon(provider: .claude, size: 30).tag("claude")
            ProviderAppIcon(provider: .codex, size: 30).tag("codex")
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 30, height: 30).tag("pacer")
        }
        .aspectRatio(CollaborationDiagram.size.width / CollaborationDiagram.size.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CollaborationDiagram.summary(throughPacer: throughPacer))
        .accessibilityAddTraits(.isImage)
    }

    private func color(_ ink: CollaborationDiagram.Ink) -> Color {
        switch ink {
        case .primary: .primary
        case .secondary: .secondary
        case .good: Color(nsColor: CollaborationDiagram.base(.good, light: scheme == .light))
        case .goodNote: Color(nsColor: CollaborationDiagram.note(.good, light: scheme == .light))
        case .bad: Color(nsColor: CollaborationDiagram.note(.bad, light: scheme == .light))
        case .card: MainPalette.card
        case .waiting: Color.primary.opacity(0.28)
        case .idle: Color.primary.opacity(0.14)
        }
    }

    private func draw(_ item: CollaborationDiagram.Element, in context: inout GraphicsContext) {
        switch item {
        case .person(let x):
            context.stroke(Path(ellipseIn: CGRect(x: x - 7, y: 15, width: 14, height: 14)), with: .color(.primary), lineWidth: 1.6)
            var body = Path()
            for step in 0...24 {
                let angle = Double.pi + Double.pi * Double(step) / 24
                let point = CGPoint(x: x + 13 * cos(angle), y: 48 + 11 * sin(angle))
                if step == 0 { body.move(to: point) } else { body.addLine(to: point) }
            }
            context.stroke(body, with: .color(.primary), lineWidth: 1.6)
        case .icon(let participant, let x):
            let tag: String = switch participant { case .claude: "claude"; case .pacer: "pacer"; case .codex: "codex" }
            if let symbol = context.resolveSymbol(id: tag) { context.draw(symbol, in: CGRect(x: x - 15, y: 12, width: 30, height: 30)) }
        case .lifeline(let x, let end):
            var line = Path(); line.move(to: CGPoint(x: x, y: 78)); line.addLine(to: CGPoint(x: x, y: end))
            context.stroke(line, with: .color(Color.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 3.3]))
        case .arrow(let from, let to, let y, let dashed, let both):
            let ink = color(dashed ? .secondary : .primary)
            let direction: CGFloat = to >= from ? 1 : -1, back = to - direction * 8, start = both ? from + direction * 8 : from
            var line = Path(); line.move(to: CGPoint(x: start, y: y)); line.addLine(to: CGPoint(x: back, y: y))
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3.3, 2.7] : []))
            context.fill(head(tip: to, back: back, y: y), with: .color(ink))
            if both { context.fill(head(tip: from, back: start, y: y), with: .color(ink)) }
        case .bar(let x, let y, let height, let ink):
            context.fill(Path(roundedRect: CGRect(x: x - 6, y: y, width: 12, height: height), cornerRadius: 3), with: .color(color(ink)))
        case .stroke(let from, let to, let ink):
            var line = Path(); line.move(to: from); line.addLine(to: to)
            context.stroke(line, with: .color(color(ink)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        case .sheet(let x, let y):
            let shape = Path(roundedRect: CGRect(x: x, y: y, width: 24, height: 13), cornerRadius: 3)
            context.fill(shape, with: .color(color(.card)))
            context.stroke(shape, with: .color(color(.bad)), lineWidth: 1.2)
        case .dot(let center, let ink):
            context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(color(ink)))
        case .label(let label):
            let weight: Font.Weight = label.weight == .bold ? .bold : label.weight == .semibold ? .semibold : .regular
            let resolved = context.resolve(Text(label.text).font(.system(size: label.size, weight: weight)).foregroundColor(color(label.ink)))
            let measured = resolved.measure(in: CGSize(width: 1000, height: 100))
            let baseline = resolved.firstBaseline(in: measured)
            let left = label.anchor == .start ? label.x : label.anchor == .middle ? label.x - measured.width / 2 : label.x - measured.width
            context.draw(resolved, in: CGRect(x: left, y: label.baseline - baseline, width: measured.width, height: measured.height))
        }
    }

    private func head(tip: CGFloat, back: CGFloat, y: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: tip, y: y)); path.addLine(to: CGPoint(x: back, y: y - 4.5)); path.addLine(to: CGPoint(x: back, y: y + 4.5))
        path.closeSubpath()
        return path
    }
}

/// Help → Collaboration: Pacer's way first, the typical way a switch away,
/// each on its own tint. The switch is not remembered.
struct CollaborationHelp: View {
    @State private var throughPacer = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 12) {
            MainSegmented(options: [(value: true, title: "Pacer"), (value: false, title: L10n.text("help.collaboration.typical"))],
                          selection: $throughPacer, label: L10n.text("help.collaboration.view"))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(throughPacer ? "help.collaboration.pacer.caption" : "help.collaboration.typical.caption"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
                CollaborationDiagramView(throughPacer: throughPacer)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 6, trailing: 8))
            .background(Color(nsColor: CollaborationDiagram.figure(throughPacer ? .good : .bad, light: scheme == .light)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
