import Foundation

/// Reads recent files and resumed sessions from the read-only Codex index.
/// Startup and catch-up reads are bounded; conversation text is never retained.
public actor LocalActivityReader {
    private struct Cursor {
        var offset: UInt64
        var fragment: Data
        var activity: SessionActivity
        var identity: String
        var parentCompletion: SessionActivity.SubagentEvidence?
        var attention = CodexLogAttention()
    }
    private var cursors: [URL: Cursor] = [:]
    private var metadata: [URL: (identity: String, activity: SessionActivity)] = [:]
    private var originSizes: [URL: UInt64] = [:]
    private var ignoredIDs: Set<String> = []
    private let maxFiles = 16
    private let maxBytes = 128 * 1024
    private let startupBytes = 512 * 1024

    private let fileMetadata: (@Sendable (URL) -> PlatformFileMetadata?)?
    public init(fileMetadata: (@Sendable (URL) -> PlatformFileMetadata?)? = nil) { self.fileMetadata = fileMetadata }
    private func signature(_ url: URL) -> (identity: String, size: UInt64)? {
        if let fileMetadata { return fileMetadata(url).map { ($0.identity, $0.size) } }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return (String((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0), size)
    }
    public func reset() { cursors.removeAll(); metadata.removeAll(); originSizes.removeAll(); ignoredIDs.removeAll() }

    public func read(home: URL, now: Date = Date(), phaseAwareRate: Bool = false,
                     excludingThreads: Set<String> = [], includeCoveredMetrics: Bool = false, metricsOnly: Bool = false,
                     subagentStates: [String: SessionActivity.SubagentEvidence] = [:]) -> (activities: [SessionActivity], watchURLs: [URL], excludedIDs: Set<String>, requests: [PendingAttentionRequest]) {
        func retainingCompletion(_ cursor: Cursor) -> Cursor {
            var value = cursor
            if let id = value.activity.threadID, let evidence = subagentStates[id], evidence.state == "completed",
               value.parentCompletion.map({ evidence.observedAt > $0.observedAt }) ?? true {
                value.parentCompletion = evidence
            }
            return value
        }
        func projected(_ cursor: Cursor) -> SessionActivity {
            var value = cursor.activity
            // A confirmed ending survives the parent's subscription being
            // released. A new child turn rejects this older ending normally.
            if let completion = cursor.parentCompletion { value.applySubagentEvidence(completion) }
            if let id = value.threadID, let evidence = subagentStates[id] { value.applySubagentEvidence(evidence) }
            return value
        }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)!]
        var files: [(URL, Date)] = []
        var watchURLs: [URL] = []
        let manager = FileManager.default
        if !metricsOnly { for day in days {
            let directory = home.appendingPathComponent("sessions/\(formatter.string(from: day))")
            var existing = directory
            while !manager.fileExists(atPath: existing.path), existing.path != home.path {
                existing.deleteLastPathComponent()
            }
            if manager.fileExists(atPath: existing.path) { watchURLs.append(existing) }
            let entries = (try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((file, date))
            }
        }
        } else {
            files = cursors.keys.map { ($0, cursors[$0]?.activity.lastObserved ?? .distantPast) }
        }
        let indexed = metricsOnly ? [] : SessionIndex.entries(home: home)
        for entry in indexed {
            let file = entry.url
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if !files.contains(where: { $0.0 == file }) { files.append((file, date)) }
        }
        for file in Array(cursors.keys) {
            if let cursor = cursors[file] { cursors[file] = retainingCompletion(cursor) }
        }
        var unavailable: [SessionActivity] = []
        for (file, cursor) in cursors where !manager.isReadableFile(atPath: file.path) {
            var activity = projected(cursor)
            if ![.completed, .interrupted].contains(activity.phase) { activity.markUnconfirmed() }
            unavailable.append(activity)
            cursors.removeValue(forKey: file)
            metadata.removeValue(forKey: file)
        }
        for (file, cursor) in cursors where [.running, .waitingForInput].contains(projected(cursor).phase) && !files.contains(where: { $0.0 == file }) {
            files.append((file, cursor.activity.lastObserved ?? .distantPast))
        }
        // Reviews must not consume the user-task discovery slots.
        func covered(_ file: URL) -> Bool {
            excludingThreads.contains(String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased())
        }
        var selected = metricsOnly ? Array(cursors.keys) : cursors.filter {
            [.running, .waitingForInput].contains(projected($0.value).phase) && !covered($0.key)
        }.map(\.key)
        let candidates = Array(files.sorted { $0.1 > $1.1 }.prefix(256).map(\.0))
        metadata = metadata.filter { candidates.contains($0.key) }
        if !metricsOnly { for file in candidates {
            let facts = signature(file)
            let identity = facts?.identity ?? "0", size = facts?.size ?? 0
            if metadata[file]?.identity != identity || (metadata[file]?.activity.isIgnoredCodexSession == true && originSizes[file] != size) {
                var activity = SessionActivity(id: file.lastPathComponent, phaseAwareRate: phaseAwareRate)
                activity.setCodexRollout(file)
                var header: Data?
                if let handle = try? FileHandle(forReadingFrom: file) {
                    defer { try? handle.close() }
                    // Session metadata can include a long instruction block.
                    var head = Data()
                    while head.count < 1024 * 1024 {
                        guard let chunk = try? handle.read(upToCount: 32768), !chunk.isEmpty else { break }
                        head.append(chunk)
                        if let end = head.firstIndex(of: 10) { activity.consume(head.prefix(upTo: end)); break }
                    }
                    header = head
                }
                if let latest = CodexRolloutMetadata.read(file, threadID: activity.threadID, head: header) {
                    activity.setCodexOrigin(latest.origin, at: latest.observedAt)
                }
                metadata[file] = (identity, activity)
                originSizes[file] = size
            }
        }
            let inherited = Dictionary(CodexSessionOrigin.inheriting(candidates.compactMap { metadata[$0]?.activity })
                .map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            ignoredIDs = Set(inherited.values.filter(\.isIgnoredCodexSession).map { $0.canonicalized().id })
            selected.removeAll { file in metadata[file].flatMap { inherited[$0.activity.id] }?.isIgnoredCodexSession == true }
            for file in candidates {
                guard selected.count < maxFiles else { break }
                guard !covered(file), let value = metadata[file]?.activity, !value.isInternalReview,
                      inherited[value.id]?.isIgnoredCodexSession != true, !selected.contains(file) else { continue }
                selected.append(file)
            }
            originSizes = originSizes.filter { metadata[$0.key] != nil }
        }
        // Keep covered baselines for reconnects without spending fallback slots.
        if includeCoveredMetrics && !metricsOnly {
            let metricFiles = candidates.filter { covered($0) && metadata[$0]?.activity.isIgnoredCodexSession != true }.prefix(32)
            selected += metricFiles.filter { !selected.contains($0) }
        }
        if !metricsOnly { cursors = cursors.filter { selected.contains($0.key) || covered($0.key) } }
        for file in selected {
            let id = String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
            if excludingThreads.contains(id), !includeCoveredMetrics { continue }
            guard let facts = signature(file) else {
                if let cursor = cursors.removeValue(forKey: file) {
                    var activity = projected(cursor)
                    if ![.completed, .interrupted].contains(activity.phase) { activity.markUnconfirmed() }
                    unavailable.append(activity)
                }
                metadata.removeValue(forKey: file)
                continue
            }
            let identity = facts.identity, size = facts.size
            if var existing = cursors[file], existing.identity == identity, existing.offset == size {
                if let entry = indexed.first(where: { $0.url == file }) { existing.activity.updateTitle(entry.title); existing.activity.updateParent(entry.parentThreadID); cursors[file] = existing }
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var cursor = cursors[file]
            if cursor == nil || cursor!.offset > size || cursor!.identity != identity {
                var activity = metadata[file]?.activity ?? SessionActivity(id: file.lastPathComponent, phaseAwareRate: phaseAwareRate)
                if let anchor = latestTurnAnchor(handle: handle, size: size, threadID: activity.threadID) { activity.consume(anchor) }
                cursor = Cursor(offset: 0, fragment: Data(), activity: activity, identity: identity)
            }
            guard var current = cursor else { continue }
            var dropPartial = false
            let budget = current.offset == 0 ? startupBytes : maxBytes
            if size - current.offset > UInt64(budget) {
                current.offset = size - UInt64(budget)
                current.fragment.removeAll()
                if cursors[file] != nil {
                    current.activity.markDiscontinuity()
                    current.attention.reset()
                    if let anchor = latestTurnAnchor(handle: handle, size: size, threadID: current.activity.threadID) { current.activity.consume(anchor) }
                }
                dropPartial = true
                current.activity.markPartialRate()
            }
            do {
                try handle.seek(toOffset: current.offset)
                let data = try handle.read(upToCount: budget) ?? Data()
                current.offset += UInt64(data.count)
                current.fragment.append(data)
                if dropPartial, let end = current.fragment.firstIndex(of: 10) {
                    current.fragment.removeSubrange(...end)
                }
                while let end = current.fragment.firstIndex(of: 10) {
                    if let value = try? JSONSerialization.jsonObject(with: current.fragment.prefix(upTo: end)) as? [String: Any] {
                        current.activity.consume(value)
                        current.attention.consume(value, activity: current.activity, now: now)
                    }
                    current.fragment.removeSubrange(...end)
                }
                if current.fragment.count > maxBytes { current.fragment.removeAll(); current.attention.reset() }
                if let entry = indexed.first(where: { $0.url == file }) { current.activity.updateTitle(entry.title); current.activity.updateParent(entry.parentThreadID) }
                if cursors[file] == nil, [.running, .waitingForInput].contains(current.activity.phase),
                   now.timeIntervalSince(current.activity.lastObserved ?? .distantPast) > 900 { current.activity.markUnconfirmed() }
                if current.activity.isInternalReview || current.activity.isIgnoredCodexSession {
                    if current.activity.isIgnoredCodexSession { ignoredIDs.insert(current.activity.canonicalized().id) }
                    metadata[file] = (identity, current.activity)
                    cursors.removeValue(forKey: file)
                } else { cursors[file] = retainingCompletion(current) }
            } catch {
                var activity = projected(retainingCompletion(current))
                if ![.completed, .interrupted].contains(activity.phase) { activity.markUnconfirmed() }
                unavailable.append(activity)
                cursors.removeValue(forKey: file)
                metadata.removeValue(forKey: file)
            }
        }
        // Parent hints affect the published view and cursor selection, never
        // the log baseline. Withdrawing a running hint must work at unchanged
        // EOF, while explicitly observed endings remain independently known.
        let watched = selected.filter { metadata[$0]?.activity.isIgnoredCodexSession != true }
        watchURLs += watched.map { $0.deletingLastPathComponent() }
        return (CodexSessionOrigin.inheriting(cursors.values.map(projected) + unavailable).filter { !$0.isInternalReview && !$0.isIgnoredCodexSession }.sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) },
                watchURLs + watched.sorted { (cursors[$0]?.activity.lastObserved ?? .distantPast) > (cursors[$1]?.activity.lastObserved ?? .distantPast) }, ignoredIDs,
                cursors.values.flatMap { $0.attention.requests(for: projected($0)) }.filter { !ignoredIDs.contains($0.activity.id) })
    }
    /// Recover the latest explicit turn anchor without loading conversation history.
    /// Scan the existing 8 MiB budget; retain one anchor and numeric first-output times.
    private func latestTurnAnchor(handle: FileHandle, size: UInt64, threadID: String?) -> Data? {
        var offset = size
        let floor = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
        var fragment = Data()
        var fallback: Data?
        var latestTurn: String?
        var firstTimes: [String: Double] = [:]
        while offset > floor {
            let start = max(floor, offset > 128 * 1024 ? offset - 128 * 1024 : 0)
            do {
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: Int(offset - start)) ?? Data()
                data.append(fragment)
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropFirst().reversed() {
                    guard line.count <= 1024 * 1024,
                          line.range(of: Data("turn_context".utf8)) != nil || line.range(of: Data("task_started".utf8)) != nil || line.range(of: Data("item_completed".utf8)) != nil,
                          var value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          var payload = value["payload"] as? [String: Any], let turn = payload["turn_id"] as? String else { continue }
                    if value["type"] as? String == "event_msg", payload["type"] as? String == "item_completed",
                       payload["thread_id"] as? String == threadID, let ms = SessionActivity.loggedFirstOutput(payload), ms.isFinite,
                       let stamp = value["timestamp"] as? String, let reported = SessionActivity.parseDate(stamp),
                       ms / 1000 <= reported.timeIntervalSince1970,
                       firstTimes[turn] != nil || firstTimes.count < 64 {
                        firstTimes[turn] = min(firstTimes[turn] ?? ms, ms)
                    } else if value["type"] as? String == "turn_context", fallback == nil {
                        fallback = Data(line); latestTurn = turn
                    } else if value["type"] as? String == "event_msg", payload["type"] as? String == "task_started",
                              latestTurn == nil || latestTurn == turn {
                        if let fallback, let context = (try? JSONSerialization.jsonObject(with: fallback) as? [String: Any])?["payload"] as? [String: Any],
                           context["turn_id"] as? String == turn, let model = ModelDisplay.sanitizedModel(context["model"]) {
                            var recovered: [String: Any] = ["model": model]
                            if let effort = context["effort"] { recovered["effort"] = (ModelDisplay.sanitizedEffort(effort) as Any?) ?? NSNull() }
                            payload["_model_context"] = recovered
                            value["payload"] = payload
                        }
                        if let ms = firstTimes[turn], let stamp = value["timestamp"] as? String,
                           let began = SessionActivity.parseDate(stamp) {
                            let duration = ms - began.timeIntervalSince1970 * 1000
                            if duration >= 0, duration <= 3_600_000 { payload["first_output_latency_ms"] = duration; value["payload"] = payload }
                        }
                        return try? JSONSerialization.data(withJSONObject: value)
                    }
                }
                fragment = lines.first.map { Data($0) } ?? Data()
                if fragment.count > 1024 * 1024 { fragment.removeAll() }
                offset = start
            } catch { return nil }
        }
        return fallback
    }

}
