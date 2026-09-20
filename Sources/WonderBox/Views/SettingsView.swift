import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accent") private var accent = AccentChoice.ocean.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var language = AppLanguage.current
    @State private var showLanguageRelaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Settings"), subtitle: String(localized: "Appearance, language and startup"))

                settingsSection(String(localized: "Appearance"), symbol: "paintbrush") {
                    settingRow(String(localized: "Theme")) {
                        Picker("Theme", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Divider()

                    settingRow(String(localized: "Language")) {
                        Picker("Language", selection: $language) {
                            ForEach(AppLanguage.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: language) { _, selected in
                            guard selected != AppLanguage.current else { return }
                            selected.apply()
                            showLanguageRelaunch = true
                        }
                    }

                    Divider()

                    settingRow(String(localized: "Accent Color")) {
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

                settingsSection(String(localized: "Always Available"), symbol: "menubar.rectangle") {
                    Toggle(isOn: $showMenuBar) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Menu bar shortcut")
                            Text("Status overview and keep awake")
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
                            Text("Launch at login")
                            Text("Uses macOS Service Management")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = launchAtLogin.message {
                    InlineMessage(text: message, isError: true)
                }

                settingsSection(String(localized: "Permissions and Build"), symbol: "lock.shield") {
                    capabilityRow(String(localized: "App Store core features"), status: String(localized: "Public APIs"), color: .healthy)
                    Divider()
                    capabilityRow(String(localized: "Fan control"), status: FanController.isAvailable ? String(localized: "Direct build") : String(localized: "Unavailable"), color: FanController.isAvailable ? .warning : .secondary)
                    Divider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Disk Access")
                            Text(model.supportsFullDiskAccess
                                ? String(localized: "Analyze the home folder and protected folders directly")
                                : String(localized: "The App Store build uses user-selected folder access"))
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
                        .help("Re-check authorization")
                        .accessibilityLabel("Re-check Full Disk Access status")
                        Button("Grant Access") { model.openFullDiskAccessSettings() }
                            .disabled(!model.supportsFullDiskAccess)
                    }
                }

                HStack {
                    Image(systemName: "checkmark.shield")
                    Text("All scan results stay on this Mac")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear { model.refreshFullDiskAccessStatus() }
        .confirmationDialog(
            "Relaunch to change the language?",
            isPresented: $showLanguageRelaunch,
            titleVisibility: .visible
        ) {
            Button("Relaunch Now") { AppLanguage.relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The new language takes effect the next time WonderBox starts.")
        }
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
