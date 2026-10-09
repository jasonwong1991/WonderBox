import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DiagnosticsController: ObservableObject {
    @Published private(set) var summary = DiagnosticLogger.Summary()
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false
    private let logger: DiagnosticLogger
    init(logger: DiagnosticLogger = .shared) { self.logger = logger }

    func refresh() async {
        let logger = logger
        do {
            summary = try await Task.detached(priority: .utility, operation: { try logger.summary() }).value
        } catch {
            message = String(localized: "Diagnostic logs are unavailable. Check folder permissions.")
            messageIsError = true
        }
    }

    func setEnabled(_ enabled: Bool) {
        logger.setEnabled(enabled)
        Task { await refresh() }
    }

    func clear() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let logger = logger
        do {
            try await Task.detached(priority: .utility) { try logger.clear() }.value
            message = String(localized: "Local logs cleared.")
            messageIsError = false
        } catch {
            message = String(localized: "Logs could not be cleared. Check folder permissions.")
            messageIsError = true
        }
        await refresh()
    }

    func chooseExportLocation(version: String, build: String) {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "WonderBox-Diagnostics-\(formatter.string(from: Date())).zip"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Diagnostic Logs")
        panel.prompt = String(localized: "Export")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.export(to: url, version: version, build: build) }
        }
    }

    func export(to destination: URL, version: String, build: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let logger = logger
        do {
            try await Task.detached(priority: .utility) { try logger.export(to: destination, version: version, build: build) }.value
            message = String(localized: "Diagnostic logs exported. Share the ZIP with your issue report.")
            messageIsError = false
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            message = String(localized: "Logs could not be exported. Choose another location.")
            messageIsError = true
        }
        await refresh()
    }
}
