import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accent") private var accent = AccentChoice.ocean.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "设置", subtitle: "外观与启动行为")

                settingsSection("外观", symbol: "paintbrush") {
                    settingRow("主题") {
                        Picker("主题", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Divider()

                    settingRow("强调色") {
                        HStack(spacing: 12) {
                            ForEach(AccentChoice.allCases) { choice in
                                Button {
                                    accent = choice.rawValue
                                } label: {
                                    ZStack {
                                        Circle().fill(choice.color)
                                        if accent == choice.rawValue {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help(choice.title)
                                .accessibilityLabel(choice.title)
                            }
                        }
                    }
                }

                settingsSection("常驻", symbol: "menubar.rectangle") {
                    Toggle(isOn: $showMenuBar) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("菜单栏快捷入口")
                            Text("状态概览与保持唤醒")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录时启动")
                            Text("使用 macOS Service Management")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = launchAtLogin.message {
                    InlineMessage(text: message, isError: true)
                }

                settingsSection("权限与构建", symbol: "lock.shield") {
                    capabilityRow("App Store 核心功能", status: "公有 API", color: .healthy)
                    Divider()
                    capabilityRow("风扇控制", status: FanController.isAvailable ? "Direct 可用" : "当前不可用", color: FanController.isAvailable ? .warning : .secondary)
                    Divider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完全磁盘访问")
                            Text(model.supportsFullDiskAccess
                                ? "直接分析主目录与受保护文件夹"
                                : "App Store 版本使用用户选择的目录权限")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            text: model.fullDiskAccessStatus.title,
                            color: fullDiskAccessColor,
                            symbol: model.fullDiskAccessStatus == .authorized ? "checkmark.shield" : "lock"
                        )
                        Button {
                            model.refreshFullDiskAccessStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("重新检查授权状态")
                        .accessibilityLabel("重新检查完全磁盘访问状态")
                        Button("完全授权") { model.openFullDiskAccessSettings() }
                            .disabled(!model.supportsFullDiskAccess)
                    }
                }

                HStack {
                    Image(systemName: "checkmark.shield")
                    Text("所有扫描结果仅在本机处理")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear { model.refreshFullDiskAccessStatus() }
    }

    private var fullDiskAccessColor: Color {
        switch model.fullDiskAccessStatus {
        case .authorized: .healthy
        case .denied: .warning
        case .unavailable: .secondary
        }
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .appPanel()
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private func capabilityRow(_ title: String, status: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            StatusPill(text: status, color: color)
        }
    }
}
