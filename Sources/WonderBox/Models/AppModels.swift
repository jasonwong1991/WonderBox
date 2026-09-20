import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case memory
    case fan
    case awake
    case applications
    case cleaner
    case storage
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .memory: "内存"
        case .fan: "风扇"
        case .awake: "保持唤醒"
        case .applications: "应用卸载"
        case .cleaner: "空间清理"
        case .storage: "磁盘分析"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .memory: "memorychip"
        case .fan: "fan"
        case .awake: "moon.zzz"
        case .applications: "shippingbox"
        case .cleaner: "sparkles"
        case .storage: "internaldrive.fill"
        case .settings: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .overview: Color(hex: 0x3178F6)
        case .memory: Color(hex: 0xD4568F)
        case .fan: Color(hex: 0x13A58D)
        case .awake: Color(hex: 0xF18B43)
        case .applications: Color(hex: 0x7A67D8)
        case .cleaner: Color(hex: 0xE45E65)
        case .storage: Color(hex: 0xE1A127)
        case .settings: Color.secondary
        }
    }
}

struct MetricSnapshot: Equatable, Sendable {
    var cpuUsage: Double = 0
    var memory = MemoryBreakdown()
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var networkDownPerSecond: UInt64 = 0
    var networkUpPerSecond: UInt64 = 0
    var batteryLevel: Double? = nil
    var isCharging = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var sampledAt = Date()

    var memoryFraction: Double { memory.usedFraction }

    var diskFraction: Double {
        guard diskTotal > 0 else { return 0 }
        return min(1, Double(diskUsed) / Double(diskTotal))
    }
}

struct FanReading: Identifiable, Equatable, Sendable {
    let id: Int
    var name: String
    var currentRPM: Double
    var minimumRPM: Double
    var maximumRPM: Double
}

enum FanMode: String, CaseIterable, Identifiable {
    case automatic
    case quiet
    case balanced
    case performance
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "自动"
        case .quiet: "静音"
        case .balanced: "均衡"
        case .performance: "强劲"
        case .custom: "自定"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .quiet: "leaf"
        case .balanced: "dial.medium"
        case .performance: "bolt"
        case .custom: "slider.horizontal.3"
        }
    }
}

enum AwakeDuration: String, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case indefinitely

    var id: Self { self }

    var title: String {
        switch self {
        case .thirtyMinutes: "30 分钟"
        case .oneHour: "1 小时"
        case .twoHours: "2 小时"
        case .indefinitely: "持续"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .indefinitely: nil
        }
    }
}

struct InstalledApplication: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let size: UInt64
    let installedAt: Date?
    let lastUsedAt: Date?
}

enum ApplicationSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case installedAt
    case lastUsedAt

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "名称"
        case .size: "大小"
        case .installedAt: "安装日期"
        case .lastUsedAt: "最近使用"
        }
    }

    var symbol: String {
        switch self {
        case .name: "textformat"
        case .size: "internaldrive"
        case .installedAt: "calendar.badge.plus"
        case .lastUsedAt: "clock.arrow.circlepath"
        }
    }
}

enum ApplicationFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case large
    case stale

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .large: "大型"
        case .stale: "久未使用"
        }
    }

    var detail: String {
        switch self {
        case .all: "显示全部应用"
        case .large: "显示 1 GB 及以上的应用"
        case .stale: "显示超过 180 天未使用或无使用记录的应用"
        }
    }
}

struct RelatedFile: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let displayPath: String
    let size: UInt64
    var isSelected = true
}

enum CleanupKind: String, CaseIterable, Identifiable, Sendable {
    case caches
    case systemCaches
    case logs
    case developer
    case installers
    case applicationLeftovers
    case deviceBackups
    case developerDeep
    case packageCaches
    case browserCaches
    case partialDownloads
    case trash

    var id: Self { self }

    var title: String {
        switch self {
        case .caches: "应用缓存"
        case .systemCaches: "系统缓存"
        case .logs: "日志文件"
        case .developer: "开发缓存"
        case .installers: "安装包"
        case .applicationLeftovers: "应用残留"
        case .deviceBackups: "设备备份"
        case .developerDeep: "开发深层缓存"
        case .packageCaches: "包管理缓存"
        case .browserCaches: "浏览器缓存"
        case .partialDownloads: "未完成下载"
        case .trash: "废纸篓"
        }
    }

    var symbol: String {
        switch self {
        case .caches: "shippingbox.and.arrow.backward"
        case .systemCaches: "macwindow.badge.plus"
        case .logs: "doc.text.magnifyingglass"
        case .developer: "hammer"
        case .installers: "archivebox"
        case .applicationLeftovers: "app.dashed"
        case .deviceBackups: "iphone.and.arrow.forward"
        case .developerDeep: "wrench.and.screwdriver"
        case .packageCaches: "cube"
        case .browserCaches: "globe"
        case .partialDownloads: "arrow.down.doc"
        case .trash: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .caches: Color(hex: 0x2E8BFF)
        case .systemCaches: Color(hex: 0x13A58D)
        case .logs: Color(hex: 0xE1A127)
        case .developer: Color(hex: 0x7A67D8)
        case .installers: Color(hex: 0x13A58D)
        case .applicationLeftovers: Color(hex: 0xD16B3F)
        case .deviceBackups: Color(hex: 0x3178F6)
        case .developerDeep: Color(hex: 0x7A67D8)
        case .packageCaches: Color(hex: 0x7A67D8)
        case .browserCaches: Color(hex: 0x2E8BFF)
        case .partialDownloads: Color(hex: 0xE1A127)
        case .trash: Color(hex: 0xE45E65)
        }
    }

    var detail: String {
        switch self {
        case .caches: "应用与沙盒容器中可重建的缓存数据"
        case .systemCaches: "共享系统缓存，需要管理员授权"
        case .logs: "应用运行与诊断日志"
        case .developer: "Xcode DerivedData"
        case .installers: "下载超过 7 天的安装文件"
        case .applicationLeftovers: "已卸载应用遗留的数据"
        case .deviceBackups: "本机保存的 iPhone 与 iPad 备份"
        case .developerDeep: "模拟器缓存、设备支持文件与文档缓存"
        case .packageCaches: "npm、pnpm、uv、Go、Cargo 等下载缓存，安装时自动重建"
        case .browserCaches: "Chromium 浏览器与 Electron 应用的网页缓存，跳过运行中的应用"
        case .partialDownloads: "超过 7 天的中断下载"
        case .trash: "Finder 废纸篓中的项目"
        }
    }

    var isDeepOnly: Bool {
        switch self {
        case .applicationLeftovers, .deviceBackups, .developerDeep, .packageCaches, .browserCaches, .partialDownloads: true
        default: false
        }
    }

    var isSelectedByDefault: Bool {
        switch self {
        case .caches, .logs, .installers, .trash: true
        default: false
        }
    }

    var movesToTrash: Bool {
        switch self {
        case .installers, .applicationLeftovers, .deviceBackups, .developerDeep, .partialDownloads, .trash: true
        default: false
        }
    }

    static func kinds(for mode: CleanupScanMode) -> [CleanupKind] {
        allCases.filter { mode == .deep || !$0.isDeepOnly }
    }
}

enum CleanupScanMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case deep

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "标准扫描"
        case .deep: "深度清理"
        }
    }

    var detail: String {
        switch self {
        case .standard: "快速检查常见缓存、日志和安装文件"
        case .deep: "额外检查应用残留、设备备份、开发数据、包管理与浏览器缓存"
        }
    }
}

struct CleanupItem: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let size: UInt64
    var isSelected: Bool
    let modifiedAt: Date?
    let isDirectory: Bool
    /// False when the size estimate did not finish within the scan's time budget.
    let isSizeEstimated: Bool

    init(
        url: URL,
        size: UInt64,
        isSelected: Bool,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false,
        isSizeEstimated: Bool = true
    ) {
        self.url = url
        self.size = size
        self.isSelected = isSelected
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isSizeEstimated = isSizeEstimated
    }
}

struct CleanupCategory: Identifiable, Equatable, Sendable {
    var id: CleanupKind { kind }
    let kind: CleanupKind
    var size: UInt64
    var itemCount: Int
    var isSelected: Bool
    var locations: [URL]
    var items: [CleanupItem] = []
    var accessMessage: String? = nil

    /// Items whose size estimate timed out; the category total is a lower bound while any exist.
    var unsizedItemCount: Int {
        items.filter { !$0.isSizeEstimated }.count
    }

    var selectedSize: UInt64 {
        guard !items.isEmpty else { return isSelected ? size : 0 }
        return isSelected ? items.filter(\.isSelected).reduce(0) { $0 + $1.size } : 0
    }

    var selectedItemCount: Int {
        guard !items.isEmpty else { return isSelected ? itemCount : 0 }
        return isSelected ? items.filter(\.isSelected).count : 0
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case ocean
    case mint
    case coral
    case violet

    var id: Self { self }

    var title: String {
        switch self {
        case .ocean: "海蓝"
        case .mint: "薄荷"
        case .coral: "珊瑚"
        case .violet: "鸢尾"
        }
    }

    var color: Color {
        switch self {
        case .ocean: Color(hex: 0x3178F6)
        case .mint: Color(hex: 0x13A58D)
        case .coral: Color(hex: 0xE66756)
        case .violet: Color(hex: 0x7A67D8)
        }
    }
}
