import Foundation

public enum ActivitySourceMerger {
    public static func merge(logged: [SessionActivity], streamed: [SessionActivity]) -> [SessionActivity] {
        var result = Dictionary(logged.map { ($0.canonicalized().id, $0.canonicalized()) }, uniquingKeysWith: { old, new in
            (new.lastObserved ?? .distantPast) >= (old.lastObserved ?? .distantPast) ? new : old
        })
        for item in streamed {
            let value = item.canonicalized()
            guard !value.isInternalReview else { continue }
            if value.phase == .unknown, let previous = result[value.id], previous.turnID == value.turnID,
               [.completed, .interrupted].contains(previous.phase) { continue }
            if let previous = result[value.id], value.hasLiveEvidence {
                if previous.turnID != value.turnID && (!value.liveTurnStarted ||
                    (previous.phaseChangedAt ?? .distantPast) > (value.phaseChangedAt ?? .distantPast)) { continue }
                if [.completed, .interrupted].contains(previous.phase),
                   (previous.phaseChangedAt ?? .distantPast) > (value.lastObserved ?? .distantPast) { continue }
            } else if let previous = result[value.id],
                      (previous.lastObserved ?? .distantPast) > (value.lastObserved ?? .distantPast) { continue }
            result[value.id] = value
        }
        return result.values.filter { !$0.isInternalReview }
    }
}
