import Foundation

/// Follows the rollouts that Pacer's Codex hook names in its spool. The spool is
/// the only discovery: it says which threads have turns, which turns are open and
/// which wait for a permission. Rollout reads are bounded and keep no conversation text.
public actor LocalActivityReader {
    private struct Cursor {
        var offset: UInt64
        var fragment: Data
        var activity: SessionActivity
        var identity: String
        var parentCompletion: SessionActivity.SubagentEvidence?
        var gap: SessionActivity.CodexLogGap?
        var attention = CodexLogAttention()
    }
    private var cursors: [URL: Cursor] = [:]
    private var metadata: [URL: (identity: String, activity: SessionActivity)] = [:]
    /// Codex names a conversation seconds after it starts (11 s, seen 11/15)
    /// and reads while it runs are metrics-only, so names are reread from its
    /// index at most this often then too; discovery reads always reread them.
    static let titleRefreshInterval: TimeInterval = 5
    private var titlesReadAt: Date?
    private var originSizes: [URL: UInt64] = [:]
    private var ignoredIDs: Set<String> = []
    private var hooks = CodexHookState()
    /// How long a thread whose turn ended stays followed after its last hook row.
    static let recentWindow: TimeInterval = 30 * 60
    /// Request IDs for hook permission requests.
    static let approvalPrefix = "codex-hook-approval:"
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
    public func reset() { cursors.removeAll(); metadata.removeAll(); originSizes.removeAll(); ignoredIDs.removeAll(); hooks.reset(); nextRunningExpiry = nil }
    /// The next time a running cursor needs a read even if its file stays quiet.
    public private(set) var nextRunningExpiry: Date?
    /// The newest hook row, for telling a silent hook from an idle Codex.
    public var lastHookRow: Date? { hooks.lastRowAt }

    public func read(home: URL, now: Date = Date(), phaseAwareRate: Bool = false,
                     metricsOnly: Bool = false,
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
        var files: [(URL, Date)] = []
        var watchURLs: [URL] = []
        var watchedDirectories: Set<String> = []
        let manager = FileManager.default
        // A hook row can name a rollout no cursor follows yet; the spool's append is the only
        // event for it, so a metrics-only read that saw new rows discovers as well.
        let hooksChanged = hooks.read(home: home, now: now, retaining: recentlyActiveHookThreads(at: now)) { self.signature($0) }
        let metricsOnly = metricsOnly && !hooksChanged
        hooks.locateChildren(home: home, now: now) { folder in
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        // The spool folder shows its creation and rotation; the file itself shows appends.
        var spool = CodexHookSpool.folder(home: home), isDirectory: ObjCBool = false
        while !manager.fileExists(atPath: spool.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            if spool.path == home.path || spool.pathComponents.count <= 1 { break }
            spool.deleteLastPathComponent()
        }
        watchURLs.append(spool); watchedDirectories.insert(spool.path)
        if manager.fileExists(atPath: CodexHookSpool.current(home: home).path) { watchURLs.append(CodexHookSpool.current(home: home)) }
        if metricsOnly {
            files = cursors.keys.map { ($0, cursors[$0]?.activity.lastObserved ?? .distantPast) }
        } else {
            files = hooks.transcripts(now: now, recent: Self.recentWindow).map { ($0.url, $0.at) }
        }
        let titlesDue = titlesReadAt.map { now.timeIntervalSince($0) >= Self.titleRefreshInterval || $0 > now } ?? true
        let named = titlesDue && !(files.isEmpty && cursors.isEmpty) ? SessionIndex.entries(home: home) : []
        if titlesDue && !(files.isEmpty && cursors.isEmpty) { titlesReadAt = now }
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
        var selected = metricsOnly ? Array(cursors.keys) : cursors.filter {
            [.running, .waitingForInput].contains(projected($0.value).phase)
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
                    if let launch = latest.observedAt { activity.noteHostLaunch(at: launch) }
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
                guard let value = metadata[file]?.activity, !value.isInternalReview,
                      inherited[value.id]?.isIgnoredCodexSession != true, !selected.contains(file) else { continue }
                selected.append(file)
            }
            originSizes = originSizes.filter { metadata[$0.key] != nil }
        }
        if !metricsOnly { cursors = cursors.filter { selected.contains($0.key) } }
        for file in selected {
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
                if let entry = named.first(where: { $0.url == file }) { existing.activity.updateTitle(entry.title); existing.activity.updateParent(entry.parentThreadID); cursors[file] = existing }
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var cursor = cursors[file]
            let attaching = cursor.map { $0.offset > size || $0.identity != identity } ?? true
            if attaching {
                var activity = metadata[file]?.activity ?? SessionActivity(id: file.lastPathComponent, phaseAwareRate: phaseAwareRate)
                activity.setCodexRollout(file)
                if let anchor = latestTurnAnchor(handle: handle, size: size, threadID: activity.threadID) { activity.consume(anchor) }
                cursor = Cursor(offset: 0, fragment: Data(), activity: activity, identity: identity)
            }
            guard var current = cursor else { continue }
            var dropPartial = false
            let budget = current.offset == 0 ? startupBytes : maxBytes
            if size - current.offset > UInt64(budget) {
                // Skipping a large append need not lose the turn. When nothing appended
                // since the last read starts, ends or sets a turn, the known turn is
                // still current: keep it and read on. Otherwise, or with no turn known,
                // start over from an anchor, which a turn longer than the anchor search
                // (8 MiB) no longer has in reach.
                let sameTurn = !attaching && current.activity.turnID != nil && size - current.offset <= Self.boundaryScanLimit
                    && !holdsTurnBoundary(handle: handle, fragment: current.fragment, from: current.offset, to: size)
                if !sameTurn, current.gap == nil { current.gap = .init(previous: attaching ? nil : current.activity) }
                current.offset = size - UInt64(budget)
                current.fragment.removeAll()
                if !attaching { current.attention.reset() }
                if !attaching && !sameTurn {
                    current.activity.markDiscontinuity()
                    if let anchor = latestTurnAnchor(handle: handle, size: size, threadID: current.activity.threadID) { current.activity.consume(anchor) }
                }
                if current.activity.turnID != nil { current.gap = nil }
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
                        if let gap = current.gap { current.activity.recoverCodexEnding(value, after: gap, now: now) }
                        current.activity.consume(value)
                        if current.activity.turnID != nil { current.gap = nil }
                        current.attention.consume(value, activity: current.activity, now: now)
                    }
                    current.fragment.removeSubrange(...end)
                }
                if current.fragment.count > maxBytes { current.fragment.removeAll(); current.attention.reset() }
                if let entry = named.first(where: { $0.url == file }) { current.activity.updateTitle(entry.title); current.activity.updateParent(entry.parentThreadID) }
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
        // A turn runs while its log moves or its hook holds it open; a Codex that
        // crashed does neither. Every read checks, including a file that did not
        // change, so a turn already followed cannot run on forever.
        nextRunningExpiry = nil
        for (file, cursor) in cursors {
            let activity = closedBySessionEnd(projected(cursor))
            guard [.running, .waitingForInput].contains(activity.phase) else { continue }
            let logExpiry = (activity.lastObserved ?? .distantPast).addingTimeInterval(Self.quietLimit)
            let hookExpiry = openHookDate(for: activity)?.addingTimeInterval(Self.hookOpenLimit) ?? .distantPast
            let expiry = max(logExpiry, hookExpiry)
            if expiry <= now { cursors[file]?.activity.markUnconfirmed() }
            else { nextRunningExpiry = min(nextRunningExpiry ?? expiry, expiry) }
        }
        // Parent hints affect the published view and cursor selection, never
        // the log baseline. Withdrawing a running hint must work at unchanged
        // EOF, while explicitly observed endings remain independently known.
        let watched = selected.filter { metadata[$0]?.activity.isIgnoredCodexSession != true }
        for file in watched {
            let directory = file.deletingLastPathComponent()
            if watchedDirectories.insert(directory.path).inserted { watchURLs.append(directory) }
        }
        let activities = CodexSessionOrigin.inheriting(cursors.values.map(projected) + unavailable)
            .filter { !$0.isInternalReview && !$0.isIgnoredCodexSession }.map(closedBySessionEnd)
            .sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) }
        // Questions follow the same closed state as their tasks.
        let requests = cursors.values.flatMap { $0.attention.requests(for: closedBySessionEnd(projected($0))) } + activities.compactMap { approval(for: $0) }
        return (activities,
                watchURLs + watched.sorted { (cursors[$0]?.activity.lastObserved ?? .distantPast) > (cursors[$1]?.activity.lastObserved ?? .distantPast) }, ignoredIDs,
                requests.filter { !ignoredIDs.contains($0.activity.id) })
    }

    /// How long a turn the hook opened counts as running without any word in its log;
    /// a Codex that crashed sends no Stop or SessionEnd.
    static let hookOpenLimit: TimeInterval = 3 * 60 * 60
    /// How long a running turn's log may stay quiet before only its hook can keep it running.
    static let quietLimit: TimeInterval = 15 * 60

    private func openHookDate(for activity: SessionActivity) -> Date? {
        guard let thread = activity.threadID else { return nil }
        if let state = hooks.threads[thread] {
            guard let turn = activity.turnID, state.openTurn == turn else { return nil }
            return state.lastAt
        }
        // A subagent runs within its parent's turn until SubagentStop.
        guard let child = hooks.children[thread], child.stoppedAt == nil,
              let parent = hooks.threads[child.parent], parent.openTurn != nil else { return nil }
        return max(parent.lastAt, child.startedAt)
    }

    private func recentlyActiveHookThreads(at now: Date) -> Set<String> {
        Set(cursors.values.compactMap { cursor in
            let value = cursor.activity
            guard [.running, .waitingForInput].contains(value.phase), openHookDate(for: value) != nil,
                  now.timeIntervalSince(value.lastObserved ?? .distantPast) < Self.quietLimit else { return nil }
            return value.threadID
        })
    }

    /// What `CodexHookStatus.evaluate` needs to tell a silent hook from a long turn:
    /// the newest hook row, and the newest rollout change in today's or yesterday's
    /// folder that no turn the hooks hold open explains. An open turn keeps writing
    /// its own and its subagents' rollouts with no other hook event; a turn Codex ran
    /// without the hooks writes another rollout, or one whose turn had ended.
    public func hookEvidence(home: URL, now: Date = Date()) async -> (lastHookEvent: Date?, lastCodexTurn: Date?) {
        let explained = hooks.openThreads(now: now, limit: Self.hookOpenLimit).union(recentlyActiveHookThreads(at: now))
        let last = hooks.lastRowAt
        let turn = await Task.detached(priority: .utility) {
            CodexHookSpool.latestRollout(home: home, now: now, excludingThreads: explained)
        }.value
        return (last, turn)
    }

    /// Codex closed the thread (usually by quitting) after the log's last word on
    /// a turn it never ended: that turn can no longer be confirmed as running.
    private func closedBySessionEnd(_ activity: SessionActivity) -> SessionActivity {
        guard let thread = activity.threadID, let ended = hooks.threads[thread]?.endedAt,
              [.running, .waitingForInput].contains(activity.phase), (activity.lastObserved ?? .distantPast) <= ended else { return activity }
        var value = activity; value.markUnconfirmed(); return value
    }

    /// A permission request waits until its turn's log moves past it or the turn ends.
    /// Codex fires the hook for a turn whose approvals its own reviewer takes too;
    /// nothing waits for the user there, so nothing shows.
    private func approval(for activity: SessionActivity) -> PendingAttentionRequest? {
        guard let thread = activity.threadID, activity.parentThreadID == nil, !activity.codexReviewsApprovals,
              let request = hooks.threads[thread]?.approval,
              [.running, .waitingForInput].contains(activity.phase),
              request.turn == nil || activity.turnID == nil || request.turn == activity.turnID,
              (activity.lastObserved ?? .distantPast) <= request.at else { return nil }
        return PendingAttentionRequest(id: Self.approvalPrefix + thread + ":" + (request.turn ?? ""), threadID: thread, sourceHostID: nil,
                                       sourceName: nil, kind: .approval, detectedAt: request.at)
    }
    /// The most unread log a skip still checks for turn boundaries; more falls back to an anchor.
    static let boundaryScanLimit: UInt64 = 8 * 1024 * 1024
    /// The records' own type fields. Inside a tool's output the same words
    /// appear with escaped quotes, so text that mentions them is no boundary.
    private static let turnBoundaries = ["task_started", "task_complete", "turn_aborted", "turn_context"].flatMap { kind in
        [#""type":"\#(kind)""#, #""type": "\#(kind)""#].map { Data($0.utf8) }
    }
    /// Whether the unread `fragment` and the file's `from..<to` hold a turn start,
    /// ending or context. Compares bytes in 1 MiB steps without parsing; an
    /// unreadable step counts as a boundary.
    private func holdsTurnBoundary(handle: FileHandle, fragment: Data, from: UInt64, to: UInt64) -> Bool {
        let overlap = (Self.turnBoundaries.map(\.count).max() ?? 1) - 1
        func found(_ data: Data) -> Bool { Self.turnBoundaries.contains { data.range(of: $0) != nil } }
        if found(fragment) { return true }
        var carry = Data(fragment.suffix(overlap)), offset = from
        while offset < to {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(min(1 << 20, to - offset))), !chunk.isEmpty else { return true }
            let data = carry + chunk
            if found(data) { return true }
            carry = Data(data.suffix(overlap)); offset += UInt64(chunk.count)
        }
        return false
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
