import AppKit
import CoreGraphics
import PacerCore

/// The task icon's centre glyphs, drawn as paths so each can light one part
/// at a time: the three stars while thinking, the dots while replying, the
/// cursor while a tool runs. A glyph never turns, scales or moves; only its
/// parts brighten and dim. Paths use a 24-unit box with y running down, like
/// the design draft; the view scales and flips them.
enum TaskGlyphArt {
    /// How a part's opacity loops. Every part of one glyph shares a period, and
    /// parts of a wave start one after another.
    struct Rhythm: Equatable {
        let period: Double
        /// Opacities and their times (0...1 of the period).
        let values: [Double]
        let times: [Double]
        /// Seconds after the shared clock's period start.
        let offset: Double
        static func wave(_ index: Int, period: Double, step: Double, low: Double) -> Rhythm {
            Rhythm(period: period, values: [low, 1, low, low], times: [0, 0.25, 0.6, 1], offset: Double(index) * step)
        }
        /// Two frames, like a text cursor.
        static let blink = Rhythm(period: 1.1, values: [1, 1, 0.12, 0.12, 1], times: [0, 0.5, 0.5, 0.999, 1], offset: 0)
        static let sandTop = Rhythm(period: 2.4, values: [1, 0.2, 1], times: [0, 0.65, 1], offset: 0)
        static let sandBottom = Rhythm(period: 2.4, values: [0.2, 1, 0.2], times: [0, 0.65, 1], offset: 0)
    }
    struct Part {
        let path: CGPath
        let filled: Bool
        var rhythm: Rhythm?
    }

    /// The working glyph for a stage. Stages without one draw no parts.
    static func parts(for symbol: TaskSymbol) -> [Part] {
        switch symbol {
        case .thinking:
            // Three stars, the large one dimming least so the glyph always reads.
            return [Part(path: star(9.6, 14, 7.2), filled: false, rhythm: Rhythm(period: 2.1, values: [0.55, 1, 0.55, 0.55], times: [0, 0.25, 0.6, 1], offset: 0)),
                    Part(path: star(17.6, 5.6, 3.6), filled: true, rhythm: .wave(1, period: 2.1, step: 0.35, low: 0.3)),
                    Part(path: star(20, 17.6, 2.3), filled: true, rhythm: .wave(2, period: 2.1, step: 0.35, low: 0.3))]
        case .tool:
            return [Part(path: CGPath(roundedRect: CGRect(x: 3.5, y: 5, width: 17, height: 14), cornerWidth: 3.2, cornerHeight: 3.2, transform: nil), filled: false),
                    Part(path: svg("M7.6 10.1l2.6 1.9-2.6 1.9"), filled: false),
                    Part(path: svg("M12.6 14.2h3.8"), filled: false, rhythm: .blink)]
        case .responding:
            return [Part(path: bubble, filled: false)] + [8.6, 12, 15.4].enumerated().map { index, x in
                Part(path: dot(x, 11.2, 1.25), filled: true, rhythm: .wave(index, period: 1.2, step: 0.18, low: 0.28))
            }
        case .starting:
            return [Part(path: svg("M7 3.5h10M7 20.5h10"), filled: false),
                    Part(path: svg("M8.2 3.5v2.3c0 2.3 1.5 3.8 3.8 6.2 2.3-2.4 3.8-3.9 3.8-6.2V3.5"), filled: false),
                    Part(path: svg("M8.2 20.5v-2.3c0-2.3 1.5-3.8 3.8-6.2 2.3 2.4 3.8 3.9 3.8 6.2v2.3"), filled: false),
                    Part(path: svg("M10 6.6h4l-2 2.3z"), filled: true, rhythm: .sandTop),
                    Part(path: svg("M9.6 19.2h4.8c-.35-1.5-1.2-2.4-2.4-3.2-1.2.8-2.05 1.7-2.4 3.2z"), filled: true, rhythm: .sandBottom)]
        case .working:
            // A cloud Project only says it is working, so its glyph keeps still.
            return [Part(path: svg("M7.6 18.2h9a4 4 0 0 0 .5-7.97 5.4 5.4 0 0 0-10.3 1.2A3.4 3.4 0 0 0 7.6 18.2z"), filled: false)]
        case .coordinating:
            return [Part(path: svg("M12 17.2v-4.6M12 12.6L8 8.4M12 12.6l4-4.2"), filled: false)]
                + [(12.0, 19.2), (6.6, 6.8), (17.4, 6.8)].enumerated().map { index, point in
                    Part(path: dot(point.0, point.1, 1.9), filled: true, rhythm: .wave(index, period: 2.1, step: 0.35, low: 0.3))
                }
        case .background:
            return [Part(path: svg("M11.8 6.2a6.6 6.6 0 1 0 6.9 8.9 5.2 5.2 0 0 1-6.9-8.9z"), filled: false),
                    Part(path: svg("M14.6 3.6h2.9l-2.9 2.9h2.9"), filled: false, rhythm: Rhythm(period: 3, values: [0.2, 1, 0.2], times: [0, 0.5, 1], offset: 0)),
                    Part(path: svg("M18.4 8.4h2.2l-2.2 2.2h2.2"), filled: false, rhythm: Rhythm(period: 3, values: [0.2, 1, 0.2], times: [0, 0.5, 1], offset: 1.5))]
        default:
            return []
        }
    }

    /// The check a finished task draws inside its disc.
    static let check = svg("M7.4 12.4l3.1 3.1 6.1-6.6")

    /// SF Symbols for the solid faces, which keep still.
    static func solidSymbol(for symbol: TaskSymbol) -> String? {
        switch symbol {
        case .approval: "hand.raised.fill"
        case .input: "questionmark.bubble.fill"
        case .interrupted: "pause.fill"
        case .failed: "xmark"
        default: nil
        }
    }

    // MARK: Shapes

    private static let bubble: CGPath = {
        let path = CGMutablePath(), radius = 2.7
        path.move(to: CGPoint(x: 6.2, y: 5.2))
        path.addArc(tangent1End: CGPoint(x: 20.5, y: 5.2), tangent2End: CGPoint(x: 20.5, y: 17.2), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 20.5, y: 17.2), tangent2End: CGPoint(x: 3.5, y: 17.2), radius: radius)
        path.addLine(to: CGPoint(x: 11.7, y: 17.2))
        path.addLine(to: CGPoint(x: 7.8, y: 20.1))
        path.addLine(to: CGPoint(x: 7.8, y: 17.2))
        path.addArc(tangent1End: CGPoint(x: 3.5, y: 17.2), tangent2End: CGPoint(x: 3.5, y: 5.2), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 3.5, y: 5.2), tangent2End: CGPoint(x: 20.5, y: 5.2), radius: radius)
        path.closeSubpath()
        return path
    }()

    private static func dot(_ x: Double, _ y: Double, _ radius: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }

    /// A four-point star like SF Symbols' sparkle, centred on (x, y).
    static func star(_ x: Double, _ y: Double, _ r: Double) -> CGPath {
        let path = CGMutablePath()
        var point = CGPoint(x: x, y: y - r)
        path.move(to: point)
        // Each quarter: out to the next tip, the curve pulled towards the centre.
        for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
            let horizontalFirst = sx * sy < 0
            let a = horizontalFirst ? CGPoint(x: 0.59 * sx, y: 0.049 * sy) : CGPoint(x: 0.055 * sx, y: 0.6 * sy)
            let b = horizontalFirst ? CGPoint(x: 0.945 * sx, y: 0.4 * sy) : CGPoint(x: 0.41 * sx, y: 0.95 * sy)
            let end = CGPoint(x: point.x + sx * r, y: point.y + sy * r)
            path.addCurve(to: end, control1: CGPoint(x: point.x + a.x * r, y: point.y + a.y * r),
                          control2: CGPoint(x: point.x + b.x * r, y: point.y + b.y * r))
            point = end
        }
        path.closeSubpath()
        return path
    }

    /// The subset of SVG path data the glyphs use: M L H V C A Z, absolute or
    /// relative, with implicit repeats. Arcs are circular.
    static func svg(_ data: String) -> CGPath {
        var numbers: [Double] = [], tokens: [Any] = []
        var scanner = Substring(data)
        func flushNumber(_ text: inout String) { if let value = Double(text) { tokens.append(value) }; text = "" }
        var text = ""
        while let character = scanner.first {
            scanner = scanner.dropFirst()
            if character.isLetter { flushNumber(&text); tokens.append(character) }
            else if character == "-" { if !text.isEmpty, text.last != "e" { flushNumber(&text) }; text.append(character) }
            else if character == "." {
                if text.contains(".") { flushNumber(&text) }
                text.append(character)
            } else if character == "," || character == " " { flushNumber(&text) }
            else { text.append(character) }
        }
        flushNumber(&text)
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, command: Character = "M"
        var index = 0
        func next() -> Double { defer { index += 1 }; return numbers[index] }
        var tokenIndex = 0
        while tokenIndex < tokens.count {
            if let letter = tokens[tokenIndex] as? Character { command = letter; tokenIndex += 1; if letter == "z" || letter == "Z" { path.closeSubpath(); current = start; continue } }
            numbers = []; index = 0
            while tokenIndex < tokens.count, let value = tokens[tokenIndex] as? Double { numbers.append(value); tokenIndex += 1 }
            let relative = command.isLowercase
            func point(_ x: Double, _ y: Double) -> CGPoint { relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            var first = true
            while index < numbers.count {
                switch command.uppercased() {
                case "M":
                    let p = point(next(), next())
                    if first { path.move(to: p); start = p } else { path.addLine(to: p) }
                    current = p
                case "L": let p = point(next(), next()); path.addLine(to: p); current = p
                case "H": let x = next(); current = CGPoint(x: relative ? current.x + x : x, y: current.y); path.addLine(to: current)
                case "V": let y = next(); current = CGPoint(x: current.x, y: relative ? current.y + y : y); path.addLine(to: current)
                case "C":
                    let c1 = point(next(), next()), c2 = point(next(), next()), end = point(next(), next())
                    path.addCurve(to: end, control1: c1, control2: c2); current = end
                case "A":
                    let radius = next(); _ = next(); _ = next()
                    let large = next() != 0, sweep = next() != 0, end = point(next(), next())
                    addArc(to: path, from: current, to: end, radius: radius, large: large, sweep: sweep); current = end
                default: index = numbers.count
                }
                first = false
            }
        }
        return path
    }

    /// An SVG circular arc from its endpoints, in a y-down box.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, radius: Double, large: Bool, sweep: Bool) {
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let dx = p1.x - p0.x, dy = p1.y - p0.y, chord = hypot(dx, dy)
        guard chord > 0 else { return }
        let r = max(radius, chord / 2), h = sqrt(max(0, r * r - chord * chord / 4))
        // The centre sits to one side of the chord; flags pick which.
        let sign: Double = large == sweep ? -1 : 1
        let center = CGPoint(x: mid.x + sign * h * (-dy / chord), y: mid.y + sign * h * (dx / chord))
        let a0 = atan2(p0.y - center.y, p0.x - center.x), a1 = atan2(p1.y - center.y, p1.x - center.x)
        // SVG's positive sweep turns towards +y, which CGPath calls counterclockwise=false in a y-down box.
        path.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: !sweep)
    }
}
