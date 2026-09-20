import CSMC
import Foundation

typealias FanApplyResult = PrivilegedServiceResult

enum FanController {
    static var isAvailable: Bool {
        wc_smc_is_available() == 1
    }

    static func readFans() -> [FanReading] {
        let count = max(0, min(8, Int(wc_smc_fan_count())))
        return (0..<count).compactMap { index in
            var raw = WCFanReading()
            guard wc_smc_read_fan(Int32(index), &raw) == 0,
                  raw.current_rpm.isFinite,
                  (0...20_000).contains(raw.current_rpm)
            else { return nil }
            return FanReading(
                id: index,
                name: count == 1 ? "主风扇" : "风扇 \(index + 1)",
                currentRPM: raw.current_rpm,
                minimumRPM: raw.minimum_rpm,
                maximumRPM: raw.maximum_rpm
            )
        }
    }

    @MainActor
    static func apply(mode: FanMode, customRPM: Double, fans: [FanReading]) async -> FanApplyResult {
        guard !fans.isEmpty else {
            return FanApplyResult(succeeded: false, message: "当前机型未开放 SMC 风扇控制")
        }

        let command: String
        if mode == .automatic {
            command = "set-auto"
        } else {
            let target = targetRPM(for: mode, customRPM: customRPM, fans: fans)
            command = "set-rpm \(Int(target.rounded()))"
        }

        let service = await PrivilegedService.ensureReady()
        guard service.succeeded else { return service }
        let reply = await Task.detached(priority: .userInitiated) { PrivilegedService.send(command) }.value
        switch reply {
        case let .success(message):
            let fallback = mode == .automatic ? "已恢复系统自动控制，转速将由温控系统调节" : "风扇模式已应用"
            return FanApplyResult(succeeded: true, message: message.isEmpty ? fallback : message)
        case let .failure(message):
            return FanApplyResult(succeeded: false, message: message)
        case .unavailable:
            return FanApplyResult(succeeded: false, message: "后台风扇服务连接已中断")
        }
    }

    private static func targetRPM(for mode: FanMode, customRPM: Double, fans: [FanReading]) -> Double {
        let minimum = fans.map(\.minimumRPM).filter { $0 > 0 }.max() ?? 1_200
        let maximum = fans.map(\.maximumRPM).filter { $0 > minimum }.min() ?? 6_000
        let fraction: Double
        switch mode {
        case .quiet: fraction = 0.18
        case .balanced: fraction = 0.48
        case .performance: fraction = 0.82
        case .custom, .automatic: return min(maximum, max(minimum, customRPM))
        }
        return minimum + (maximum - minimum) * fraction
    }
}
