import AppKit
import SwiftUI

@main
struct WonderBoxApplication: App {
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accent") private var accent = AccentChoice.ocean.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("awakeDuration") private var awakeDuration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false
    @Environment(\.scenePhase) private var scenePhase

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedAccent: AccentChoice {
        AccentChoice(rawValue: accent) ?? .ocean
    }

    private var selectedAwakeDuration: AwakeDuration {
        AwakeDuration(rawValue: awakeDuration) ?? .oneHour
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .tint(selectedAccent.color)
                .frame(minWidth: 980, minHeight: 660)
                .onAppear { model.startMonitoring() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.startMonitoring()
                    } else if phase == .background {
                        model.stopMonitoring()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("工具") {
                Button("刷新状态") {
                    Task { await model.refreshMetrics() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(model.sleepPreventer.isActive ? "停止保持唤醒" : "持续保持唤醒") {
                    if model.sleepPreventer.isActive {
                        model.sleepPreventer.disable()
                    } else {
                        model.sleepPreventer.enable(
                            duration: selectedAwakeDuration.seconds,
                            keepDisplayAwake: keepDisplayAwake
                        )
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContentView(preventer: model.sleepPreventer, optimizer: model.memoryOptimizer)
                .environmentObject(model)
                .preferredColorScheme(selectedAppearance.colorScheme)
        } label: {
            Image(nsImage: MenuBarAppIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var preventer: SleepPreventer
    @ObservedObject var optimizer: MemoryOptimizer
    @AppStorage("awakeDuration") private var awakeDuration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false
    @State private var isRefreshing = false

    private var selectedAwakeDuration: AwakeDuration {
        AwakeDuration(rawValue: awakeDuration) ?? .oneHour
    }

    private var actionMessage: String? {
        model.quickActionMessage ?? optimizer.message
    }

    private var actionMessageIsError: Bool {
        model.quickActionMessage == nil && optimizer.messageIsError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WonderBox")
                        .font(.headline)
                    Text(model.systemInfo.computerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: model.snapshot.thermalState == .nominal ? "温控正常" : "温度较高",
                    color: model.snapshot.thermalState == .nominal ? .healthy : .warning
                )
                Button {
                    Task { await refreshStatus() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .disabled(isRefreshing)
                .help("刷新状态")
                .accessibilityLabel("刷新菜单栏状态")
            }

            HStack(spacing: 8) {
                MenuMetric(title: "CPU", value: AppFormatters.percent(model.snapshot.cpuUsage))
                MenuMetric(title: "内存", value: AppFormatters.percent(model.snapshot.memoryFraction))
                MenuMetric(title: "磁盘", value: AppFormatters.percent(model.snapshot.diskFraction))
            }

            fanSummary

            Button {
                if preventer.isActive {
                    preventer.disable()
                } else {
                    preventer.enable(
                        duration: selectedAwakeDuration.seconds,
                        keepDisplayAwake: keepDisplayAwake
                    )
                }
            } label: {
                Label(
                    preventer.isActive
                        ? "停止保持唤醒 · \(preventer.remainingText)"
                        : "保持唤醒 · \(selectedAwakeDuration.title)",
                    systemImage: preventer.isActive ? "moon.zzz.fill" : "moon.zzz"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                MenuQuickAction(
                    title: "优化内存",
                    symbol: "memorychip",
                    isWorking: optimizer.isOptimizing,
                    isDisabled: model.isQuickCleaning,
                    action: { Task { await model.optimizeMemory() } }
                )
                MenuQuickAction(
                    title: "一键清理",
                    symbol: "sparkles",
                    isWorking: model.isQuickCleaning,
                    isDisabled: optimizer.isOptimizing,
                    action: { Task { await model.quickClean() } }
                )
            }

            if let actionMessage {
                HStack(spacing: 8) {
                    Image(systemName: actionMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(actionMessageIsError ? Color.warning : Color.healthy)
                    Text(actionMessage)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button {
                        model.dismissQuickActionMessage()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭消息")
                }
                .padding(9)
                .background((actionMessageIsError ? Color.warning : Color.healthy).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Divider()

            HStack {
                Button {
                    openApp()
                } label: {
                    Label("打开完整应用", systemImage: "macwindow")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                Spacer()
                Button {
                    model.selection = .settings
                    openApp()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("设置")
                .accessibilityLabel("打开设置")
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 360)
        .task { await refreshStatus() }
    }

    private var fanSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("风扇转速", systemImage: "fan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.fans.isEmpty ? "未检测到" : "\(model.fans.count) 个风扇")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !model.fans.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(model.fans.prefix(2))) { fan in
                        HStack(spacing: 6) {
                            Text(fan.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(fan.currentRPM.rounded())) RPM")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func refreshStatus() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshMetrics()
        await model.refreshFans()
        isRefreshing = false
    }

    private func openApp() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuQuickAction: View {
    let title: String
    let symbol: String
    let isWorking: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(isWorking ? "正在处理" : title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
        .background(Color.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.separatorSoft, lineWidth: 1)
        }
        .disabled(isWorking || isDisabled)
    }
}

private enum MenuBarAppIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.125, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 17, height: 17), xRadius: 4, yRadius: 4).fill()

            let tiles: [(NSRect, NSColor)] = [
                (NSRect(x: 3.5, y: 9.5, width: 5, height: 5), NSColor(calibratedRed: 0.19, green: 0.47, blue: 0.96, alpha: 1)),
                (NSRect(x: 9.5, y: 9.5, width: 5, height: 5), NSColor(calibratedRed: 0.075, green: 0.65, blue: 0.55, alpha: 1)),
                (NSRect(x: 3.5, y: 3.5, width: 5, height: 5), NSColor(calibratedRed: 0.9, green: 0.37, blue: 0.4, alpha: 1)),
                (NSRect(x: 9.5, y: 3.5, width: 5, height: 5), NSColor(calibratedRed: 0.94, green: 0.63, blue: 0.2, alpha: 1))
            ]
            for (tile, color) in tiles {
                color.setFill()
                NSBezierPath(roundedRect: tile, xRadius: 1.4, yRadius: 1.4).fill()
            }
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.25, y: 7.25, width: 3.5, height: 3.5)).fill()
            NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.125, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 8.25, y: 8.25, width: 1.5, height: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

private struct MenuMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
