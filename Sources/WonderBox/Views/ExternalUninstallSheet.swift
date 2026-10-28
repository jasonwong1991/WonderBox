import AppKit
import SwiftUI
import WonderSupport

struct ExternalUninstallSheet: View {
    @EnvironmentObject private var model: AppModel
    let event: UninstallWatchEvent
    @ObservedObject var controller: UninstallWatcherController
    @StateObject private var review: ExternalUninstallReview
    @State private var isRemoving = false
    @State private var needsFullDiskAccess = false
    @State private var needsFinderPermission = false
    @State private var showConfirmation = false

    init(event: UninstallWatchEvent, controller: UninstallWatcherController, review: ExternalUninstallReview? = nil) {
        self.event = event; self.controller = controller
        _review = StateObject(wrappedValue: review ?? ExternalUninstallReview(event: event))
    }
    private var isWorking: Bool { review.isScanning || isRemoving }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Remove Related Files?", systemImage: "trash.circle").font(.title2.bold())
            Text("\(event.application.name) was removed from Applications. Review the files below; selected files will be moved to the Trash.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isWorking { ProgressView(isRemoving ? "Moving files to the Trash…" : "Checking related files…").controlSize(.small) }
            if let message = review.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(message) }
            if needsFullDiskAccess || review.cookieAccessRestricted { CookiePermissionGuidance() }
            if needsFinderPermission { FinderPermissionGuidance() }
            HStack {
                RelatedFileSelectionControls(selected: review.selectedCount, total: review.files.count, selectAll: review.selectAll)
                    .disabled(isWorking)
                Spacer()
                if review.isMeasuring { ProgressView().controlSize(.mini) }
                Text("\(review.selectedCount) of \(review.files.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach($review.files) { $file in
                    HStack {
                        Toggle(isOn: $file.isSelected) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.displayPath).lineLimit(2).help(file.url.path)
                                if file.association.requiresReview { Text("Review before removal").font(.caption).foregroundStyle(.orange) }
                            }
                        }.toggleStyle(.checkbox)
                        Spacer()
                        Text(file.sizeText).monospacedDigit().foregroundStyle(.secondary)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Show in Finder")
                    }
                }
            }
            .disabled(isWorking)
            HStack {
                Button("Keep Files") { controller.finish(event) }.keyboardShortcut(.cancelAction).disabled(isRemoving)
                Button("Rescan") { Task { await review.scan() } }.disabled(isWorking)
                Spacer()
                Text(review.selectedSizeText).monospacedDigit()
                Button("Move Selected to Trash", role: .destructive) { showConfirmation = true }
                    .disabled(isWorking || review.selectedCount == 0)
            }
        }
        .padding(24).frame(width: 700, height: 520)
        .interactiveDismissDisabled()
        .task { await review.loadIfNeeded() }
        .onDisappear { review.cancel() }
        .confirmationDialog("Move the selected related files to the Trash?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Move Selected to Trash", role: .destructive) { Task { await clean() } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func clean() async {
        guard model.beginExternalUninstall() else {
            review.message = String(localized: "Another cleanup is in progress. Try again shortly.")
            return
        }
        isRemoving = true
        defer { isRemoving = false; model.finishExternalUninstall() }
        needsFullDiskAccess = false; needsFinderPermission = false
        guard await UninstallWatcherController.canReview(event.application) else {
            review.message = String(localized: "The app is running, restored, reinstalled, or its removal could not be verified. No files were removed.")
            return
        }
        let selected = review.files.filter(\.isSelected).map(\.url)
        // Only the objects that were reviewed are eligible. No full discovery pass
        // or bundle reinspection is needed just to confirm the same selected paths.
        let urls = review.validatedSelection()
        let result = await SystemTrashService.remove(urls)
        let remaining = selected.filter { FilePresence.check($0) != .missing }
        if remaining.isEmpty { controller.finish(event) }
        else {
            review.retainRemaining()
            needsFullDiskAccess = result.needsFullDiskAccess || remaining.contains {
                UninstallFileAccess.isCookieLocation($0) && FilePresence.check($0) == .inaccessible
            }
            needsFinderPermission = result.needsFinderPermission
            review.message = result.message ?? (needsFullDiskAccess ? UninstallFileAccess.cookieAccessMessage
                : String(localized: "Some selected files changed or are inaccessible. Rescan and review them before retrying."))
        }
    }
}
