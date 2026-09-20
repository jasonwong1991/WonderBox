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
                PageHeader(title: "保持唤醒", subtitle: "防止空闲睡眠")

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
                    .accessibilityLabel(preventer.isActive ? "停止保持唤醒" : "开始保持唤醒")

                    VStack(spacing: 5) {
                        Text(preventer.isActive ? "Mac 将保持唤醒" : "当前允许自动睡眠")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(preventer.isActive ? preventer.remainingText : "点击电源按钮开启")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .appPanel()

                VStack(alignment: .leading, spacing: 18) {
                    Text("唤醒选项")
                        .font(.headline)

                    Picker("持续时间", selection: $duration) {
                        ForEach(AwakeDuration.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(preventer.isActive)

                    Divider()

                    Toggle(isOn: $keepDisplayAwake) {
                        Label("同时保持显示器点亮", systemImage: "display")
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
