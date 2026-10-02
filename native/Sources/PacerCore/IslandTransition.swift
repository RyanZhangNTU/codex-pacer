import Foundation
import CoreGraphics

/// Sequences the physical-notch backing around the shell's spring. Sample in
/// display-time order; retarget from the last displayed sample on interruption.
public struct IslandTransition {
    public struct Sample {
        public let geometry: IslandMotion.Sample
        public let blackOpacity: Double
        public let finished: Bool

        public var frame: CGRect { geometry.frame }
        public var expansion: Double { geometry.expansion }
        public var content: Double { geometry.content }

        public static func resting(at frame: CGRect, expanded: Bool, hasBlackHeader: Bool) -> Self {
            Self(geometry: .resting(at: frame, expanded: expanded),
                 blackOpacity: hasBlackHeader && !expanded ? 1 : 0, finished: true)
        }
    }

    public let target: Sample
    public let hasBlackHeader: Bool
    private let opening: Bool
    private let initial: Sample
    private let shell: IslandMotion
    private let fadeOut: Fade?
    private var fadeIn: Fade?

    public init(from sample: Sample, to frame: CGRect, opening: Bool, hasBlackHeader: Bool, start: TimeInterval) {
        initial = sample
        self.opening = opening
        self.hasBlackHeader = hasBlackHeader
        target = .resting(at: frame, expanded: opening, hasBlackHeader: hasBlackHeader)
        let fadeOut = hasBlackHeader && opening && sample.blackOpacity > 0
            ? Fade(from: sample.blackOpacity, to: 0, start: start, duration: 0.10) : nil
        self.fadeOut = fadeOut
        shell = IslandMotion(from: sample.geometry, to: frame, opening: opening, start: fadeOut?.end ?? start)
        // Reversing during the opening fade never moved the shell, so the
        // backing can fade straight back in from its current opacity.
        if hasBlackHeader && !opening && Self.isVisuallyClosed(sample.geometry, at: frame) {
            fadeIn = Fade(from: sample.blackOpacity, to: 1, start: start, duration: 0.13)
        }
    }

    public mutating func sample(at time: TimeInterval) -> Sample {
        if let fadeOut, time < fadeOut.end {
            return Sample(geometry: initial.geometry, blackOpacity: fadeOut.value(at: time), finished: false)
        }
        let geometry = shell.sample(at: time)
        guard hasBlackHeader && !opening else {
            return Sample(geometry: geometry, blackOpacity: 0, finished: geometry.finished)
        }
        if fadeIn == nil, Self.isVisuallyClosed(geometry, at: target.frame) {
            // The integral window is already fully folded. Do not wait for the
            // invisible subpoint spring tail before beginning the backing fade.
            fadeIn = Fade(from: initial.blackOpacity, to: 1, start: time, duration: 0.13)
        }
        return Sample(geometry: geometry, blackOpacity: fadeIn?.value(at: time) ?? 0,
                      finished: geometry.finished && fadeIn.map { time >= $0.end } == true)
    }

    private static func isVisuallyClosed(_ geometry: IslandMotion.Sample, at frame: CGRect) -> Bool {
        geometry.content == 0 && IslandGeometry.windowFrame(geometry.frame) == frame
    }

    private struct Fade {
        let from: Double
        let to: Double
        let start: TimeInterval
        let duration: TimeInterval
        var end: TimeInterval { start + duration }

        init(from: Double, to: Double, start: TimeInterval, duration: TimeInterval) {
            self.from = from
            self.to = to
            self.start = start
            self.duration = duration * sqrt(abs(to - from))
        }

        func value(at time: TimeInterval) -> Double {
            guard duration > 0, time < end else { return to }
            let fraction = min(1, max(0, (time - start) / duration))
            let eased = fraction * fraction * (3 - 2 * fraction)
            return from + (to - from) * eased
        }
    }
}
