import Foundation
import CoreGraphics

/// One timeline for the window, shell and content. Retarget from the last
/// displayed sample so reversing a hover never jumps to an endpoint.
public struct IslandMotion {
    public struct Sample {
        public let frame: CGRect
        public let expansion: Double
        public let content: Double
        public let finished: Bool
    }

    public let duration: TimeInterval
    private let from: CGRect
    private let to: CGRect
    private let start: TimeInterval
    private let expansion: Double
    private let content: Double
    private let opening: Bool

    public init(from: CGRect, to: CGRect, expansion: Double, content: Double,
                opening: Bool, start: TimeInterval, distance: Double = 1) {
        self.from = from; self.to = to; self.start = start
        self.expansion = expansion; self.content = content; self.opening = opening
        duration = max(0.12, (opening ? 0.36 : 0.26) * sqrt(min(1, max(0, distance))))
    }

    public func sample(at time: TimeInterval) -> Sample {
        let elapsed = max(0, time - start)
        let fraction = min(1, elapsed / duration)
        if fraction == 1 {
            return Sample(frame: to, expansion: opening ? 1 : 0, content: opening ? 1 : 0, finished: true)
        }
        let width = ease(segment(fraction, from: opening ? 0 : 0.25, to: opening ? 0.55 : 1))
        let height = ease(segment(fraction, from: opening ? 0.04 : 0.18, to: 1))
        let reveal = ease(segment(fraction, from: opening ? 0.24 : 0, to: opening ? 0.85 : 0.28))
        let w = blend(from.width, to.width, width), h = blend(from.height, to.height, height)
        let center = blend(from.midX, to.midX, height), top = blend(from.maxY, to.maxY, height)
        return Sample(frame: CGRect(x: center - w / 2, y: top - h, width: w, height: h),
            expansion: blend(expansion, opening ? 1 : 0, height),
            content: blend(content, opening ? 1 : 0, reveal), finished: fraction == 1)
    }

    private func segment(_ value: Double, from: Double, to: Double) -> Double {
        min(1, max(0, (value - from) / (to - from)))
    }
    // Critically damped response: starts at rest and never overshoots the shell.
    private func ease(_ value: Double) -> Double {
        (1 - (1 + 7 * value) * exp(-7 * value)) / (1 - 8 * exp(-7))
    }
    private func blend(_ from: Double, _ to: Double, _ fraction: Double) -> Double { from + (to - from) * fraction }
}
