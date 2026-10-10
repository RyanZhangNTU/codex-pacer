import SwiftUI
import PacerCore

/// Display-frame updates must not invalidate the activity model, task rows,
/// settings, or charts. Only the shell observes this presentation state.
@MainActor
final class IslandPresentation: ObservableObject {
    @Published var sample = IslandTransition.Sample.resting(at: .zero, expanded: false, hasBlackHeader: false)
    @Published var canvas = CGSize(width: IslandWidthSettings.expandedRange.lowerBound, height: 510)

    var expansion: Double { min(1, max(0, sample.expansion)) }
    var contentVisibility: Double { sample.content }
    var blackOpacity: Double { sample.blackOpacity }
}
