import AppKit
import SwiftUI

struct DiskAnalyzerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser
    @State private var history: [URL] = []
    @State private var items: [DiskScanItem] = []
    @State private var selected = Set<URL>()
    @State private var search = ""
    @State private var sort = DiskSort.size
    @State private var isScanning = false
    @State private var message: String?
    @State private var confirmRemoval = false
    @State private var hasScopedDirectoryAccess = false

    private enum DiskSort: String, CaseIterable, Identifiable {
        case size
        case name
        case modified

        var id: Self { self }
        var title: String {
            switch self {
            case .size: String(localized: "By Size")
            case .name: String(localized: "By Name")
            case .modified: String(localized: "By Date Modified")
            }
        }
    }

    private var displayedItems: [DiskScanItem] {
        let filtered = search.isEmpty ? items : items.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .size:
                if lhs.size == rhs.size { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
                return lhs.size > rhs.size
            case .name:
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            case .modified:
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
        }
    }

    private var selectedSize: UInt64 {
        items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: String(localized: "Disk Analyzer"),
                subtitle: displayPath(directory),
                actionTitle: String(localized: "Rescan"),
                actionSymbol: "arrow.clockwise",
                isWorking: isScanning,
                action: requestScan
            )

            if let message {
                InlineMessage(text: message, dismiss: { self.message = nil })
            }

            if model.fullDiskAccessStatus != .authorized {
                permissionBanner
            }

            controls
            summary
            itemList
            footer
        }
        .padding(28)
        .frame(maxWidth: 1_180, maxHeight: .infinity, alignment: .topLeading)
        .task {
            model.refreshFullDiskAccessStatus()
            if model.fullDiskAccessStatus == .authorized {
                scan()
            } else {
                message = model.supportsFullDiskAccess
                    ? String(localized: "Full Disk Access is not granted yet; grant it, or choose a folder manually.")
                    : String(localized: "Choose a folder to analyze; WonderBox uses the system folder permission.")
            }
        }
        .onChange(of: model.fullDiskAccessStatus) { _, status in
            if status == .authorized, items.isEmpty {
                scan()
            }
        }
        .confirmationDialog(
            "Move the selected items to the Trash?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: removeSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selected.count) items, about \(AppFormatters.bytes(selectedSize)).")
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.supportsFullDiskAccess ? "Full scans need Full Disk Access" : "Choose a folder to analyze")
                    .font(.subheadline.weight(.medium))
                Text(model.supportsFullDiskAccess
                    ? String(localized: "After granting access once, rescans no longer ask for each folder.")
                    : String(localized: "The App Store sandbox uses the system folder picker for access."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.supportsFullDiskAccess {
                Button("Grant Access") { model.openFullDiskAccessSettings() }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(Color.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(history.isEmpty || isScanning)
            .help("Back to the previous folder")

            Button {
                chooseDirectory()
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .disabled(isScanning)

            Button {
                NSWorkspace.shared.open(directory)
            } label: {
                Image(systemName: "folder")
            }
            .help("Open in Finder")

            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(DiskSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
            }

            Spacer()

            TextField("Search files or folders", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(items.count) items", systemImage: "doc.on.doc")
            Divider().frame(height: 16)
            Label("\(AppFormatters.bytes(items.reduce(0) { $0 + $1.size })) at this level", systemImage: "externaldrive")
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
                Text("Calculating sizes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Size").frame(width: 100, alignment: .trailing)
                Text("Modified").frame(width: 110, alignment: .trailing)
                Color.clear.frame(width: 28)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()

            if displayedItems.isEmpty, !isScanning {
                EmptyContentView(
                    symbol: "externaldrive.badge.questionmark",
                    title: search.isEmpty ? String(localized: "Nothing to Show Here") : String(localized: "No Matches"),
                    detail: search.isEmpty ? String(localized: "Choose another folder to continue") : String(localized: "Try a different search term")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedItems) { item in
                            diskRow(item)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 320)
        .appPanel(padding: 0)
    }

    private func diskRow(_ item: DiskScanItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(item.id) },
                set: { checked in
                    if checked { selected.insert(item.id) } else { selected.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? Color(hex: 0xE1A127) : .secondary)
                .frame(width: 22)
            Button {
                if item.isDirectory { enter(item.url) }
                else { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            } label: {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            Text(item.size > 0 ? AppFormatters.bytes(item.size) : String(localized: "Not sized"))
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Text(item.modifiedAt.map(AppFormatters.compactDate.string) ?? "--")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            if item.isDirectory {
                Button { enter(item.url) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .help("Scan this folder")
                    .disabled(isScanning)
            } else {
                Color.clear.frame(width: 16)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var footer: some View {
        HStack {
            Text(selected.isEmpty ? "Select items to show them in Finder or move them to the Trash" : "\(selected.count) selected · \(AppFormatters.bytes(selectedSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let urls = items.filter { selected.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(selected.isEmpty)
            Button(role: .destructive) {
                confirmRemoval = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
        }
    }

    private func scan() {
        guard !isScanning else { return }
        let target = directory
        isScanning = true
        selected.removeAll()
        message = nil
        Task {
            let result = await Task.detached(priority: .utility) { DiskAnalyzer.scan(target) }.value
            guard directory == target else { return }
            items = result
            isScanning = false
            if result.isEmpty {
                message = String(localized: "Nothing could be read; use “Choose Folder” to grant access to protected folders")
            }
        }
    }

    private func requestScan() {
        guard model.fullDiskAccessStatus == .authorized || hasScopedDirectoryAccess else {
            message = String(localized: "Grant Full Disk Access first, or use “Choose Folder” to grant access to a single folder.")
            return
        }
        scan()
    }

    private func enter(_ url: URL) {
        history.append(directory)
        directory = url
        search = ""
        scan()
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        directory = previous
        search = ""
        scan()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan")
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        hasScopedDirectoryAccess = true
        history.removeAll()
        directory = url
        search = ""
        scan()
    }

    private func removeSelected() {
        let targets = items.filter { selected.contains($0.id) }.map(\.url)
        let root = directory
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiskAnalyzer.moveToTrash(targets, inside: root)
            }.value
            message = result.failed == 0
                ? String(localized: "Moved \(result.removed) items to the Trash")
                : String(localized: "Moved \(result.removed) items to the Trash; \(result.failed) could not be moved")
            scan()
        }
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }
}
