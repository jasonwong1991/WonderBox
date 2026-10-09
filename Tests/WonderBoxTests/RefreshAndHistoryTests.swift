import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class RefreshAndHistoryTests: XCTestCase {
    func testHistoryUsesOneMinuteOfRealSamplesAfterAnEntireDay() {
        var history = ProcessorHistory()
        XCTAssertTrue(history.samples.isEmpty)
        for second in stride(from: 0, through: 86_400, by: 3) { history.append(sample(Double(second))) }
        XCTAssertEqual(history.samples.count, 21)
        let points = history.points(for: .cpu, endingAt: date(86_400))
        XCTAssertEqual(points.first?.date, date(86_340))
        XCTAssertEqual(points.last?.date, date(86_400))
        XCTAssertEqual(points.last?.value, 0.2)
    }

    func testManualRefreshesStayBoundedAndNeverAddFakeZeroHistory() {
        var history = ProcessorHistory()
        for tick in 0..<10_000 { history.append(sample(Double(tick) / 1_000)) }
        XCTAssertEqual(history.samples.count, ProcessorHistory.maximumSamples)
        XCTAssertTrue(history.samples.allSatisfy { $0.cpuUsage == 0.2 })
        history.append(sample(10_000))
        XCTAssertEqual(history.samples.count, 1, "A long sleep must discard stale history")
        XCTAssertTrue(history.points(for: .cpu, endingAt: date(10_061)).isEmpty)
    }

    func testUnknownGPUAndSamplingGapsAreNotDrawnAsIdleOrConnected() {
        var history = ProcessorHistory()
        history.append(sample(0, gpu: 0.4))
        history.append(sample(3, gpu: nil))
        history.append(sample(6, gpu: 0))
        history.append(sample(30, gpu: 0.5))
        let points = history.points(for: .gpu, endingAt: date(30))
        XCTAssertEqual(points.map(\.value), [0.4, 0, 0.5])
        XCTAssertEqual(Set(points.map(\.segment)).count, 3)
        XCTAssertEqual(history.points(for: .cpu, endingAt: date(30)).count, 4)
    }

    func testClockChangeAndDuplicateTimestampKeepAValidChronologicalAxis() {
        var history = ProcessorHistory()
        history.append(sample(100))
        history.append(sample(100, gpu: 0.8))
        XCTAssertEqual(history.samples.count, 1)
        history.append(sample(20))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.sampledAt, date(20))
    }

    func testInvalidAndOutOfRangePercentagesDoNotCorruptChartScale() {
        var history = ProcessorHistory()
        history.append(sample(0, gpu: .nan))
        history.append(sample(3, gpu: -.infinity))
        history.append(sample(6, gpu: 2))
        history.append(sample(9, gpu: -0.5))
        XCTAssertEqual(history.points(for: .gpu, endingAt: date(9)).map(\.value), [1, 0])
    }

    @MainActor
    func testEachTabRefreshesOnlyItsOwnRegisteredAction() async {
        let controller = SectionRefreshController()
        var calls: [AppSection] = []
        for section in AppSection.allCases {
            controller.register(section, owner: UUID(), busy: false) { calls.append(section) }
        }
        for section in AppSection.allCases {
            calls.removeAll()
            await controller.refresh(section)
            XCTAssertEqual(calls, [section])
            XCTAssertTrue(controller.canRefresh(section))
        }
    }

    @MainActor
    func testUnregisteredOrBusyTabsDoNotFallBackToOverview() async {
        let controller = SectionRefreshController()
        controller.register(.overview, owner: UUID(), busy: false) { XCTFail("Wrong tab") }
        let owner = UUID()
        var calls = 0
        controller.register(.applications, owner: owner, busy: true) { calls += 1 }
        await controller.refresh(.applications)
        await controller.refresh(.storage)
        XCTAssertEqual(calls, 0)
        controller.setBusy(false, section: .applications, owner: owner)
        await controller.refresh(.applications)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testRepeatedClickDoesNotDuplicateWorkAndSwitchingTabsDoesNotRedirectIt() async throws {
        let controller = SectionRefreshController()
        var resume: CheckedContinuation<Void, Never>?
        var cpuCalls = 0, gpuCalls = 0
        controller.register(.cpu, owner: UUID(), busy: false) {
            cpuCalls += 1
            await withCheckedContinuation { resume = $0 }
        }
        controller.register(.gpu, owner: UUID(), busy: false) { gpuCalls += 1 }
        let first = Task { await controller.refresh(.cpu) }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let continuation = try XCTUnwrap(resume)
        XCTAssertFalse(controller.canRefresh(.cpu))
        await controller.refresh(.cpu)
        await controller.refresh(.gpu)
        XCTAssertEqual(cpuCalls, 1)
        XCTAssertEqual(gpuCalls, 1)
        continuation.resume()
        await first.value
        XCTAssertTrue(controller.running.isEmpty)
    }

    @MainActor
    func testOldViewDisappearanceCannotRemoveNewViewAction() async {
        let controller = SectionRefreshController()
        let old = UUID(), new = UUID()
        var calls = 0
        controller.register(.storage, owner: old, busy: false) { XCTFail("Stale view") }
        controller.register(.storage, owner: new, busy: false) { calls += 1 }
        controller.unregister(.storage, owner: old)
        controller.setBusy(true, section: .storage, owner: old)
        await controller.refresh(.storage)
        XCTAssertEqual(calls, 1)
        controller.unregister(.storage, owner: new)
        XCTAssertFalse(controller.canRefresh(.storage))
    }

    @MainActor
    func testRegisteredViewActionReadsCurrentStateAfterDirectoryChanges() async {
        let model = AppModel()
        let changes = PassthroughSubject<String, Never>()
        var refreshed: [String] = []
        let host = NSHostingView(rootView: RefreshStateProbe(changes: changes, refreshed: { refreshed.append($0) })
            .environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        XCTAssertTrue(model.sectionRefresh.canRefresh(.storage))
        await model.sectionRefresh.refresh(.storage)
        changes.send("second-directory")
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        await model.sectionRefresh.refresh(.storage)
        XCTAssertEqual(refreshed, ["first-directory", "second-directory"], "The toolbar must not hold onto the first directory")
    }

    @MainActor
    func testDiskRefreshForcesCurrentDirectoryInsteadOfUsingCachedSizes() async {
        var requests: [URL] = []
        let browser = DiskBrowserController { url in
            requests.append(url)
            return AsyncStream { stream in
                stream.yield(.contents([])); stream.yield(.finished); stream.finish()
            }
        }
        let first = URL(fileURLWithPath: "/fixture/one"), second = URL(fileURLWithPath: "/fixture/two")
        var current = first
        let controller = SectionRefreshController()
        controller.register(.storage, owner: UUID(), busy: false) {
            browser.scan(current, force: true)
            await browser.waitForScan()
        }
        browser.scan(first); await browser.waitForScan()
        browser.scan(first); XCTAssertTrue(browser.isCached)
        current = second
        await controller.refresh(.storage)
        await controller.refresh(.storage)
        XCTAssertEqual(requests, [first, second, second])
        XCTAssertFalse(browser.isScanning)
        XCTAssertFalse(browser.isCached)
    }

    @MainActor
    func testRefreshKeepAwakeDoesNotStartAnInactiveSession() {
        let preventer = SleepPreventer()
        preventer.refreshStatus()
        XCTAssertFalse(preventer.isActive)
        XCTAssertNil(preventer.expiresAt)
    }

    @MainActor
    func testOverviewSamplingUpdatesTimestampedProcessorHistory() async {
        let model = AppModel()
        XCTAssertTrue(model.processorHistory.samples.isEmpty)
        await model.refreshMetrics()
        XCTAssertEqual(model.processorHistory.samples.last, model.snapshot)
        XCTAssertFalse(model.isRefreshingMetrics)
    }

    func testEveryScreenRegistersAnActionAndBothGlobalButtonsUseTheRouter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let screens = ["OverviewView", "MemoryView", "ProcessorView", "FanView", "AwakeView", "ApplicationsView", "CleanerView", "DiskAnalyzerView", "SettingsView"]
        for screen in screens {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/Views/\(screen).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains(".sectionRefresh("), screen)
        }
        for file in ["Views/RootView.swift", "WonderBoxApp.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/\(file)"), encoding: .utf8)
            XCTAssertTrue(source.contains("CurrentSectionRefreshButton(controller: model.sectionRefresh"))
        }
    }

    @MainActor
    func testHistoryCardUsesAvailableWidthAtCompactAndLargeWindowSizes() throws {
        var history = ProcessorHistory()
        let end = Date()
        for second in stride(from: -60, through: 0, by: 3) {
            var value = MetricSnapshot(cpuUsage: 0.15 + sin(Double(second) / 5) * 0.1, gpuUsage: 0.5)
            value.sampledAt = end.addingTimeInterval(Double(second))
            history.append(value)
        }
        for width: CGFloat in [600, 1_000] {
            let host = NSHostingView(rootView: ProcessorHistoryCard(kind: .cpu, value: "15%", detail: "Apple M4 Max", history: history))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.width, width)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 300)
            if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-processor-history-\(Int(width)).png"))
            }
            window.contentView = nil
        }
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func sample(_ seconds: Double, gpu: Double? = 0.4) -> MetricSnapshot {
        var snapshot = MetricSnapshot(cpuUsage: 0.2, gpuUsage: gpu)
        snapshot.sampledAt = date(seconds)
        return snapshot
    }
}

private struct RefreshStateProbe: View {
    @State private var directory = "first-directory"
    let changes: PassthroughSubject<String, Never>
    let refreshed: (String) -> Void
    var body: some View {
        Color.clear
            .onReceive(changes) { directory = $0 }
            .sectionRefresh(.storage) { refreshed(directory) }
    }
}
