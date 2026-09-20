import SwiftUI

struct AwakeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AwakeContent(preventer: model.sleepPreventer)
    }
}

private struct AwakeContent: View {
    @ObservedObject var preventer: SleepPreventer
    @AppStorage("awakeDuration") private var duration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false

    private var selectedDuration: AwakeDuration {
        AwakeDuration(rawValue: duration) ?? .oneHour
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Keep Awake"), subtitle: String(localized: "Prevent idle sleep"))

                VStack(spacing: 22) {
                    Button {
                        if preventer.isActive {
                            preventer.disable()
                        } else {
                            preventer.enable(duration: selectedDuration.seconds, keepDisplayAwake: keepDisplayAwake)
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(preventer.isActive ? Color.healthy : Color.subtleBackground)
                            Circle()
                                .stroke(preventer.isActive ? Color.healthy.opacity(0.25) : Color.separatorSoft, lineWidth: 8)
                                .padding(-10)
                            Image(systemName: "power")
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(preventer.isActive ? .white : .secondary)
                        }
                        .frame(width: 138, height: 138)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(preventer.isActive ? "Stop Keeping Awake" : "Start Keeping Awake")

                    VStack(spacing: 5) {
                        Text(preventer.isActive ? "Your Mac Will Stay Awake" : "Automatic Sleep Allowed")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(preventer.isActive ? preventer.remainingText : String(localized: "Click the power button to start"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .appPanel()

                VStack(alignment: .leading, spacing: 18) {
                    Text("Options")
                        .font(.headline)

                    Picker("Duration", selection: $duration) {
                        ForEach(AwakeDuration.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(preventer.isActive)

                    Divider()

                    Toggle(isOn: $keepDisplayAwake) {
                        Label("Also keep the display awake", systemImage: "display")
                    }
                    .disabled(preventer.isActive)
                }
                .appPanel()

                if let error = preventer.lastError {
                    InlineMessage(text: error, isError: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}
