import AppKit
import SwiftUI

@main
struct WonderBoxApplication: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(DockPresenceController.self) private var dockPresence
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accent") private var accent = AccentChoice.ocean.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage(MenuBarIconStyle.storageKey) private var menuBarIconStyle = MenuBarIconStyle.defaultStyle
    @AppStorage("awakeDuration") private var awakeDuration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

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
        // A single window: every window shares `model.selection`, so a second one would only mirror the first.
        Window("WonderBox", id: "main") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .tint(selectedAccent.color)
                .frame(minWidth: 980, minHeight: 660)
                .reportsMainWindow(to: dockPresence)
                .onAppear { model.startMonitoring(); model.startApplicationServices() }
                .onOpenURL { url in
                    guard url.scheme == "wonderbox", url.host == "uninstall-review" else { return }
                    dockPresence.willShowMainWindow()
                    openWindow(id: "main")
                    Task { await model.uninstallWatcher.checkPendingEvents() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.startMonitoring()
                        model.startApplicationServices()
                    } else if phase == .background {
                        model.stopMonitoring()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if UpdateController.isSupported {
                    Button("Check for Updates…") {
                        model.selection = .settings
                        dockPresence.willShowMainWindow()
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        model.updater.check()
                    }
                }
            }
            CommandMenu("Tools") {
                CurrentSectionRefreshButton(controller: model.sectionRefresh, section: model.selection ?? .overview)
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(model.sleepPreventer.isActive ? "Stop Keeping Awake" : "Keep Awake Indefinitely") {
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
                .environmentObject(dockPresence)
                .preferredColorScheme(selectedAppearance.colorScheme)
        } label: {
            Image(nsImage: MenuBarAppIcon.image(for: menuBarIconStyle))
                .accessibilityLabel("WonderBox")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dockPresence: DockPresenceController
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
                    text: model.snapshot.thermalState == .nominal ? String(localized: "Thermals Normal") : String(localized: "Running Hot"),
                    color: model.snapshot.thermalState == .nominal ? .healthy : .warning
                )
                Button {
                    Task { await refreshStatus(); await model.refreshQuickCleanEstimate(force: true) }
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
                .help("Refresh Status")
                .accessibilityLabel("Refresh menu bar status")
            }

            HStack(spacing: 8) {
                MenuMetric(title: "CPU", value: AppFormatters.percent(model.snapshot.cpuUsage))
                MenuMetric(title: String(localized: "Memory"), value: AppFormatters.percent(model.snapshot.memoryFraction))
                MenuMetric(title: String(localized: "Disk"), value: AppFormatters.percent(model.snapshot.diskFraction))
            }

            HStack(spacing: 8) {
                MenuMetric(title: String(localized: "CPU Temperature"), value: TemperatureReading.summary(model.temperatures))
                MenuMetric(title: String(localized: "GPU Temperature"), value: TemperatureReading.summary(model.temperatures, gpu: true))
            }
            .help("Highest available sensor reading; unavailable sensors show a dash")

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
                        ? String(localized: "Stop Keeping Awake · \(preventer.remainingText)")
                        : String(localized: "Keep Awake · \(selectedAwakeDuration.title)"),
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
                    title: String(localized: "Optimize Memory"),
                    symbol: "memorychip",
                    isWorking: optimizer.isOptimizing,
                    isDisabled: model.isQuickCleaning,
                    action: { Task { await model.optimizeMemory() } }
                )
                MenuQuickAction(
                    title: String(localized: "Quick Clean"),
                    symbol: "sparkles",
                    isWorking: model.isQuickCleaning,
                    isDisabled: optimizer.isOptimizing || model.isUninstallingApplication || model.isScanningStorage || model.isCleaningStorage || model.isEstimatingQuickClean,
                    action: { Task { await model.quickClean() } }
                )
            }

            Group {
                if model.isEstimatingQuickClean {
                    Label("Estimating reclaimable caches…", systemImage: "hourglass")
                } else if let estimate = model.quickCleanEstimate {
                    Label("Quick Clean · About \(AppFormatters.bytes(estimate)) reclaimable", systemImage: "externaldrive.badge.checkmark")
                } else {
                    Label("Cache estimate not available yet", systemImage: "externaldrive")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .help("Estimate includes the default Quick Clean categories; actual reclaimed space may vary")

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
                    .help("Dismiss message")
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
                    Label("Open Main Window", systemImage: "macwindow")
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
                .help("Settings")
                .accessibilityLabel("Open settings")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 360)
        .task {
            model.startApplicationServices()
            await refreshStatus()
            await model.refreshQuickCleanEstimate()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await refreshStatus()
                await model.refreshQuickCleanEstimate()
            }
        }
    }

    private var fanSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Fan Speed", systemImage: "fan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.fans.isEmpty ? "Not detected" : "\(model.fans.count) fans")
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
        dockPresence.willShowMainWindow()
        openWindow(id: "main")
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
                Text(isWorking ? String(localized: "Working…") : title)
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
