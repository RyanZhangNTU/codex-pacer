import AppKit
import SwiftUI
import PacerCore

@_silgen_name("pacer_perf_metrics")
private func readMetrics(_ values: UnsafeMutablePointer<UInt64>) -> Int32

enum ReplayMetrics {
    static var chartEvaluations = 0
}

@main
struct UIReplay {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ReplayDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ReplayDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel!
    private var hosting: NSHostingView<IslandView>!
    private var panel: NSPanel!
    private var backdrop: NSWindow!
    private var timer: Timer?
    private var tick = 0
    private let hertz = 4.0
    private let warmup = 10.0
    private let epoch = Date(timeIntervalSince1970: 1_791_021_600)
    private var started = 0.0
    private var measurementStart = 0.0
    private var initialMetrics: [UInt64]?
    private var initialEvaluations = 0
    private var samples: [[String: Any]] = []
    private var output: URL!
    private var label = ""
    private var seconds = 60.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf:
                Bundle.main.url(forResource: "configuration", withExtension: "json")!)) as! [String: Any]
            label = settings["label"] as! String
            output = URL(fileURLWithPath: settings["output"] as! String, isDirectory: true)
            seconds = settings["seconds"] as? Double ?? 60
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Isolated bundle defaults and synthetic data: no Codex sessions or credentials.
            UserDefaults.standard.register(defaults: ["islandAppearance": "liquidGlass", "glassStyle": "regular",
                "glassTransparency": 0.5, "glassCornerRadius": 27, "glassTint": "neutral",
                "compactMetric": "remaining", "quotaWindowID": "auto", "completedRetentionMinutes": 30])
            model = IslandModel(demo: true, initiallyExpanded: true)
            model.now = epoch
            model.history = QuotaCycleHistory()
            for index in 0..<187 {
                let date = epoch.addingTimeInterval(-5 * 86400 * (1 - Double(index) / 186))
                model.history.record(try quota(at: date, used: 57 * Double(index) / 186))
            }
            model.quota = try quota(at: epoch, used: 57)
            model.activities = DemoScenario.tasks(stage: .responding, at: epoch)
            model.notchWidth = 180
            model.topHeight = 32
            model.onQuit = { NSApp.terminate(nil) }
            let size = CGSize(width: 440, height: 466)
            let presentation = IslandPresentation()
            presentation.canvas = size
            presentation.sample = .resting(at: CGRect(origin: .zero, size: size), expanded: true, hasBlackHeader: true)
            hosting = NSHostingView(rootView: IslandView(model: model, presentation: presentation))
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            hosting.autoresizingMask = [.width, .height]
            let screen = NSScreen.main!.frame
            let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                width: size.width, height: size.height)
            backdrop = NSWindow(contentRect: frame.insetBy(dx: -24, dy: -24), styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.30, alpha: 1)
            backdrop.level = .floating
            backdrop.isReleasedWhenClosed = false
            backdrop.orderFrontRegardless()
            panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Pacer Performance — " + label
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            started = ProcessInfo.processInfo.systemUptime
            timer = Timer(timeInterval: 1 / hertz, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } catch { fail(error) }
    }

    private func quota(at date: Date, used: Double) throws -> QuotaSnapshot {
        let wire: [String: Any] = ["rateLimits": ["limitId": "codex", "planType": "pro",
            "credits": ["hasCredits": true, "unlimited": false, "balance": "12500"],
            "secondary": ["usedPercent": used, "windowDurationMins": 10080,
                "resetsAt": epoch.addingTimeInterval(2 * 86400).timeIntervalSince1970]],
            "rateLimitResetCredits": ["availableCount": 2, "credits": [
                ["id": "first", "status": "available", "grantedAt": epoch.addingTimeInterval(-3600).timeIntervalSince1970,
                 "expiresAt": epoch.addingTimeInterval(20).timeIntervalSince1970],
                ["id": "second", "status": "available", "grantedAt": epoch.addingTimeInterval(-3600).timeIntervalSince1970,
                 "expiresAt": epoch.addingTimeInterval(3600).timeIntervalSince1970]]]]
        var snapshot = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: wire), capturedAt: date)
        snapshot.accountScope = "performance-replay"
        return snapshot
    }

    private func metrics() -> [UInt64] {
        var values = Array(repeating: UInt64(0), count: 6)
        precondition(readMetrics(&values) == 0)
        return values
    }
    private func advance() {
        tick += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let now = epoch.addingTimeInterval(Double(tick) / hertz)
        model.now = now
        model.activities = DemoScenario.tasks(stage: .responding, at: now)
        var status = RuntimeStreamStatus()
        status.connected = true; status.attachedThreads = 2; status.notifications = tick
        model.streamStatuses = ["local": status]
        if tick % 120 == 0 {
            let snapshot = try! quota(at: now, used: 57 + Double(tick / 120))
            model.quota = snapshot
            model.history.record(snapshot)
        }
        if initialMetrics == nil && elapsed >= warmup {
            initialMetrics = metrics(); measurementStart = ProcessInfo.processInfo.systemUptime
            initialEvaluations = ReplayMetrics.chartEvaluations
        }
        if initialMetrics != nil && tick % 4 == 0 {
            let value = metrics()
            samples.append(["elapsed": elapsed, "cpuNanoseconds": value[0], "footprintBytes": value[1],
                "rssBytes": value[2], "chartEvaluations": ReplayMetrics.chartEvaluations])
        }
        if elapsed >= warmup + seconds { finish() }
    }
    private func finish() {
        timer?.invalidate()
        let end = metrics(), initial = initialMetrics!
        let elapsed = ProcessInfo.processInfo.systemUptime - measurementStart
        let footprint = samples.compactMap { $0["footprintBytes"] as? UInt64 }.sorted()
        let result: [String: Any] = ["label": label, "measuredSeconds": elapsed, "warmupSeconds": warmup,
            "eventHertz": hertz, "initialCurvePoints": 187, "taskCount": 2,
            "cpuPercent": Double(end[0] - initial[0]) / 1e9 / elapsed * 100,
            "footprintMedianBytes": footprint[footprint.count / 2], "footprintPeakBytes": footprint.last!,
            "diskReadBytes": end[3] - initial[3], "diskWriteBytes": end[4] - initial[4],
            "logicalWriteBytes": end[5] - initial[5],
            "chartEvaluations": ReplayMetrics.chartEvaluations - initialEvaluations,
            "totalTicks": tick, "samples": samples]
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(label + ".json"), options: .atomic)
            // Capture after the measured interval; export work does not enter the CPU/I/O result.
            if let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: image)
                try image.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent(label + ".png"))
            }
            NSApp.terminate(nil)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        if let output { try? String(describing: error).write(to: output.appendingPathComponent(label + ".error.txt"), atomically: true, encoding: .utf8) }
        NSApp.terminate(nil)
    }
}
