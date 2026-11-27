import Foundation

enum AntigravityHarness {
    static let definition = LocalHarnessDefinition(descriptor: .init(id: .antigravity, name: "Antigravity", symbol: "a.circle",
        brand: .init(dark: .init(0xA5CAFF), light: .init(0x285CAD), accentLift: 0.32, accentLuminance: 0.105),
        website: URL(string: "https://antigravity.google/"), balance: .quotaWindows, hasRateDisplay: true,
        hasTaskProgress: true, progressConnector: true, quotaGroups: AntigravityQuotaGroup.options),
        platforms: [.macOS, .windows], home: ".gemini/antigravity", detectsDataDirectory: true, dataFile: "conversation_summaries.db",
        windowsExecutables: ["antigravity/Antigravity.exe", "Programs/antigravity/Antigravity.exe"],
        macApplicationNames: ["Antigravity"], macBundleIdentifiers: ["com.google.antigravity"], macTeamIdentifier: "EQHXZ8M8AV",
        installsProgressPlugin: true,
        makeMonitor: { AntigravityMonitor(io: $0) })
}

actor AntigravityMonitor: LocalHarnessMonitor, LocalHarnessQuotaSource {
    private var quotaObserver: (@Sendable (LocalQuotaFactory?) async -> Void)?
    func observeQuota(_ observer: @escaping @Sendable (LocalQuotaFactory?) async -> Void) {
        quotaObserver = observer
    }

    private struct Cached {
        let db: URL
        let wal: URL
        let shm: URL
        let log: URL
        var blockedLogDirectory: URL?
        var retryTrajectory = false
        var needsInspection = false
        init(_ store: AntigravityStore, id: String) {
            db = store.conversationURL(id)
            wal = URL(fileURLWithPath: db.path + "-wal", isDirectory: false)
            shm = URL(fileURLWithPath: db.path + "-shm", isDirectory: false)
            log = store.transcriptURL(id)
        }
        func databaseStamps(_ files: any PlatformFileSystem) -> [PlatformFileMetadata?] {
            [files.metadata(db), files.metadata(wal), files.metadata(shm)]
        }
        mutating func updateTranscript(files: any PlatformFileSystem) -> Bool {
            let before = transcript.stamp
            guard let stamp = files.metadata(log), stamp.isRegularFile else {
                transcript = .init()
                return before != nil
            }
            guard stamp != before else { return false }
            if let blockedLogDirectory, files.metadata(blockedLogDirectory)?.isDirectory != true { return false }
            // A cached tail never authorizes a new read through a replaced ancestor.
            let logs = log.deletingLastPathComponent(), system = logs.deletingLastPathComponent()
            let conversation = system.deletingLastPathComponent(), brain = conversation.deletingLastPathComponent()
            blockedLogDirectory = [brain, conversation, system, logs].first { files.metadata($0)?.isDirectory != true }
            if blockedLogDirectory == nil { transcript.read(log, files: files) }
            else { transcript = .init() }
            return before != transcript.stamp
        }
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
    private let schedule: ActivityLogWatcher.Schedule
    private var summaryCache: (stamps: [PlatformFileMetadata?], rows: [AntigravityStore.Summary])?
    private var retryFiles = false
    private var publish: (@Sendable (HarnessActivity) async -> Void)?
    private var generation: UInt64 = 0
    private var reading = false, dirty = false
    private var disagreements = Set<String>()
    private var policy = ActivityRefreshPolicy.collapsed
    private var cache: [String: Cached] = [:]
    private var watermark: Date?
    private var hubGeneration: UInt64?
    private var pass: UInt64 = 0
    private var previous: HarnessActivity?

    init(io: LocalHarnessIO, schedule: @escaping ActivityLogWatcher.Schedule = ActivityLogWatcher.dispatchAfter) {
        self.io = io; self.schedule = schedule
    }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        let old = reset()
        let current = generation
        await old?.revoke()
        guard generation == current else { return }
        let store = AntigravityStore(home: home, files: io.files)
        self.store = store; self.policy = policy; self.publish = publish
        client = AntigravityLocalClient(home: home, io: io)
        let watcher = ActivityLogWatcher(files: io.files, events: io.events, interval: policy.interval, fileExtensions: nil, schedule: schedule) { [weak self] _ in
            Task { await self?.refresh(ifCurrent: current) }
        }
        self.watcher = watcher
        urls = baseURLs(store)
        watcher.update(urls, interval: policy.interval)
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
        return [directory, store.home.appendingPathComponent("daemon", isDirectory: true), store.summariesURL, sidecar(store.summariesURL)]
    }

    private func sidecar(_ url: URL) -> URL { URL(fileURLWithPath: url.path + "-wal", isDirectory: false) }

    private func reset() -> AntigravityLocalClient? {
        generation &+= 1; reading = false; dirty = false
        watcher?.stop(); watcher = nil; summaryCache = nil
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
            if let hubGeneration { _ = await client.isCurrent(hubGeneration) }
            return
        }
        reading = true
        let current = generation
        disagreements.removeAll()
        var attempts = 0, rechecked = false
        repeat {
            attempts += 1
            dirty = false
            let retryIDs = disagreements
            disagreements.removeAll(); retryFiles = false
            let observation = await reconcile(store, client: client, generation: current, rechecking: retryIDs)
            guard current == generation else { return }
            if !disagreements.isEmpty && !rechecked {
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
        let active = previous?.activities.contains { [.running, .waitingForInput].contains($0.phase) } == true ||
            cache.values.contains { $0.summary?.running == true || $0.summary?.background == true }
        watcher?.poll(after: dirty || !disagreements.isEmpty || retryFiles || active ? policy.interval : 60)
    }

    private func reconcile(_ store: AntigravityStore, client: AntigravityLocalClient, generation current: UInt64, rechecking: Set<String>) async -> HarnessActivity? {
        let session = await client.discover()
        guard current == generation else { return nil }
        if session != hubGeneration {
            watermark = nil
            for key in cache.keys { cache[key]?.metadata = .init(); cache[key]?.witnessed = nil; cache[key]?.gap = nil }
            hubGeneration = session
            if let session {
                await quotaObserver? { home, credential, history, output in
                    AntigravityQuotaCoordinator(client: client, session: session, home: home, credential: credential,
                                                history: history, output: output)
                }
            } else { await quotaObserver?(nil) }
            guard current == generation else { return nil }
        }
        let summaryFiles = [store.summariesURL, sidecar(store.summariesURL),
                            URL(fileURLWithPath: store.summariesURL.path + "-shm", isDirectory: false),
                            URL(fileURLWithPath: store.summariesURL.path + "-journal", isDirectory: false)]
        let summaryStamps = summaryFiles.map { io.files.metadata($0) }
        let rows: [AntigravityStore.Summary]
        do {
            if let summaryCache, summaryCache.stamps == summaryStamps { rows = summaryCache.rows }
            else { rows = try store.summaries(includeDatabaseDates: false) }
        } catch {
            retryFiles = error as? AntigravityStore.Failure == .retrySoon
            watermark = nil; cache = [:]; summaryCache = nil
            var value = HarnessActivity(status: .unavailable)
            if let failure = error as? AntigravityStore.Failure {
                switch failure { case .missing: value.status = .missing; case .incompatible: value.status = .incompatible; default: break }
            }
            value.activities = previous?.activities.map { old in
                var row = old
                if [.running, .waitingForInput].contains(row.phase) { row.markSourceUnavailable() }
                return row
            } ?? []
            urls = baseURLs(store); watcher?.update(urls, interval: policy.interval)
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
        for index in family.indices {
            var row = family[index].0
            var item = cache[row.id] ?? Cached(store, id: row.id)
            let stamps = item.databaseStamps(io.files)
            if let db = stamps[0], db.isRegularFile { row.updated = max(row.updated, db.modified) }
            family[index].0 = row
            let filesChanged = item.stamps != stamps
            let changed = row != item.summary || filesChanged
            if changed || item.retryTrajectory || rechecking.contains(row.id) {
                item.retryTrajectory = false
                let trajectory: AntigravityStore.Trajectory?
                do { trajectory = try store.trajectory(row) }
                catch {
                    trajectory = nil
                    item.retryTrajectory = error as? AntigravityStore.Failure == .unavailable || error as? AntigravityStore.Failure == .retrySoon
                    if item.retryTrajectory { retryFiles = true }
                }
                if item.trajectory?.id != trajectory?.id || item.trajectory?.anchor?.index != trajectory?.anchor?.index ||
                    item.trajectory?.anchor?.type != trajectory?.anchor?.type ||
                    (trajectory?.last?.index ?? -1) < (item.trajectory?.last?.index ?? -1) ||
                    item.stamps.first.flatMap({ $0?.identity }) != stamps[0]?.identity {
                    item.metadata = .init(); item.transcript = .init(); item.witnessed = nil; item.turn = nil
                }
                item.trajectory = trajectory
            }
            let transcriptChanged = item.updateTranscript(files: io.files)
            if item.summary != nil && (changed || transcriptChanged) { item.needsInspection = true }
            let open = item.trajectory?.unresolved.isEmpty == false
            // An idle summary can lag an input or a completed tool before the next
            // planner is written. Historical completed planners need no API poll.
            let lacksEnding = item.trajectory?.last.map { $0.status != 6 && !($0.type == 15 && $0.status == 3) } ?? false
            let settled = item.trajectory?.tail.last { $0.type == 15 && AntigravityProjection.Status(database: $0.status)?.settled == true }
            let needsFinalCall = watermark.map { row.updated > $0 } == true &&
                settled.map { $0.index != item.metadata.fetchedPlanner } == true
            if needsFinalCall || row.running || row.background || open || lacksEnding || item.metadata.runState == .running ||
                item.needsInspection || item.metadata.conflictingState {
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
            if selected.contains(row.id) { watched += [item.db, item.wal, item.log] }
            if let session, selected.contains(row.id), let trajectory = item.trajectory, let id = UUID(uuidString: row.id) {
                item.lastInspection = pass; item.needsInspection = false
                await enrich(&item.metadata, row: row, trajectory: trajectory, id: id,
                             root: parents.last ?? row.id, client: client, session: session)
                guard current == generation else { return nil }
                if item.databaseStamps(io.files) != item.stamps { dirty = true; return nil }
            }
            let latestPlanner = item.trajectory?.tail.last { $0.type == 15 && $0.status == 3 }?.index ?? item.metadata.planner?.index
            if let session, let id = latestPlanner.flatMap({ item.transcript.records[$0]?.model }) ?? item.metadata.call?.modelID {
                item.metadata.catalog = await client.modelCatalog(for: id, session: session)
                guard current == generation else { return nil }
            }
            if item.metadata.conflictingState { disagreements.insert(row.id) }
            if item.metadata.conflictingFamily { next[row.id] = item; continue }
            let result = AntigravityProjection.project(row, trajectory: item.trajectory, transcript: item.transcript, live: item.metadata,
                dependent: activeParents.contains(row.id), unconfirmedDependent: unconfirmedParents.contains(row.id),
                watermark: item.gap ?? watermark, turnCache: &item.turn, witnessed: item.witnessed, previous: prior[row.id],
                dependentEnded: childEnd[row.id], scope: scope)
            if result.needsRecheck { disagreements.insert(row.id) }
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
            guard await client.isCurrent(session, checkDirectory: true) else { if current == generation { dirty = true }; return nil }
            guard current == generation else { return nil }
        }
        // SQL and Connect are independent snapshots. Reconcile a changed request
        // before publishing, including when no server was available for the pass.
        if summaryFiles.map({ io.files.metadata($0) }) != summaryStamps, (try? store.summaries(includeDatabaseDates: false)) != rows {
            dirty = true; return nil
        }
        guard !dirty, disagreements.isEmpty || !rechecking.isEmpty else { return nil }
        let visible = Set(value.activities.compactMap(\.threadID))
        let orphans = Set(family.compactMap { row, parents in parents.contains(where: { !visible.contains($0) }) ? row.id : nil })
        value.activities.removeAll { $0.threadID.map(orphans.contains) == true }
        value.requests.removeAll { orphans.contains($0.threadID) }
        summaryCache = (summaryStamps, rows)
        cache = next; urls = watched; watcher?.update(urls, interval: policy.interval)
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
            var steps = try AntigravityProjection.typedSteps(data, offset: offset, anchor: trajectory.anchor?.index, cascade: row.id, trajectory: trajectory.id)
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
