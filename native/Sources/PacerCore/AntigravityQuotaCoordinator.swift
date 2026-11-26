import Foundation

package enum AntigravityQuotaGroup: String, CaseIterable, Sendable {
    case gemini, thirdParty = "3p"

    package static let defaultsKey = "antigravityQuotaGroup"
    static let options = HarnessQuotaGroups(ids: allCases.map(\.rawValue), defaultsKey: defaultsKey, labelPrefix: "antigravity.quota")
    package var name: String { L10n.text("antigravity.quota." + rawValue) }

    /// A saved choice stays selected when its pool is unavailable. On first use
    /// an account offering just one pool shows that pool.
    package static func selected(_ snapshot: QuotaSnapshot?, saved: String?) -> QuotaSnapshot? {
        guard let snapshot else { return nil }
        let id = options.selection(in: snapshot, saved: saved)
        return snapshot.buckets.first { $0.id == id }.map { snapshot.showing($0) }
    }
}

/// One coordinator belongs to one verified hub session. Activity owns the
/// client and its revocation. Quota never opens a second transport binding.
package actor AntigravityQuotaCoordinator: LocalHarnessQuotaCoordinator {
    private let client: AntigravityLocalClient
    private let session: UInt64
    private let home: URL
    private let credential: DeepSeekHistoryCredential
    private let store: QuotaHistoryStore
    private let now: @Sendable () -> Date
    private let output: @Sendable (LocalHarnessQuotaState, [IslandNotice]) async -> Void
    private let generation = QuotaWorkGeneration()
    private let revision: UInt64
    private var state = LocalHarnessQuotaState()
    private var scope: String?
    private var policies: [String: AttentionPolicy] = [:]

    package init(client: AntigravityLocalClient, session: UInt64, home: URL, credential: DeepSeekHistoryCredential,
                 history: QuotaHistoryStore, now: @escaping @Sendable () -> Date = { Date() },
                 output: @escaping @Sendable (LocalHarnessQuotaState, [IslandNotice]) async -> Void) {
        self.client = client; self.session = session; self.home = home; self.credential = credential
        revision = generation.capture()
        self.store = history; self.now = now; self.output = output
    }

    static func decode(_ data: Data, scope: String?, at now: Date) throws -> QuotaSnapshot {
        guard let groups = try JSONFieldView.document(data, maximumBytes: 64 * 1024)
            .fields(["response"])["response"]?.fields(["groups"])["groups"] else { throw JSONFieldView.Failure.malformed }
        var windows: [String: QuotaWindow] = [:]
        for group in try groups.elements(maximumCount: 32) where group.isObject {
            guard let buckets = try group.fields(["buckets"])["buckets"], buckets.isArray else { continue }
            for bucket in try buckets.elements(maximumCount: 64) where bucket.isObject {
                let values = try bucket.fields(["bucketId", "window", "remainingFraction", "resetTime"])
                guard let id = values["bucketId"]?.string(limit: 32),
                      let period = values["window"]?.string(limit: 8), ["5h", "weekly"].contains(period),
                      AntigravityQuotaGroup.allCases.contains(where: { id == $0.rawValue + "-" + period }),
                      let fraction = values["remainingFraction"]?.number(), (0...1).contains(fraction) else { continue }
                windows[id] = QuotaWindow(id: "antigravity:" + id, usedPercent: 100 * (1 - fraction),
                    durationMinutes: period == "5h" ? 300 : 10080, resetsAt: AntigravityStore.date(values["resetTime"]?.string(limit: 64)))
            }
        }
        let buckets = AntigravityQuotaGroup.allCases.compactMap { group -> QuotaBucket? in
            let pair = ["5h", "weekly"].compactMap { windows[group.rawValue + "-" + $0] }
            return pair.isEmpty ? nil : QuotaBucket(id: group.rawValue, name: group.name, plan: nil, windows: pair, credits: nil)
        }
        return .init(buckets: buckets, capturedAt: now, accountScope: scope, resetCredits: nil)
    }

    private func accountScope() async -> String? {
        guard let data = try? await client.call(.userStatus, generation: session),
              let email = try? JSONFieldView.document(data).fields(["userStatus"])["userStatus"]?
                .fields(["email"])["email"]?.string(limit: 321),
              !email.isEmpty, email.utf8.count <= 320, email.contains("@"),
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { return nil }
        return credential.antigravityScope(email: email)
    }

    private func clearReading() {
        scope = nil; state.snapshot = nil; state.history = .init(); state.warning = nil; state.error = nil
        policies.removeAll()
    }

    private func notices(_ reading: QuotaSnapshot) -> [IslandNotice] {
        guard let scope else { return [] }
        return reading.buckets.flatMap { bucket -> [IslandNotice] in
            let baseline = policies[bucket.id] == nil
            let notices = policies[bucket.id, default: AttentionPolicy()].quotaNotices(reading.showing(bucket), at: now())
            return baseline ? [] : notices.map {
                IslandNotice(id: "antigravity:" + scope + ":" + $0.id, kind: $0.kind,
                    title: "Antigravity · " + $0.title, detail: (bucket.name ?? bucket.id) + " · " + $0.detail)
            }
        }
    }

    private var current: Bool { generation.contains(revision) && !Task.isCancelled }

    package func refresh(expanded: Bool, force: Bool = false) async {
        guard current, !state.refreshing, ProviderQuotaRefreshPolicy.isDue(lastAttempt: state.lastAttempt,
            expanded: expanded, failures: state.failures, now: now(), force: force) else { return }
        state.refreshing = true; state.lastAttempt = now()
        defer { state.refreshing = false }
        await output(state, [])
        guard current else { return }
        let before = await accountScope()
        guard current else { return }
        if before != scope || before == nil {
            clearReading(); scope = before
            await output(state, [])
            if let before, let cached = await store.restore(home: home, accountScope: before, now: now()) {
                guard current else { return }
                state.history = cached.1
                state.snapshot = cached.0
            }
        }
        guard current else { return }
        let reading: QuotaSnapshot?
        var timedOut = false
        do {
            let data = try await client.call(.quota, generation: session)
            reading = try Self.decode(data, scope: before, at: now())
        } catch AntigravityLocalClient.Failure.timedOut { reading = nil; timedOut = true }
        catch { reading = nil }
        guard current else { return }
        let after = await accountScope()
        guard current else { return }
        let bound = await client.discover() == session
        guard current else { return }
        var delivery: [IslandNotice] = []
        if !bound || before != after {
            clearReading()
            state.failures = 0; state.lastAttempt = bound ? nil : now()
        } else if let reading {
            state.snapshot = reading; state.error = nil; state.failures = 0
            if after != nil {
                state.history.record(reading, preservingMissingSeries: true)
                let saved = await store.save(home: home, snapshot: reading, history: state.history, now: now())
                guard current else { return }
                state.warning = saved ? nil : L10n.text("quota.history_unsaved")
                delivery = notices(reading)
            } else { state.warning = L10n.text("quota.no_identity") }
        } else {
            if after == nil { clearReading() }
            state.failures = min(4, state.failures + 1)
            if !timedOut || state.snapshot == nil { state.error = L10n.text("antigravity.quota.unavailable") }
        }
        var completed = state
        completed.refreshing = false
        await output(completed, delivery)
    }

    package func flush() async { await store.flush() }
    package nonisolated func invalidateSource() { generation.invalidate() }
}
