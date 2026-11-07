import AppKit
import SwiftUI
import XCTest
@testable import WonderBox

final class OverviewPowerTests: XCTestCase {
    @MainActor
    func testCardUsesSystemSensorRatherThanComponentTotals() async {
        let sample = PowerSnapshot(readings: [
            .system: PowerReading(watts: 32.5, source: "SMC · PSTR"),
            .cpu: PowerReading(watts: 12, source: "IOReport · CPU Energy"),
            .gpu: PowerReading(watts: 2.3, source: "IOReport · GPU Energy")
        ])
        let monitor = PowerMonitor { sample }
        await monitor.refresh()
        let view = OverviewContent(powerMonitor: monitor)
        let card = view.powerCard(at: sample.sampledAt)
        XCTAssertEqual(card.title, String(localized: "System Power"))
        XCTAssertEqual(card.value, "32.50 W")
        XCTAssertEqual(card.detail, "SMC · PSTR")
        XCTAssertNotNil(card.action)
        XCTAssertEqual(card.actionHelp, String(localized: "View power details"))
        XCTAssertNil(card.progress, "Watts are not a utilization percentage")
        XCTAssertTrue(card.history.isEmpty, "The generic sparkline has a 0–1 percentage scale")
        XCTAssertEqual(view.powerCard(at: sample.sampledAt.addingTimeInterval(-0.1)).value, card.value)
        XCTAssertEqual(view.powerCard(at: sample.sampledAt.addingTimeInterval(11)).value, "—")
        XCTAssertEqual(view.powerCard(at: sample.sampledAt.addingTimeInterval(11)).detail, String(localized: "No current reading"))
        monitor.pause()
        XCTAssertEqual(view.powerCard(at: .now).value, "—")
    }

    @MainActor
    func testCardDistinguishesMeasuredZeroFromMissingSystemSensor() async {
        for watts: Double? in [0, nil] {
            var sample = PowerSnapshot(readings: [.cpu: PowerReading(watts: 12, source: "IOReport · CPU Energy")])
            sample.readings[.system] = watts.map { PowerReading(watts: $0, source: "SMC · PSTR") }
            let captured = sample
            let monitor = PowerMonitor { captured }
            let view = OverviewContent(powerMonitor: monitor)
            XCTAssertEqual(view.powerCard(at: .now).value, "—")
            await monitor.refresh()
            XCTAssertEqual(view.powerCard(at: .now).value, watts == nil ? "—" : "0.00 W")
        }
    }

    @MainActor
    func testOverviewFitsBothAppearancesAndRefreshesPowerWithMetrics() async throws {
        for width: CGFloat in [720, 950] {
            for dark in [false, true] {
                let sample = PowerSnapshot(readings: [.system: PowerReading(watts: 28, source: "SMC · PSTR")])
                let monitor = PowerMonitor { sample }
                let model = AppModel()
                let host = NSHostingView(rootView: OverviewContent(powerMonitor: monitor)
                    .environmentObject(model).preferredColorScheme(dark ? .dark : .light))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.frame = window.contentView!.bounds
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(20))
                    host.layoutSubtreeIfNeeded()
                }
                XCTAssertLessThanOrEqual(host.fittingSize.width, width)
                XCTAssertTrue(model.sectionRefresh.canRefresh(.overview))
                XCTAssertFalse(monitor.hasSampled)
                await model.sectionRefresh.refresh(.overview)
                XCTAssertTrue(monitor.hasSampled)
                XCTAssertEqual(monitor.snapshot.readings[.system]?.watts, 28)
                XCTAssertEqual(model.processorHistory.samples.last, model.snapshot)
                XCTAssertFalse(model.isRefreshingMetrics)
                XCTAssertFalse(monitor.isRefreshing)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width)
            }
        }
    }
}
