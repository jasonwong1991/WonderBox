import AppKit
import CSMC
import SwiftUI
import XCTest
@testable import WonderBox

final class PowerTests: XCTestCase {
    func testEnergyUnitsUseActualElapsedTime() {
        for (unit, value) in [("J", Int64(12)), ("mJ", 12_000), ("uJ", 12_000_000), ("µJ", 12_000_000), ("nJ", 12_000_000_000)] {
            XCTAssertEqual(EnergyCounter(channel: "CPU Energy", unit: unit, value: value).watts(elapsed: 3), 4, unit)
        }
        XCTAssertEqual(EnergyCounter(channel: "GPU", unit: "mJ", value: 0).watts(elapsed: 3), 0)
    }

    func testUnknownUnitsResetsAndInvalidIntervalsStayUnavailable() {
        for interval in [0, -1, 0.1, 11, .infinity, .nan] {
            XCTAssertNil(EnergyCounter(channel: "CPU Energy", unit: "mJ", value: 12_000).watts(elapsed: interval))
        }
        XCTAssertNil(EnergyCounter(channel: "CPU Energy", unit: "mW", value: 12).watts(elapsed: 3))
        XCTAssertNil(EnergyCounter(channel: "CPU Energy", unit: "mJ", value: -1).watts(elapsed: 3))
        XCTAssertNil(EnergyCounter(channel: "CPU Energy", unit: "J", value: .max).watts(elapsed: 3))
    }

    func testOnlyAggregateChannelsAreUsedWithoutDoubleCounting() {
        let readings = PowerClassifier.readings(energy: [
            EnergyCounter(channel: "CPU Energy", unit: "mJ", value: 30_000),
            EnergyCounter(channel: "EACC_CPU", unit: "mJ", value: 9_000),
            EnergyCounter(channel: "PACC0_CPU", unit: "mJ", value: 21_000),
            EnergyCounter(channel: "GPU Energy", unit: "nJ", value: 6_000_000_000),
            EnergyCounter(channel: "GPU", unit: "mJ", value: 6_000)
        ], elapsed: 3, smc: ["PSTR": 40, "PCPC": 25, "PG0R": 8, "PDTR": 100])
        XCTAssertEqual(readings[.cpu]?.watts, 10)
        XCTAssertEqual(readings[.gpu]?.watts, 2)
        XCTAssertEqual(readings[.system]?.watts, 40)
        XCTAssertEqual(readings[.gpu]?.source, "IOReport · GPU Energy")
        XCTAssertFalse(readings[.cpu]!.isCPUPackage)
        XCTAssertTrue(PowerClassifier.readings(energy: [], elapsed: 3, smc: ["PDTR": 100, "PPBR": 10, "PC0C": 5]).isEmpty)
    }

    func testSMCFallbacksKeepPackageScopeAndPreferTotalsInsteadOfAddingAliases() {
        let readings = PowerClassifier.readings(energy: [], elapsed: 0, smc: ["PSTR": 40, "PCPC": 15, "PCPR": 16, "PG0R": 3, "PG1R": 2, "PCGC": 1])
        XCTAssertEqual(readings[.cpu]?.watts, 15)
        XCTAssertTrue(readings[.cpu]!.isCPUPackage)
        XCTAssertEqual(readings[.gpu]?.watts, 5)
        XCTAssertEqual(PowerClassifier.readings(energy: [], elapsed: 0, smc: ["PCTR": 12, "PCPC": 18])[.cpu]?.watts, 12)
        XCTAssertNil(PowerClassifier.readings(energy: [], elapsed: 0, smc: ["PG0R": 3, "PG1R": .nan])[.gpu])
    }

    func testDuplicateChannelsAndZeroAreHandledConservatively() {
        let duplicated = [EnergyCounter](repeating: EnergyCounter(channel: "CPU Energy", unit: "mJ", value: 3000), count: 2)
        XCTAssertNil(PowerClassifier.readings(energy: duplicated, elapsed: 3, smc: [:])[.cpu])
        let idle = PowerClassifier.readings(energy: [EnergyCounter(channel: "GPU", unit: "mJ", value: 0)], elapsed: 3, smc: ["PSTR": 0])
        XCTAssertEqual(idle[.system]?.watts, 0)
        XCTAssertEqual(idle[.gpu]?.watts, 0)
        XCTAssertEqual(PowerReading.formatted(nil), "—")
    }

    func testPowerSMCDecoderHandlesFloatAndFixedPointWithoutIntegerFallback() {
        func decode(_ type: String, _ bytes: [UInt8]) -> Double {
            type.withCString { type in bytes.withUnsafeBufferPointer { wc_smc_decode_power(type, $0.baseAddress, Int32($0.count)) } }
        }
        XCTAssertEqual(decode("sp78", [0x0c, 0x80]), 12.5)
        XCTAssertEqual(decode("sp96", [0x03, 0x20]), 12.5)
        XCTAssertEqual(decode("fp88", [0x0c, 0x80]), 12.5)
        XCTAssertEqual(decode("fpe2", [0x00, 0x32]), 12.5)
        var value: Float = 12.5
        XCTAssertEqual(withUnsafeBytes(of: &value) { decode("flt ", Array($0)) }, 12.5)
        XCTAssertEqual(decode("sp78", [0, 0]), 0)
        for (type, bytes) in [("ui16", [UInt8(0), 10]), ("sp78", [255, 0]), ("sp79", [0, 10]), ("flt ", [0, 10]), ("fpzz", [0, 10])] {
            XCTAssertTrue(decode(type, bytes).isNaN, type)
        }
    }

    func testHistoryRetainsOneHourAndManualRefreshesStayBounded() {
        var history = PowerHistory()
        for second in stride(from: 0, through: 7200, by: 3) { history.append(sample(Double(second))) }
        XCTAssertEqual(history.samples.count, 1201)
        XCTAssertEqual(history.samples.first?.sampledAt, date(3600))
        XCTAssertEqual(history.points(for: .cpu, range: .minute, endingAt: date(7200)).count, 21)
        XCTAssertEqual(history.points(for: .cpu, range: .quarterHour, endingAt: date(7200)).count, 301)
        for tick in 0..<10_000 { history.append(sample(7200 + Double(tick) / 10_000)) }
        XCTAssertLessThanOrEqual(history.samples.count, 1202)
        XCTAssertTrue(history.samples.allSatisfy { $0.readings[.cpu]?.watts == 12 })
    }

    func testHistoryDoesNotJoinMissingSensorsSleepOrSourceChanges() {
        var history = PowerHistory()
        history.append(sample(0))
        history.append(PowerSnapshot(sampledAt: date(3)))
        history.append(sample(6, watts: 0))
        history.append(sample(30))
        history.append(sample(33, source: "SMC · PCPC"))
        let points = history.points(for: .cpu, range: .minute, endingAt: date(33))
        XCTAssertEqual(points.map(\.watts), [12, 0, 12, 12])
        XCTAssertEqual(Set(points.map(\.segment)).count, 4)
        XCTAssertTrue(history.points(for: .gpu, range: .minute, endingAt: date(33)).isEmpty)
        XCTAssertTrue(history.points(for: .cpu, range: .minute, endingAt: date(100)).isEmpty)
        history.append(PowerSnapshot(sampledAt: date(33.2)))
        history.append(sample(33.4, source: "SMC · PCPC"))
        let afterShortPause = history.points(for: .cpu, range: .minute, endingAt: date(34))
        XCTAssertNotEqual(afterShortPause.suffix(2).first?.segment, afterShortPause.last?.segment,
                          "Coalescing fast refreshes must preserve a short pause's missing-data marker")
    }

    func testHistoryClockChangesAndInvalidValues() {
        var history = PowerHistory()
        history.append(sample(100))
        history.append(sample(100, watts: 8))
        XCTAssertEqual(history.samples.count, 1)
        history.append(sample(50))
        XCTAssertEqual(history.samples.count, 1)
        for (i, value) in [Double.nan, .infinity, -1, 2001].enumerated() { history.append(sample(53 + Double(i) * 3, watts: value)) }
        XCTAssertEqual(history.points(for: .cpu, range: .minute, endingAt: date(70)).count, 1)
        XCTAssertNil(sample(50).reading(.cpu, at: date(61)))
        XCTAssertNil(sample(50).reading(.cpu, at: date(49)))
        XCTAssertNotNil(sample(50).reading(.cpu, at: date(60)))
    }

    func testTimeWeightedAverageExcludesGapsAndDownsamplingPreservesPeaks() throws {
        var history = PowerHistory()
        for second in 0...3600 { history.append(sample(Double(second), watts: second == 1201 ? 100 : 10)) }
        let raw = history.points(for: .cpu, range: .hour, endingAt: date(3600))
        let drawn = PowerHistory.chartPoints(raw, range: .hour)
        XCTAssertLessThan(drawn.count, 1000)
        XCTAssertEqual(drawn.map(\.watts).max(), 100)
        XCTAssertEqual(drawn.first?.date, raw.first?.date)
        XCTAssertEqual(drawn.last?.date, raw.last?.date)
        XCTAssertEqual(Set(drawn.map(\.date)).count, drawn.count)
        XCTAssertEqual(try XCTUnwrap(PowerHistory.average(raw)), 10.025, accuracy: 0.0001)
        let disconnected = [PowerHistoryPoint(date: date(0), watts: 10, segment: 0),
                            PowerHistoryPoint(date: date(3), watts: 20, segment: 0),
                            PowerHistoryPoint(date: date(30), watts: 100, segment: 1)]
        XCTAssertEqual(PowerHistory.average(disconnected), 15)
        XCTAssertNil(PowerHistory.average([]))
    }

    @MainActor
    func testMonitorCoalescesRefreshAndRetainsUnavailableSamples() async {
        let gate = PowerSampleGate()
        let monitor = PowerMonitor { await gate.sample() }
        let first = Task { await monitor.refresh() }
        while !(await gate.started) { await Task.yield() }
        XCTAssertTrue(monitor.isRefreshing)
        await monitor.refresh()
        await gate.finish(PowerSnapshot())
        await first.value
        XCTAssertTrue(monitor.hasSampled)
        XCTAssertFalse(monitor.isRefreshing)
        XCTAssertEqual(monitor.history.samples.count, 1)
        XCTAssertTrue(monitor.snapshot.readings.isEmpty)
        await monitor.refresh()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCancelledRefreshDoesNotPublishLatePower() async {
        let gate = PowerSampleGate()
        let monitor = PowerMonitor { await gate.sample() }
        let task = Task { await monitor.refresh() }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.finish(PowerSnapshot())
        await task.value
        XCTAssertFalse(monitor.hasSampled)
        XCTAssertTrue(monitor.history.samples.isEmpty)
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    func testPausingRejectsInFlightSamplesEvenDuringAShortPause() async {
        let gate = PowerSampleGate()
        let monitor = PowerMonitor { await gate.sample() }
        let task = Task { await monitor.refresh() }
        while !(await gate.started) { await Task.yield() }
        monitor.pause()
        await gate.finish(PowerSnapshot(readings: [.cpu: PowerReading(watts: 10, source: "fixture")]))
        await task.value
        XCTAssertFalse(monitor.hasSampled)
        XCTAssertTrue(monitor.snapshot.readings.isEmpty)
        let resumed = Task { await monitor.refresh() }
        while !(await gate.started) { await Task.yield() }
        await gate.finish(PowerSnapshot(readings: [.cpu: PowerReading(watts: 12, source: "fixture")]))
        await resumed.value
        XCTAssertEqual(monitor.snapshot.readings[.cpu]?.watts, 12)
        monitor.pause()
        XCTAssertTrue(monitor.snapshot.readings.isEmpty)
        XCTAssertTrue(monitor.history.samples.last!.readings.isEmpty)
    }

    @MainActor
    func testFullPowerPageLayoutAndRefreshRegistration() async throws {
        let value = PowerSnapshot(readings: [
            .system: PowerReading(watts: 32.5, source: "SMC · PSTR"),
            .cpu: PowerReading(watts: 12, source: "IOReport · CPU Energy"),
            .gpu: PowerReading(watts: 2.3, source: "IOReport · GPU Energy")
        ], fans: [FanReading(id: 0, name: "Fan 1", currentRPM: 1400, minimumRPM: 1200, maximumRPM: 6000)])
        let monitor = PowerMonitor { value }
        await monitor.refresh()
        let model = AppModel()
        XCTAssertEqual(AppSection(rawValue: "power"), .power)
        for width: CGFloat in [720, 950] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: PowerContent(monitor: monitor, isMonitoring: true)
                    .environmentObject(model).background(Color.appBackground).preferredColorScheme(dark ? .dark : .light))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.frame = window.contentView!.bounds
                for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
                XCTAssertEqual(host.frame.width, width)
                XCTAssertLessThanOrEqual(host.fittingSize.width, width)
                XCTAssertTrue(model.sectionRefresh.canRefresh(.power))
                if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-power-page-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                window.contentView = nil
            }
        }
    }

    func testLivePowerSamplingIsReadOnlyAndReturnsValidatedSources() async throws {
        let sampler = PowerSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(600))
        let snapshot = await sampler.sample()
        for reading in snapshot.readings.values {
            XCTAssertTrue(reading.watts.isFinite && (0...2000).contains(reading.watts))
            XCTAssertTrue(reading.source.hasPrefix("IOReport · ") || reading.source.hasPrefix("SMC · "))
        }
        print("Read-only power sample: \(snapshot.readings)")
        // Sensors are hardware-dependent, so an empty result is valid on unsupported/sandboxed hosts.
    }

    @MainActor
    func testPowerChartFitsCompactAndLargeWindowsInBothAppearances() throws {
        var history = PowerHistory()
        let end = Date()
        for second in stride(from: -3600, through: 0, by: 3) {
            history.append(PowerSnapshot(sampledAt: end.addingTimeInterval(Double(second)), readings: [.system: PowerReading(watts: 20 + sin(Double(second) / 12) * 8, source: "SMC · PSTR")]))
        }
        for width: CGFloat in [600, 1000] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: PowerHistoryCard(history: history, component: .constant(.system), range: .constant(.hour), end: end)
                    .preferredColorScheme(dark ? .dark : .light))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 370), styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.frame = window.contentView!.bounds
                for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 370)
                if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-power-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                window.contentView = nil
            }
        }
    }
    private func date(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }
    private func sample(_ second: Double, watts: Double = 12, source: String = "IOReport · CPU Energy") -> PowerSnapshot {
        PowerSnapshot(sampledAt: date(second), readings: [.cpu: PowerReading(watts: watts, source: source)])
    }
}

private actor PowerSampleGate {
    private var continuation: CheckedContinuation<PowerSnapshot, Never>?
    private(set) var calls = 0
    var started: Bool { continuation != nil }
    func sample() async -> PowerSnapshot {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ snapshot: PowerSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
