import Foundation

enum AntigravityHarness {
    static let definition = LocalHarnessDefinition(descriptor: .init(id: .antigravity, name: "Antigravity", symbol: "a.circle",
        brand: .init(dark: .init(0xA5CAFF), light: .init(0x285CAD), accentLift: 0.32, accentLuminance: 0.105),
        website: URL(string: "https://antigravity.google/"), balance: .quotaWindows, hasRateDisplay: true),
        platforms: [.macOS], home: ".gemini/antigravity", dataFile: "conversation_summaries.db", windowsExecutables: [],
        macApplicationNames: ["Antigravity"], macBundleIdentifiers: ["com.google.antigravity"], macTeamIdentifier: "EQHXZ8M8AV",
        makeMonitor: { AntigravityMonitor(io: $0) })
}

package protocol AntigravityHubSource: Sendable {
    func observeHub(_ observer: @escaping @Sendable (AntigravityLocalClient, UInt64?) async -> Void) async
}

actor AntigravityMonitor: LocalHarnessMonitor, AntigravityHubSource {
    private var hubObserver: (@Sendable (AntigravityLocalClient, UInt64?) async -> Void)?
    func observeHub(_ observer: @escaping @Sendable (AntigravityLocalClient, UInt64?) async -> Void) {
        hubObserver = observer
    }

    private struct Cached {
        var trajectory: AntigravityStore.Trajectory?
        var transcript = AntigravityTranscript()
        var metadata = AntigravityProjection.Enrichment()
        var stamps: [PlatformFileMetadata?] = []
        var summary: AntigravityStore.Summary?
        var turn: AntigravityProjection.Turn?
        var witnessed: String?
        var lastInspection: UInt64 = 0
        var gap: Date?
    }

    private let io: LocalHarnessIO
    private var store: AntigravityStore?
    private var client: AntigravityLocalClient?
    private var watcher: ActivityLogWatcher?
    private var urls: [URL] = []
    private var retry: Task<Void, Never>?
    private var publish: (@Sendable (HarnessActivity) async -> Void)?
    private var generation: UInt64 = 0
    private var reading = false, dirty = false
    private var needsRecheck = false
    private var policy = ActivityRefreshPolicy.collapsed
    private var cache: [String: Cached] = [:]
    private var watermark: Date?
    private var hubGeneration: UInt64?
    private var pass: UInt64 = 0
    private var previous: HarnessActivity?

    init(io: LocalHarnessIO) { self.io = io }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        let old = reset()
        let current = generation
        await old?.revoke()
        guard generation == current else { return }
        let store = AntigravityStore(home: home, files: io.files)
        self.store = store; self.policy = policy; self.publish = publish
        client = AntigravityLocalClient(home: home, io: io)
        let watcher = ActivityLogWatcher(files: io.files, events: io.events, interval: 0.15, fileExtensions: nil) { [weak self] _ in
            Task { await self?.refresh(ifCurrent: current) }
        }
        self.watcher = watcher
        urls = baseURLs(store)
        watcher.update(urls, interval: 0.15)
        _ = await watcher.activeWatchCount()
        await refresh(ifCurrent: current)
    }

    private func baseURLs(_ store: AntigravityStore) -> [URL] {
        var directory = store.home
        while io.files.metadata(directory)?.isDirectory != true {
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path || parent.path.isEmpty { break }
            directory = parent
        }
        return [directory, store.home.appendingPathComponent("daemon"), store.summariesURL, sidecar(store.summariesURL)]
    }

    private func sidecar(_ url: URL) -> URL { URL(fileURLWithPath: url.path + "-wal") }

    private func reset() -> AntigravityLocalClient? {
        generation &+= 1; reading = false; dirty = false
        watcher?.stop(); watcher = nil; retry?.cancel(); retry = nil
        store = nil; publish = nil; cache = [:]; previous = nil; watermark = nil; hubGeneration = nil
        defer { client = nil }
        return client
    }
    func stop() async { await reset()?.revoke() }
    func updatePolicy(_ policy: ActivityRefreshPolicy) async {
        guard policy != self.policy else { return }
        self.policy = policy
        await refresh()
    }
    private func refresh(ifCurrent current: UInt64) async {
        if current == generation { await refresh() }
    }
    func refresh() async {
        guard let store, let client, let publish else { return }
        if reading {
            dirty = true
            // A daemon event may rotate the credentials while an earlier HTTP call is suspended.
            _ = await client.discover()
            return
        }
        reading = true
        let current = generation
        var attempts = 0, rechecked = false
        repeat {
            attempts += 1
            dirty = false
            needsRecheck = false
            let observation = await reconcile(store, client: client, generation: current, rechecking: rechecked)
            guard current == generation else { return }
            if needsRecheck && !rechecked {
                rechecked = true
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard current == generation else { return }
                continue
            }
            if let observation, !dirty, observation != previous { previous = observation; await publish(observation) }
            guard current == generation else { return }
            if !dirty || attempts >= 3 { break }
        } while true
        reading = false
        retry?.cancel()
        let active = previous?.activities.contains { [.running, .waitingForInput].contains($0.phase) } == true ||
            cache.values.contains { $0.summary?.running == true || $0.summary?.background == true }
        let seconds = dirty ? 0.15 : needsRecheck ? 0.5 : active ? policy.interval : 60
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) } catch { return }
            await self?.refresh(ifCurrent: current)
        }
    }

    private func reconcile(_ store: AntigravityStore, client: AntigravityLocalClient, generation current: UInt64, rechecking: Bool) async -> HarnessActivity? {
        let session = await client.discover()
        guard current == generation else { return nil }
        if session != hubGeneration {
            watermark = nil
            for key in cache.keys { cache[key]?.metadata = .init(); cache[key]?.witnessed = nil; cache[key]?.gap = nil }
            hubGeneration = session
            await hubObserver?(client, session)
            guard current == generation else { return nil }
        }
        let summaryFiles = [store.summariesURL, sidecar(store.summariesURL)]
        let summaryStamps = summaryFiles.map { io.files.metadata($0) }
        let rows: [AntigravityStore.Summary]
        do { rows = try store.summaries() }
        catch {
            if error as? AntigravityStore.Failure == .retrySoon {
                needsRecheck = true
                if !rechecking { return nil }
            }
            watermark = nil; cache = [:]
            var value = HarnessActivity(status: .unavailable)
            if let failure = error as? AntigravityStore.Failure {
                switch failure { case .missing: value.status = .missing; case .incompatible: value.status = .incompatible; default: break }
            }
            value.activities = previous?.activities.map { old in
                var row = old
                if [.running, .waitingForInput].contains(row.phase) { row.markSourceUnavailable() }
                return row
            } ?? []
            urls = baseURLs(store); watcher?.update(urls, interval: 0.15)
            return value
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Park orphans, cycles and paths deeper than the grouping layer can resolve.
        func ancestors(_ row: AntigravityStore.Summary) -> [String]? {
            var path: [String] = [], item = row
            while let parent = item.parent {
                guard path.count < 63, parent != row.id, !path.contains(parent), let next = byID[parent] else { return nil }
                path.append(parent); item = next
            }
            return item.depth == 0 ? path : nil
        }
        var family = [(AntigravityStore.Summary, [String])]()
        for row in byID.values { if let parents = ancestors(row) { family.append((row, parents)) } }
        // Read children first so an idle parent cannot end before its owned descendants.
        family.sort { $0.1.count == $1.1.count ? $0.0.id < $1.0.id : $0.1.count > $1.1.count }
        var next: [String: Cached] = [:], activeParents = Set<String>(), watched = baseURLs(store)
        pass &+= 1
        var hot = [AntigravityStore.Summary]()
        for (row, _) in family {
            var item = cache[row.id] ?? Cached()
            let db = store.conversationURL(row.id)
            let stamps = [db, sidecar(db), URL(fileURLWithPath: db.path + "-shm")].map { io.files.metadata($0) }
            let filesChanged = item.stamps != stamps
            let changed = row != item.summary || filesChanged
            if changed || item.trajectory == nil || rechecking {
                let trajectory: AntigravityStore.Trajectory?
                do { trajectory = try store.trajectory(row) }
                catch {
                    trajectory = nil
                    if error as? AntigravityStore.Failure == .retrySoon { needsRecheck = true }
                }
                if item.trajectory?.id != trajectory?.id || item.trajectory?.anchor?.index != trajectory?.anchor?.index ||
                    item.trajectory?.anchor?.type != trajectory?.anchor?.type ||
                    (trajectory?.last?.index ?? -1) < (item.trajectory?.last?.index ?? -1) ||
                    item.stamps.first.flatMap({ $0?.identity }) != stamps[0]?.identity {
                    item.metadata = .init(); item.transcript = .init(); item.witnessed = nil; item.turn = nil
                }
                item.trajectory = trajectory
            }
            let open = item.trajectory?.unresolved.isEmpty == false
            // An idle summary can lag an input or a completed tool before the next
            // planner is written. Historical completed planners need no API poll.
            let lacksEnding = item.trajectory?.last.map { $0.status != 6 && !($0.type == 15 && $0.status == 3) } ?? false
            let settled = item.trajectory?.tail.last { $0.type == 15 && AntigravityProjection.Status(database: $0.status)?.settled == true }
            let needsFinalCall = watermark.map { row.updated > $0 } == true &&
                settled.map { $0.index != item.metadata.fetchedPlanner } == true
            if needsFinalCall || row.running || row.background || open || lacksEnding || item.metadata.runState == .running ||
                (filesChanged && item.summary != nil) ||
                item.metadata.conflictingState || (changed && (item.summary?.running == true || item.summary?.background == true)) {
                hot.append(row)
            }
            if changed || session == nil { item.metadata.fresh = false; item.metadata.runState = nil }
            item.stamps = stamps; item.summary = row
            next[row.id] = item
        }
        hot.sort { lhs, rhs in
            let a = next[lhs.id]?.lastInspection ?? 0, b = next[rhs.id]?.lastInspection ?? 0
            return a == b ? lhs.updated > rhs.updated : a < b
        }
        let selected = Set(hot.prefix(16).map(\.id))
        let prior = Dictionary(uniqueKeysWithValues: (previous?.activities ?? []).map { ($0.threadID ?? $0.id, $0) })
        var childEnd: [String: Date] = [:], unconfirmedParents = Set<String>()
        var value = HarnessActivity(status: .ready)
        let scope = CompletionDismissalStore.digest(["antigravity-home", store.home.standardizedFileURL.path])
        value.scope = scope
        for (row, parents) in family {
            guard var item = next[row.id] else { continue }
            let db = store.conversationURL(row.id), wal = sidecar(db), log = store.transcriptURL(row.id)
            if [store.home.appendingPathComponent("brain"), store.home.appendingPathComponent("brain/\(row.id)"),
                log.deletingLastPathComponent().deletingLastPathComponent(), log.deletingLastPathComponent()]
                .allSatisfy({ io.files.metadata($0)?.isDirectory == true }) {
                item.transcript.read(log, files: io.files)
            } else { item.transcript = .init() }
            if selected.contains(row.id) { watched += [db, wal, log] }
            if let session, selected.contains(row.id), let trajectory = item.trajectory, let id = UUID(uuidString: row.id) {
                item.lastInspection = pass
                await enrich(&item.metadata, row: row, trajectory: trajectory, id: id,
                             root: parents.last ?? row.id, client: client, session: session)
                guard current == generation else { return nil }
                if [db, wal, URL(fileURLWithPath: db.path + "-shm")].map({ io.files.metadata($0) }) != item.stamps { dirty = true; return nil }
            }
            let latestPlanner = item.trajectory?.tail.last { $0.type == 15 && $0.status == 3 }?.index ?? item.metadata.planner?.index
            if let session, let id = latestPlanner.flatMap({ item.transcript.records[$0]?.model }) ?? item.metadata.call?.modelID {
                item.metadata.catalog = await client.modelCatalog(for: id, session: session)
                guard current == generation else { return nil }
            }
            if item.metadata.conflictingState { needsRecheck = true }
            if item.metadata.conflictingFamily { next[row.id] = item; continue }
            let result = AntigravityProjection.project(row, trajectory: item.trajectory, transcript: item.transcript, live: item.metadata,
                dependent: activeParents.contains(row.id), unconfirmedDependent: unconfirmedParents.contains(row.id),
                watermark: item.gap ?? watermark, turnCache: &item.turn, witnessed: item.witnessed, previous: prior[row.id],
                dependentEnded: childEnd[row.id], scope: scope)
            if result.needsRecheck { needsRecheck = true }
            if [.running, .waitingForInput].contains(result.activity.phase) {
                activeParents.formUnion(parents); item.witnessed = result.activity.turnID
            } else if result.activity.phase == .unknown {
                if row.running || row.background || unconfirmedParents.contains(row.id) { unconfirmedParents.formUnion(parents) }
                item.witnessed = nil; item.gap = io.now()
            } else if let ended = result.activity.phaseChangedAt {
                for parent in parents { childEnd[parent] = max(childEnd[parent] ?? ended, ended) }
            }
            next[row.id] = item
            value.activities.append(result.activity)
            if let request = result.request { value.requests.append(request) }
        }
        if let session {
            guard await client.discover() == session else { if current == generation { dirty = true }; return nil }
            guard current == generation else { return nil }
        }
        // SQL and Connect are independent snapshots. Reconcile a changed request
        // before publishing, including when no server was available for the pass.
        if summaryFiles.map({ io.files.metadata($0) }) != summaryStamps, (try? store.summaries()) != rows {
            dirty = true; return nil
        }
        guard !dirty, !needsRecheck || rechecking else { return nil }
        let visible = Set(value.activities.compactMap(\.threadID))
        let orphans = Set(family.compactMap { row, parents in parents.contains(where: { !visible.contains($0) }) ? row.id : nil })
        value.activities.removeAll { $0.threadID.map(orphans.contains) == true }
        value.requests.removeAll { orphans.contains($0.threadID) }
        cache = next; urls = watched; watcher?.update(urls, interval: 0.15)
        if watermark == nil { watermark = io.now() }
        return value
    }

    private func enrich(_ live: inout AntigravityProjection.Enrichment, row: AntigravityStore.Summary,
                        trajectory: AntigravityStore.Trajectory, id: UUID, root: String,
                        client: AntigravityLocalClient, session: UInt64) async {
        guard let offset = trajectory.tail.first?.index else { return }
        live.fresh = false
        live.runState = nil
        do {
            do {
                let data = try await client.call(.conversation(id), generation: session)
                let envelope = try JSONFieldView.document(data)
                let record = try (envelope.fields(["conversation"])["conversation"] ?? envelope).fields(["id", "state"])
                guard AntigravityStore.uuid(record["id"]?.string()) == row.id else { live.conflictingState = true; return }
                let state = try record["state"]?.fields(["runState", "updateTime"])
                live.runState = AntigravityStore.RunState(state?["runState"]?.string(), prefix: "RUN_STATE_")
                if let date = AntigravityStore.date(state?["updateTime"]?.string()) { live.updated = date }
            } catch AntigravityLocalClient.Failure.unsupported { }
            let data = try await client.call(.steps(id, offset: offset), generation: session)
            live.conflictingState = true
            var steps = try AntigravityProjection.typedSteps(data, offset: offset, cascade: row.id, trajectory: trajectory.id)
            guard steps.count == trajectory.tail.count else { return }
            for index in steps.indices {
                let local = trajectory.tail[index]
                guard steps[index].index == local.index, steps[index].type == local.type else { return }
                if steps[index].status == nil { steps[index].status = AntigravityProjection.Status(database: local.status) }
            }
            live.steps = Dictionary(uniqueKeysWithValues: steps.map { ($0.index, $0) })
            live.conflictingState = false
            live.fresh = true
            if let first = trajectory.firstPlanner, let visible = live.steps[first]?.viewable { live.firstViewable = visible }
            let settled = steps.filter { $0.type == 15 && $0.status?.settled == true }
            if let planner = settled.last {
                live.planner = planner
                if live.fetchedPlanner != planner.index {
                    do {
                        let data = try await client.call(.generators(id), generation: session)
                        let calls = try AntigravityProjection.calls(data, planners: settled)
                        live.responses = settled.compactMap { step in calls[step.index].map { (step, $0) } }
                        live.fetchedPlanner = planner.index
                    } catch AntigravityLocalClient.Failure.oversized { live.fetchedPlanner = planner.index }
                    catch AntigravityLocalClient.Failure.unsupported { live.fetchedPlanner = planner.index }
                }
            }
            if row.parent != nil, live.child == nil {
                let data = try await client.call(.metadata(id), generation: session)
                let fields = try JSONFieldView.document(data).fields(["trajectoryId", "metadata"])
                let meta = try fields["metadata"]?.fields(["parentConversationId", "rootConversationId", "subagentSpec"])
                guard AntigravityStore.uuid(fields["trajectoryId"]?.string()) == trajectory.id,
                      AntigravityStore.uuid(meta?["parentConversationId"]?.string()) == row.parent,
                      AntigravityStore.uuid(meta?["rootConversationId"]?.string()) == root else { live.conflictingFamily = true; return }
                live.conflictingFamily = false
                let spec = try meta?["subagentSpec"]?.fields(["role", "typeName"])
                live.child = SubagentDisplay(role: spec?["role"]?.stringPrefix(maximumBytes: 480), typeName: spec?["typeName"]?.string(limit: 48))
            }
        } catch { /* Optional endpoints can disappear independently of the SQLite stores. */ }
    }
}
