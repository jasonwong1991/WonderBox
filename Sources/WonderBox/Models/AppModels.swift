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
        case .overview: String(localized: "Overview")
        case .memory: String(localized: "Memory")
        case .fan: String(localized: "Fan")
        case .awake: String(localized: "Keep Awake")
        case .applications: String(localized: "Uninstaller")
        case .cleaner: String(localized: "Cleanup")
        case .storage: String(localized: "Disk Analyzer")
        case .settings: String(localized: "Settings")
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
        case .automatic: String(localized: "Automatic")
        case .quiet: String(localized: "Quiet")
        case .balanced: String(localized: "Balanced")
        case .performance: String(localized: "Performance")
        case .custom: String(localized: "Custom")
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
        case .thirtyMinutes: String(localized: "30 Minutes")
        case .oneHour: String(localized: "1 Hour")
        case .twoHours: String(localized: "2 Hours")
        case .indefinitely: String(localized: "Indefinitely")
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
        case .name: String(localized: "Name")
        case .size: String(localized: "Size")
        case .installedAt: String(localized: "Install Date")
        case .lastUsedAt: String(localized: "Last Used")
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
        case .all: String(localized: "All")
        case .large: String(localized: "Large")
        case .stale: String(localized: "Stale")
        }
    }

    var detail: String {
        switch self {
        case .all: String(localized: "Show all applications")
        case .large: String(localized: "Show applications of 1 GB or more")
        case .stale: String(localized: "Show applications unused for 180 days or with no usage record")
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
        case .caches: String(localized: "App Caches")
        case .systemCaches: String(localized: "System Caches")
        case .logs: String(localized: "Logs")
        case .developer: String(localized: "Developer Caches")
        case .installers: String(localized: "Installers")
        case .applicationLeftovers: String(localized: "App Leftovers")
        case .deviceBackups: String(localized: "Device Backups")
        case .developerDeep: String(localized: "Deep Developer Caches")
        case .packageCaches: String(localized: "Package Manager Caches")
        case .browserCaches: String(localized: "Browser Caches")
        case .partialDownloads: String(localized: "Partial Downloads")
        case .trash: String(localized: "Trash")
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
        case .caches: String(localized: "Rebuildable cache data from apps and sandboxed containers")
        case .systemCaches: String(localized: "Shared system caches; requires administrator authorization")
        case .logs: String(localized: "Application and diagnostic logs")
        case .developer: "Xcode DerivedData"
        case .installers: String(localized: "Installer files downloaded more than 7 days ago")
        case .applicationLeftovers: String(localized: "Data left behind by uninstalled apps")
        case .deviceBackups: String(localized: "iPhone and iPad backups stored on this Mac")
        case .developerDeep: String(localized: "Simulator caches, device support files and documentation caches")
        case .packageCaches: String(localized: "Download caches for npm, pnpm, uv, Go, Cargo and more; rebuilt on the next install")
        case .browserCaches: String(localized: "Web caches of Chromium browsers and Electron apps; running apps are skipped")
        case .partialDownloads: String(localized: "Interrupted downloads older than 7 days")
        case .trash: String(localized: "Items in the Finder Trash")
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
        case .standard: String(localized: "Standard Scan")
        case .deep: String(localized: "Deep Clean")
        }
    }

    var detail: String {
        switch self {
        case .standard: String(localized: "Quick check of common caches, logs and installers")
        case .deep: String(localized: "Also checks app leftovers, device backups, developer data, package manager and browser caches")
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
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
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
        case .ocean: String(localized: "Ocean")
        case .mint: String(localized: "Mint")
        case .coral: String(localized: "Coral")
        case .violet: String(localized: "Violet")
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
