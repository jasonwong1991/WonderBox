import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    private var health: (title: String, detail: String, color: Color, symbol: String) {
        switch model.snapshot.thermalState {
        case .nominal:
            switch model.snapshot.memory.pressure {
            case .normal: ("状态良好", "温控与资源占用正常", .healthy, "checkmark.circle.fill")
            case .warning: ("内存压力偏高", "系统正在压缩内存，建议优化或退出高占用 App", .warning, "memorychip")
            case .critical: ("内存压力严重", "已大量使用交换空间，请立即释放内存", .critical, "exclamationmark.triangle.fill")
            }
        case .fair: ("轻度负载", "温控系统正在调节", .warning, "thermometer.medium")
        case .serious: ("负载较高", "建议关闭高占用任务", .warning, "thermometer.high")
        case .critical: ("温度警告", "请降低当前系统负载", .critical, "exclamationmark.triangle.fill")
        @unknown default: ("状态未知", "等待下一次系统采样", .secondary, "questionmark.circle")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "概览",
                    subtitle: "\(model.systemInfo.computerName) · \(model.systemInfo.operatingSystem)"
                )

                healthBanner

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                    MetricCard(
                        title: "处理器",
                        value: AppFormatters.percent(model.snapshot.cpuUsage),
                        detail: model.systemInfo.processorName,
                        symbol: "cpu",
                        tint: Color(hex: 0x3178F6),
                        progress: model.snapshot.cpuUsage,
                        history: model.cpuHistory
                    )
                    MetricCard(
                        title: "内存",
                        value: AppFormatters.percent(model.snapshot.memoryFraction),
                        detail: "已用 \(AppFormatters.memory(model.snapshot.memory.used)) · 已压缩 \(AppFormatters.memory(model.snapshot.memory.compressed))",
                        symbol: "memorychip",
                        tint: AppSection.memory.tint,
                        progress: model.snapshot.memoryFraction,
                        history: model.memoryHistory,
                        actionSymbol: "wand.and.stars",
                        actionHelp: "前往内存优化",
                        action: { model.selection = .memory }
                    )
                    MetricCard(
                        title: "磁盘",
                        value: AppFormatters.percent(model.snapshot.diskFraction),
                        detail: "可用 \(AppFormatters.bytes(model.snapshot.diskTotal - min(model.snapshot.diskTotal, model.snapshot.diskUsed)))",
                        symbol: "internaldrive",
                        tint: Color(hex: 0xE66756),
                        progress: model.snapshot.diskFraction,
                        actionSymbol: "magnifyingglass",
                        actionHelp: "扫描磁盘",
                        action: { model.selection = .storage }
                    )
                    MetricCard(
                        title: "网络",
                        value: AppFormatters.rate(model.snapshot.networkDownPerSecond),
                        detail: "上传 \(AppFormatters.rate(model.snapshot.networkUpPerSecond))",
                        symbol: "arrow.up.arrow.down",
                        tint: Color(hex: 0x13A58D)
                    )
                    if let battery = model.snapshot.batteryLevel {
                        MetricCard(
                            title: "电池",
                            value: AppFormatters.percent(battery),
                            detail: model.snapshot.isCharging ? "正在充电" : "使用电池供电",
                            symbol: model.snapshot.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                            tint: battery < 0.2 ? .critical : .healthy,
                            progress: battery
                        )
                    }
                    MetricCard(
                        title: "运行时间",
                        value: AppFormatters.uptime(model.snapshot.uptime),
                        detail: model.systemInfo.modelIdentifier,
                        symbol: "clock.arrow.circlepath",
                        tint: Color(hex: 0xE1A127)
                    )
                }

                systemDetails
            }
            .padding(28)
            .frame(maxWidth: 1_160, alignment: .leading)
        }
    }

    private var healthBanner: some View {
        HStack(spacing: 15) {
            Image(systemName: health.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(health.color)
                .frame(width: 46, height: 46)
                .background(health.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(health.title)
                    .font(.headline)
                Text(health.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.isMonitoring ? "实时" : "暂停",
                color: model.isMonitoring ? .healthy : .secondary
            )
        }
        .appPanel(padding: 14)
    }

    private var systemDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设备信息")
                .font(.headline)
            Divider()
            detailRow("机型", model.systemInfo.modelIdentifier)
            detailRow("处理器", model.systemInfo.processorName)
            detailRow("架构", model.systemInfo.architecture)
            detailRow("系统", model.systemInfo.operatingSystem)
        }
        .appPanel()
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.subheadline)
    }
}
