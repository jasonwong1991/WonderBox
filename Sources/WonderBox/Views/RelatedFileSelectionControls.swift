import AppKit
import SwiftUI

struct RelatedFileSelectionControls: View {
    let selected: Int
    let total: Int
    let selectAll: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            MixedSelectionCheckbox(selected: selected, total: total) { selectAll(selected != total) }
                .accessibilityLabel("Select all related files")
            Button("Select All") { selectAll(true) }
                .disabled(total == 0 || selected == total)
                .accessibilityIdentifier("uninstaller.select-all")
            Button("Deselect All") { selectAll(false) }
                .disabled(selected == 0)
                .accessibilityIdentifier("uninstaller.deselect-all")
        }
        .buttonStyle(.borderless).font(.caption)
    }
}

struct CookiePermissionGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(UninstallFileAccess.cookieAccessMessage)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("If access was already enabled, remove the old entry and add the currently running copy of WonderBox, then relaunch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Full Disk Access") { FullDiskAccessController.openSystemSettings() }
                Button("Show WonderBox in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            .font(.caption)
        }
    }
}
