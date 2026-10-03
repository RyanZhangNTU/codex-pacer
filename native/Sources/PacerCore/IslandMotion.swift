import Foundation
import CoreGraphics

/// A critically damped spring shared by both shell dimensions and the reveal.
/// Retargeting carries the displayed position AND velocity into the next spring.
public struct IslandMotion {
    public struct Velocity {
        public var width: Double = 0
        public var height: Double = 0
        public var center: Double = 0
        public var top: Double = 0
        public var expansion: Double = 0

        public static let zero = Self()
    }

    public struct Sample {
        public let frame: CGRect
        public let expansion: Double
        public let velocity: Velocity
        public let finished: Bool

        /// Reveal follows the available space, so reversing also reverses the
        /// fade continuously. There is no separate fade-out / resize phase.
        public var content: Double {
            let fraction = min(1, max(0, (expansion - 0.12) / 0.76))
            return fraction * fraction * (3 - 2 * fraction)
        }

        public static func resting(at frame: CGRect, expanded: Bool) -> Self {
            Self(frame: frame, expansion: expanded ? 1 : 0, velocity: .zero, finished: true)
        }
    }

    public let target: Sample
    private let initial: Sample
    private let start: TimeInterval
    private let frequency: Double

    public init(from sample: Sample, to frame: CGRect, opening: Bool, start: TimeInterval) {
        initial = sample
        target = .resting(at: frame, expanded: opening)
        self.start = start
        // Opening has a soft landing; closing is a little more responsive.
        // Both dimensions start together and keep the same response throughout.
        frequency = opening ? 20 : 26
    }

    public func sample(at time: TimeInterval) -> Sample {
        let elapsed = max(0, time - start)
        if elapsed == 0 {
            return Sample(frame: initial.frame, expansion: initial.expansion,
                          velocity: initial.velocity, finished: false)
        }
        // Also bounds the display-link lifetime after sleep or a stalled frame.
        guard elapsed < 1.2 else { return target }
        let width = spring(initial.frame.width, target.frame.width, initial.velocity.width, elapsed)
        let height = spring(initial.frame.height, target.frame.height, initial.velocity.height, elapsed)
        let center = spring(initial.frame.midX, target.frame.midX, initial.velocity.center, elapsed)
        let top = spring(initial.frame.maxY, target.frame.maxY, initial.velocity.top, elapsed)
        let expansion = spring(initial.expansion, target.expansion, initial.velocity.expansion, elapsed)
        if width.settled && height.settled && center.settled && top.settled &&
            abs(expansion.value - target.expansion) < 0.0002 && abs(expansion.velocity) < 0.005 {
            return target
        }
        return Sample(frame: CGRect(x: center.value - width.value / 2, y: top.value - height.value,
                                    width: width.value, height: height.value),
                      expansion: expansion.value,
                      velocity: Velocity(width: width.velocity, height: height.velocity,
                                         center: center.velocity, top: top.velocity, expansion: expansion.velocity),
                      finished: false)
    }

    private func spring(_ value: Double, _ destination: Double, _ velocity: Double,
                        _ elapsed: TimeInterval) -> (value: Double, velocity: Double, settled: Bool) {
        // Closed-form solution: independent of refresh rate and dropped frames.
        let displacement = value - destination
        let coefficient = velocity + frequency * displacement
        let decay = exp(-frequency * elapsed)
        let offset = (displacement + coefficient * elapsed) * decay
        let speed = (velocity - frequency * coefficient * elapsed) * decay
        return (destination + offset, speed, abs(offset) < 0.05 && abs(speed) < 0.5)
    }
}
