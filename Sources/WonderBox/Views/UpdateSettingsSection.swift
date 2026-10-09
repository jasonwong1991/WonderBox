import SwiftUI

struct UpdateSettingsSection: View {
    @ObservedObject var updater: UpdateController
    @AppStorage(UpdateController.automaticKey) private var automaticChecks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Software Updates", systemImage: "arrow.down.circle")
                .font(.headline)
            HStack {
                Text("Installed version")
                Spacer()
                Text(updater.currentVersion).foregroundStyle(.secondary).monospacedDigit()
            }
            Divider()
            Toggle(isOn: $automaticChecks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates")
                    Text("Checks GitHub at most once a day. Downloads only when you choose.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: automaticChecks) { _, enabled in
                if enabled { updater.checkAutomaticallyIfNeeded() }
                else if updater.status == .checking { updater.cancel() }
            }

            if let date = updater.lastChecked {
                Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if updater.status == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").foregroundStyle(.secondary)
                }
            } else if updater.status == .current {
                Label("WonderBox is up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.healthy)
            } else if updater.status == .cancelled {
                Text("Update operation cancelled.").font(.caption).foregroundStyle(.secondary)
            }

            if let update = updater.update {
                Divider()
                Label(String(localized: "Version \(update.version) is available"), systemImage: "gift")
                    .font(.subheadline.weight(.semibold))
                if !update.notes.isEmpty {
                    DisclosureGroup("Release Notes") {
                        Text(update.notes)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                } else {
                    Text("View release notes on GitHub.").font(.caption).foregroundStyle(.secondary)
                }
                if updater.status == .downloading {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: updater.progress)
                            .accessibilityLabel("Update download progress")
                        Text(updater.progress < 1
                             ? String(localized: "Downloading… \(Int(updater.progress * 100))%")
                             : String(localized: "Verifying download…"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if updater.status == .downloaded {
                    Label("Download verified with SHA-256", systemImage: "checkmark.shield")
                        .foregroundStyle(Color.healthy)
                    Text("Quit WonderBox, unzip the download and replace the app in Applications. Updates are not installed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let message = updater.message {
                InlineMessage(text: message, isError: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
        .appPanel()
    }

    @ViewBuilder private var buttons: some View {
        if updater.isBusy {
            Button("Cancel") { updater.cancel() }
        } else {
            Button("Check for Updates…") { updater.check() }
            if updater.update != nil {
                if updater.status == .downloaded {
                    Button("Show in Finder") { updater.revealDownload() }
                } else {
                    Button("Download Update…") { updater.chooseDownloadLocation() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        Button("GitHub Releases") { updater.openReleasePage() }
    }
}
