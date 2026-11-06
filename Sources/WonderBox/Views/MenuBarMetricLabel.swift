import SwiftUI

struct MenuBarMetricLabel: View {
    let style: MenuBarIconStyle
    let options: MenuBarMetricOptions
    let snapshot: MenuBarMetricSnapshot

    var body: some View {
        let title = snapshot.title(options: options)
        HStack(spacing: 5) {
            Image(nsImage: MenuBarAppIcon.image(for: style))
            if !title.isEmpty {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? "WonderBox" : "WonderBox · " + title)
    }
}

struct MenuBarMetricSettings: View {
    var isEnabled = true
    @AppStorage(MenuBarMetricOptions.cpuKey) private var showCPU = false
    @AppStorage(MenuBarMetricOptions.memoryKey) private var showMemory = false
    @AppStorage(MenuBarMetricOptions.powerKey) private var showPower = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show CPU usage in menu bar", isOn: $showCPU)
                .accessibilityIdentifier("menubar.show-cpu")
            Toggle("Show memory usage in menu bar", isOn: $showMemory)
                .accessibilityIdentifier("menubar.show-memory")
            Toggle("Show system power in menu bar", isOn: $showPower)
                .accessibilityIdentifier("menubar.show-power")
            Text("CPU, RAM and system power refresh every 3 seconds, even with the main window closed. Turn off any value to save menu bar space. Power is shown in watts; unavailable sensors show —.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!isEnabled)
    }
}
