import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }

    static let appBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.34)
    static let separatorSoft = Color.primary.opacity(0.09)
    static let healthy = Color(hex: 0x13A58D)
    static let warning = Color(hex: 0xE1A127)
    static let critical = Color(hex: 0xE45E65)
}

enum AppSpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum AppRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat = AppSpacing.medium

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .stroke(Color.separatorSoft, lineWidth: 1)
            }
    }
}

extension View {
    func appPanel(padding: CGFloat = AppSpacing.medium) -> some View {
        modifier(PanelModifier(padding: padding))
    }
}

enum AppFormatters {
    static let byteCount = makeByteCountFormatter(countStyle: .file)
    /// Binary units, matching Activity Monitor for RAM figures.
    static let memoryByteCount = makeByteCountFormatter(countStyle: .memory)

    static let compactDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        byteCount.string(fromByteCount: Int64(clamping: value))
    }

    static func memory(_ value: UInt64) -> String {
        memoryByteCount.string(fromByteCount: Int64(clamping: value))
    }

    static func signedMemory(_ delta: Int64) -> String {
        (delta < 0 ? "−" : "+") + memory(delta.magnitude)
    }

    static func rate(_ value: UInt64) -> String {
        "\(bytes(value))/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    private static func makeByteCountFormatter(countStyle: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = countStyle
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }
}
