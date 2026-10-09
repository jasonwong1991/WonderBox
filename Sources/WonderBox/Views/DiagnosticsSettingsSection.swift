import SwiftUI

struct DiagnosticsSettingsSection: View {
    @ObservedObject var diagnostics: DiagnosticsController
    let version: String
    let build: String
    @AppStorage(DiagnosticLogger.enabledKey) private var loggingEnabled = true
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Toggle(isOn: $loggingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep local diagnostic logs")
                    Text("Operation results and error codes only. No filenames, paths, account details or file contents.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(diagnostics.isWorking)
            .onChange(of: loggingEnabled) { _, enabled in diagnostics.setEnabled(enabled) }
            Text("Up to 2 MB, retained for 7 days. Turning logging off clears local logs. Nothing is uploaded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Local log size")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(diagnostics.summary.bytes), countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 10) {
                Button("Export Logs…") { diagnostics.chooseExportLocation(version: version, build: build) }
                    .disabled(diagnostics.isWorking)
                Button("Clear Logs…") { showClearConfirmation = true }
                    .disabled(diagnostics.isWorking || diagnostics.summary.files == 0)
                if diagnostics.isWorking { ProgressView().controlSize(.small) }
            }
            Text("Exports include app/macOS versions and CPU architecture. Review the ZIP before attaching it to a GitHub issue.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = diagnostics.message {
                InlineMessage(text: message, isError: diagnostics.messageIsError)
            }
        }
        .appPanel()
        .task { await diagnostics.refresh() }
        .confirmationDialog("Clear local diagnostic logs?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) { Task { await diagnostics.clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Previously exported ZIP files are kept.")
        }
    }
}
