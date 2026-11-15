import Foundation
import XCTest
@testable import PacerCore
import PacerMacSupport

final class ProviderInstallationMacTests: XCTestCase {
    func testInstallationDetectionUsesBoundedExecutableLocationsWithoutLaunching() throws {
        // Every module's app list is supplied, so apps installed on this Mac never count.
        let noApps = Dictionary(uniqueKeysWithValues: HarnessRegistry.descriptors.map { ($0.id, [URL]()) })
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("provider-install-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let detected = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: noApps, systemBinDirectories: [])
        XCTAssertEqual(detected, .init(codexInstalled: false, claudeInstalled: true))

        // Finder launches do not inherit shell PATH. Existing manager installs
        // must still enable the matching module automatically.
        try FileManager.default.removeItem(at: cli)
        for (relative, name) in [(".nvm/versions/node/v22.2.0/bin", "codex"), (".fnm/current/bin", "claude")] {
            let directory = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let managed = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: noApps, systemBinDirectories: [])
        XCTAssertEqual(managed, .init(codexInstalled: true, claudeInstalled: true))

        // Harness without its app or `dsh` on a path is still found by its sessions, also under `$DSH_HOME`.
        let custom = home.appendingPathComponent("dsh-data")
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        XCTAssertFalse(managed.deepseekInstalled)
        XCTAssertTrue(ProviderInstallationDetection.detect(userHome: home, environment: ["DSH_HOME": custom.path],
            applicationURLs: noApps, systemBinDirectories: []).deepseekInstalled)
        // A local module without its app is found by its data file, in its
        // default folder or a folder chosen in Settings.
        let workbuddy = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .workbuddy })
        XCTAssertFalse(ProviderInstallationDetection.detect(userHome: home, environment: [:], applicationURLs: noApps,
            systemBinDirectories: []).isInstalled(.workbuddy))
        let chosen = home.appendingPathComponent("wb-data")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Data().write(to: chosen.appendingPathComponent(workbuddy.dataFile))
        XCTAssertTrue(ProviderInstallationDetection.detect(userHome: home, environment: [:], applicationURLs: noApps,
            systemBinDirectories: [], harnessHomes: ["workbuddy": chosen.path]).isInstalled(.workbuddy))
        let standard = workbuddy.defaultHome(userHome: home)
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        try Data().write(to: standard.appendingPathComponent(workbuddy.dataFile))
        XCTAssertTrue(ProviderInstallationDetection.detect(userHome: home, environment: [:], applicationURLs: noApps,
            systemBinDirectories: []).isInstalled(.workbuddy))
        let modules = ProviderModules()
        XCTAssertEqual(modules.enabledProviders(detection: .init(codexInstalled: true, claudeInstalled: false, deepseekInstalled: true)),
            [.codex, .deepseek], "Each detected module turns on by itself")
    }
}
