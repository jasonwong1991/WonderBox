import Darwin
import AppKit
import Foundation
import WonderSupport
import XCTest
import SwiftUI
@testable import WonderBox

final class ImprovementsTests: XCTestCase {
    @MainActor
    func testLiveProcessorSamplingAndOffscreenViews() async throws {
        let model = AppModel()
        await model.refreshMetrics()
        await model.processorMonitor.prime()
        XCTAssertFalse(model.processorMonitor.applications.isEmpty)
        XCTAssertTrue(model.processorMonitor.applications.allSatisfy { $0.cpuPercent.isFinite && $0.cpuPercent >= 0 })
        print("Live application groups: \(model.processorMonitor.applications.count); GPU counters available: \(model.processorMonitor.gpuCountersAvailable)")
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { return }
        for kind in [ProcessorKind.cpu, .gpu] {
            // Render a fixture window offscreen; don't activate or touch the user's running app.
            let host = NSHostingView(rootView: ProcessorView(kind: kind).environmentObject(model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/tmp/wonderbox-\(kind.rawValue)-preview.png"))
                }
            }
            window.contentView = nil
        }
    }
    func testUptimeIncludesSleepAndClampsFutureBootDates() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(SystemMonitor.uptime(bootTime: 1_000_000, now: now), 1_000_000)
        XCTAssertEqual(SystemMonitor.uptime(bootTime: 3_000_000, now: now), 0)
    }

    func testLiveUptimeMatchesKernelBootTime() {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        XCTAssertEqual(sysctlbyname("kern.boottime", &boot, &size, nil, 0), 0)
        let expected = Date().timeIntervalSince1970 - Double(boot.tv_sec) - Double(boot.tv_usec) / 1_000_000
        XCTAssertEqual(SystemMonitor.uptime(), expected, accuracy: 1)
    }

    func testInitialFanReadingRetriesTransientZeroWithoutInventingRPM() {
        var reads = 0
        let values = FanController.initialReadings(retry: true, read: {
            reads += 1
            return [self.fan(rpm: reads == 1 ? 0 : 2_000)]
        }, pause: {})
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(values.first?.currentRPM, 2_000)
    }

    func testFanlessAndGenuinelyStoppedFansRemainDistinct() {
        XCTAssertTrue(FanController.initialReadings(retry: true, read: { [] }, pause: {}).isEmpty)
        var reads = 0
        let values = FanController.initialReadings(retry: true, read: { reads += 1; return [self.fan(rpm: 0)] }, pause: {})
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(values.first?.currentRPM, 0)
    }

    func testSubsequentFanReadDoesNotDelayAnIdleSample() {
        var pauses = 0
        _ = FanController.initialReadings(retry: false, read: { [self.fan(rpm: 0)] }, pause: { pauses += 1 })
        XCTAssertEqual(pauses, 0)
    }

    func testProcessorUsageGroupsHelpersAndAllowsMulticorePercentages() throws {
        let before = sample(time: 1, processes: [process(pid: 10, cpu: 0, gpu: [1: 0]), process(pid: 11, cpu: 0, gpu: [2: 0])])
        let after = sample(time: 3, processes: [process(pid: 10, cpu: 3_000_000_000, gpu: [1: 200_000_000]), process(pid: 11, cpu: 1_000_000_000, gpu: [2: 100_000_000])])
        let usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first)
        XCTAssertEqual(usage.location.path, "/Applications/Demo.app")
        XCTAssertEqual(usage.processCount, 2)
        XCTAssertEqual(usage.cpuPercent, 200, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(usage.gpuPercent), 15, accuracy: 0.01)
    }

    func testPIDReuseAndCounterResetDoNotProduceSpikes() throws {
        let before = sample(time: 1, processes: [process(pid: 10, cpu: 3_000_000_000, gpu: [1: 200_000_000])])
        let reused = ProcessProcessorCounter(pid: 10, startedAt: 2, path: "/Applications/Demo.app/Contents/MacOS/Demo", cpuNanoseconds: 10_000_000_000, gpuContexts: [1: 1_000_000_000])
        var usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: sample(time: 2, processes: [reused]), previous: before).first)
        XCTAssertEqual(usage.cpuPercent, 0)
        XCTAssertEqual(usage.gpuPercent, 0)
        usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: sample(time: 2, processes: [process(pid: 10, cpu: 0, gpu: [1: 0])]), previous: before).first)
        XCTAssertEqual(usage.cpuPercent, 0)
        XCTAssertEqual(usage.gpuPercent, 0)
    }

    func testClosedGPUContextDoesNotResetRemainingContexts() throws {
        let before = sample(time: 1, processes: [process(pid: 10, cpu: 0, gpu: [1: 4_000_000_000, 2: 0])])
        let after = sample(time: 2, processes: [process(pid: 10, cpu: 0, gpu: [2: 250_000_000])])
        let usage = try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first)
        XCTAssertEqual(try XCTUnwrap(usage.gpuPercent), 25, accuracy: 0.01)
    }

    func testUnavailableGPUAndInitialSampleDoNotMasqueradeAsZeroUsage() throws {
        let before = sample(time: 1, processes: [process(pid: 10, cpu: 0)], gpu: false)
        let after = sample(time: 2, processes: [process(pid: 10, cpu: 0)], gpu: false)
        XCTAssertTrue(ProcessProcessorInspector.usage(current: before, previous: nil).isEmpty)
        XCTAssertNil(try XCTUnwrap(ProcessProcessorInspector.usage(current: after, previous: before).first).gpuPercent)
    }

    func testRelatedFilesGroupByPurposeIncludingDarwinCachesAndReports() {
        let files = [
            ("/Users/test/Library/Application Scripts/com.demo.app", RelatedFileCategory.support),
            ("/private/var/folders/xx/user/C/com.demo.app", .caches),
            ("/Users/test/Library/Preferences/ByHost/com.demo.app.plist", .preferences),
            ("/Users/test/Library/Group Containers/TEAM.com.demo.app", .containers),
            ("/Users/test/Library/Application Support/CrashReporter/Demo.plist", .logs),
            ("/Library/PrivilegedHelperTools/com.demo.app", .startup)
        ]
        for (path, category) in files { XCTAssertEqual(RelatedFileCategory.category(for: URL(fileURLWithPath: path)), category) }
        let groups = RelatedFileGroup.groups(for: files.map { path, _ in RelatedFile(url: URL(fileURLWithPath: path), displayPath: path, size: 100) })
        XCTAssertEqual(groups.count, 6)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.size }, 600)
        XCTAssertTrue(groups.allSatisfy { $0.selectedCount == 1 })
    }

    func testCleanupDraftDoesNotChangeOriginalUntilCommitted() {
        let a = CleanupItem(url: URL(fileURLWithPath: "/fixture/a"), size: 1, isSelected: true)
        let b = CleanupItem(url: URL(fileURLWithPath: "/fixture/b"), size: 2, isSelected: false)
        let c = CleanupItem(url: URL(fileURLWithPath: "/fixture/new"), size: 3, isSelected: true)
        let original = CleanupCategory(kind: .caches, size: 6, itemCount: 3, isSelected: true, locations: [], items: [a, b, c])
        var draft = Set(original.items.prefix(2).filter(\.isSelected).map(\.id))
        draft.removeAll()
        // Closing discards the local draft; no model mutation has happened.
        XCTAssertEqual(original.items.map(\.isSelected), [true, false, true])
        var committed = original
        committed.applySelection(draft, displayedItems: [a.id, b.id])
        XCTAssertEqual(committed.items.map(\.isSelected), [false, false, true])
        XCTAssertTrue(committed.isSelected) // Items from a concurrent rescan are preserved.
        committed.applySelection([], displayedItems: [a.id, b.id, c.id])
        XCTAssertFalse(committed.isSelected)
    }

    func testPrivilegedTrashAllowlistRejectsRootsTraversalAndSystemApps() {
        let home = "/Users/test"
        XCTAssertTrue(PrivilegedTrash.isAllowed("/Applications/Subfolder/Demo.app", home: home))
        XCTAssertTrue(PrivilegedTrash.isAllowed(home + "/Library/Preferences/ByHost/com.demo.app.plist", home: home))
        for path in ["/Applications", "/Applications/Demo.app/Contents/Evil.app", "/Applications/Demo.APP/Contents/Evil.app", "/System/Applications/Mail.app",
                     home + "/Library/Caches", home + "/Library/Preferences/ByHost", "/Library/LaunchDaemons",
                     "/etc/passwd", home + "/Documents/data", home + "/Library/Caches/../Preferences/x", "/Library/Caches/.secret"] {
            XCTAssertFalse(PrivilegedTrash.isAllowed(path, home: home), path)
        }
    }

    func testTrashKeepsSameNamesApartPreservesBundleNamesAndReportsMissingFiles() throws {
        try withHome { home in
            let manager = FileManager.default
            let first = home.appendingPathComponent("Library/Caches/com.demo.app")
            let second = home.appendingPathComponent("Library/Application Support/com.demo.app")
            let app = home.appendingPathComponent("Applications/Demo.app")
            for url in [first, second, app] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
            let existing = home.appendingPathComponent(".Trash/Demo.app")
            try Data("keep".utf8).write(to: existing)
            let missing = home.appendingPathComponent("Applications/Missing.app")
            let result = PrivilegedTrash.move(TrashRequest(paths: [first.path, second.path, app.path, missing.path]), uid: getuid(), gid: getgid(), home: home.path)
            XCTAssertEqual(result.moved, 3)
            XCTAssertEqual(result.failed, [missing.path])
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
            let wrappers = try manager.contentsOfDirectory(at: home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("WonderBox-") }
            XCTAssertEqual(wrappers.count, 3)
            XCTAssertEqual(Set(try wrappers.flatMap { try manager.contentsOfDirectory(atPath: $0.path) }), ["com.demo.app", "Demo.app"])
            XCTAssertFalse(manager.fileExists(atPath: app.path))
        }
    }

    func testTrashRejectsSymlinkedParentsSourcesAndTrashDirectory() throws {
        try withHome { home in
            let manager = FileManager.default
            let outside = home.appendingPathComponent("outside")
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            let important = outside.appendingPathComponent("important")
            try Data("keep".utf8).write(to: important)
            let caches = home.appendingPathComponent("Library/Caches")
            try manager.createDirectory(at: caches.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: caches, withDestinationURL: outside)
            let alias = caches.appendingPathComponent("important")
            var result = PrivilegedTrash.move(TrashRequest(paths: [alias.path]), uid: getuid(), gid: getgid(), home: home.path)
            XCTAssertEqual(result.moved, 0)
            XCTAssertEqual(result.failed, [alias.path])
            let app = home.appendingPathComponent("Applications/Demo.app")
            try manager.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: app, withDestinationURL: outside)
            result = PrivilegedTrash.move(TrashRequest(paths: [app.path]), uid: getuid(), gid: getgid(), home: home.path)
            XCTAssertEqual(result.moved, 0)
            try manager.removeItem(at: home.appendingPathComponent(".Trash"))
            try manager.createSymbolicLink(at: home.appendingPathComponent(".Trash"), withDestinationURL: outside)
            result = PrivilegedTrash.move(TrashRequest(paths: [app.path]), uid: getuid(), gid: getgid(), home: home.path)
            XCTAssertEqual(result.moved, 0)
            XCTAssertEqual(try Data(contentsOf: important), Data("keep".utf8))
        }
    }

    func testHelperProtocolVersionsStayInSyncAndIdentityChecksArePresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try String(contentsOf: root.appendingPathComponent("Sources/WonderFanHelper/main.swift"), encoding: .utf8)
        let client = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/Services/PrivilegedService.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("protocolVersion = \"\(PrivilegedService.protocolVersion)\""))
        XCTAssertTrue(helper.contains("LOCAL_PEERTOKEN"))
        XCTAssertTrue(helper.contains("SecCodeCheckValidity"))
        XCTAssertTrue(client.contains("xattr -d com.apple.quarantine"))
        XCTAssertTrue(client.contains("launchctl enable system/"))
        XCTAssertLessThan(try XCTUnwrap(client.range(of: "xattr -d")).lowerBound, try XCTUnwrap(client.range(of: "launchctl bootstrap")).lowerBound)
    }

    private func fan(rpm: Double) -> FanReading {
        FanReading(id: 0, name: "Main", currentRPM: rpm, minimumRPM: 1_200, maximumRPM: 6_000)
    }
    private func process(pid: pid_t, cpu: UInt64, gpu: [UInt64: UInt64] = [:]) -> ProcessProcessorCounter {
        ProcessProcessorCounter(pid: pid, startedAt: 1, path: "/Applications/Demo.app/Contents/MacOS/helper\(pid)", cpuNanoseconds: cpu, gpuContexts: gpu)
    }
    private func sample(time: Double, processes: [ProcessProcessorCounter], gpu: Bool = true) -> ProcessorSample {
        ProcessorSample(sampledAt: time, processes: processes, gpuCountersAvailable: gpu)
    }
    private func withHome(_ test: (URL) throws -> Void) throws {
        let manager = FileManager.default
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertNotNil(realpath(manager.temporaryDirectory.path, &path))
        let home = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("wonderbox-home-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: home) }
        try manager.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try test(home)
    }
}
