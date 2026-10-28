import SwiftUI

struct AutomaticCleanupSettings: View {
    @ObservedObject var controller: AutomaticCleanupController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Automatic Cleanup", isOn: $controller.policy.enabled)
                .font(.headline)
            Text("Only rebuildable caches belonging to idle apps are cleaned. Downloads, app data, messaging caches and the Trash are never included. Runs every five minutes while WonderBox is open, including in the menu bar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Clean when", selection: $controller.policy.trigger) {
                ForEach(AutomaticCleanupPolicy.Trigger.allCases) { trigger in Text(trigger.title).tag(trigger) }
            }
            if controller.policy.trigger != .interval {
                Picker("Cache threshold", selection: $controller.policy.thresholdMB) {
                    ForEach([128, 256, 512, 1024, 2048, 5120, 10240, 51200, 102400], id: \.self) { size in
                        Text(AppFormatters.memory(UInt64(size) * 1_048_576)).tag(size)
                    }
                }
            }
            if controller.policy.trigger != .size {
                Picker("Clean every", selection: $controller.policy.intervalHours) {
                    ForEach([1, 6, 12, 24, 72, 168, 720], id: \.self) { hours in Text("\(hours) hours").tag(hours) }
                }
            }
            if let date = controller.lastRun {
                LabeledContent("Last automatic cleanup", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.isRunning { ProgressView("Checking caches…").controlSize(.small) }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4).help(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel()
    }
}

struct UninstallWatcherSettings: View {
    @ObservedObject var controller: UninstallWatcherController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Uninstall Watcher Plugin", systemImage: "trash.circle").font(.headline)
            Text("Watch /Applications and ~/Applications. After an app is deleted or moved to the Trash, ask whether to remove its related files. This optional login item works even when WonderBox is closed; no files are removed without confirmation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(controller.requiresApproval ? "Waiting for macOS approval" : controller.isInstalled ? "Installed" : "Not installed")
                    .font(.subheadline)
                Spacer()
                if controller.isWorking { ProgressView().controlSize(.small) }
                if controller.isInstalled {
                    Button("Restart Plugin") { Task { await controller.restart() } }
                        .disabled(controller.isWorking)
                        .help("Restart after updating WonderBox to use the latest plugin")
                }
                Button(controller.isInstalled ? "Uninstall Plugin" : "Install Plugin") {
                    Task { await controller.setInstalled(!controller.isInstalled) }
                }
                .disabled(controller.isWorking || !UninstallWatcherController.isSupported)
            }
            if controller.requiresApproval {
                Button("Manage Login Items…") { controller.openSettings() }
            }
            if let message = controller.message { InlineMessage(text: message, isError: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel()
        .onAppear { controller.refresh() }
    }
}
