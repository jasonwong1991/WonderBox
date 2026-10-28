import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOperationDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: String(localized: "Uninstaller"),
                subtitle: String(localized: "Applications and related files"),
                actionTitle: String(localized: "Choose App"),
                actionSymbol: "plus",
                isWorking: model.isScanningApplications,
                action: chooseApplication
            )

            if let message = model.operationMessage {
                HStack(alignment: .top, spacing: 10) {
                    InlineMessage(text: message, isError: model.uninstallMessageIsError, dismiss: model.dismissOperationMessage)
                        .lineLimit(3)
                    Button("Details") { showOperationDetails = true }
                        .fixedSize()
                        .padding(.top, 8)
                        .popover(isPresented: $showOperationDetails) {
                            ScrollView {
                                Text(message).font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            }
                            .frame(width: 460, height: 240)
                        }
                }
                if model.uninstallNeedsFinderPermission { FinderPermissionGuidance() }
                if model.uninstallNeedsFullDiskAccess { CookiePermissionGuidance() }
                if model.uninstallMessageIsError, !model.uninstallRemainingItems.isEmpty {
                    Button("Show Remaining Items in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(model.uninstallRemainingItems)
                    }
                }
            }

            HSplitView {
                applicationList
                    .disabled(model.isUninstallingApplication)
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 440)
                applicationDetail
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            .appPanel(padding: 0)
        }
        .padding(28)
        .onChange(of: model.operationMessage) { _, _ in showOperationDetails = false }
        .sectionRefresh(.applications, busy: model.isScanningApplications || model.isScanningRelatedFiles || model.isUninstallingApplication) {
            await model.refreshApplicationInventory()
        }
        .onAppear { model.beginApplicationWork() }
        .onDisappear { model.suspendApplicationWork() }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $model.applicationSearch)
                    .textFieldStyle(.plain)
                if !model.applicationSearch.isEmpty {
                    Button {
                        model.applicationSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Picker("Filter", selection: $model.applicationFilter) {
                ForEach(ApplicationFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(model.applicationFilter.detail)
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Picker("Sort", selection: $model.applicationSort) {
                    ForEach(ApplicationSort.allCases) { sort in
                        Label(sort.title, systemImage: sort.symbol).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button {
                    model.applicationSortAscending.toggle()
                } label: {
                    Image(systemName: model.applicationSortAscending ? "arrow.up" : "arrow.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(model.applicationSortAscending ? "Ascending; click to sort descending" : "Descending; click to sort ascending")
                .accessibilityLabel(model.applicationSortAscending ? "Sort descending" : "Sort ascending")

                Spacer()

                Text(model.applicationSort.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if model.isScanningApplications && model.applications.isEmpty {
                ProgressView("Scanning applications…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredApplications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(model.applications.isEmpty ? "No Applications Found" : "No Matching Applications")
                        .font(.subheadline.weight(.medium))
                    Text(model.applicationFilter.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredApplications) { application in
                            ApplicationRow(
                                application: application,
                                sort: model.applicationSort,
                                isSelected: model.selectedApplication?.id == application.id
                            ) {
                                Task { await model.selectApplication(application) }
                            }
                        }
                    }
                    .padding(7)
                }
            }

            Divider()

            if model.isMeasuringApplicationSizes {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring related data… \(model.measuredApplicationCount)/\(model.applicationMeasurementCount)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }

            HStack {
                Text("\(model.filteredApplications.count) apps · \(model.filteredApplicationSizeIsComplete ? "" : "≥ ")\(AppFormatters.bytes(model.filteredApplicationSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.refreshApplicationInventory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Rescan")
                .disabled(model.isScanningApplications)
            }
            .padding(12)
            Text("Includes app + detected data. ≥ means a partial total.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .help("Large folders use a bounded scan. Calculate full sizes in the detail.")
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var applicationDetail: some View {
        if let application = model.selectedApplication {
            ApplicationDetail(application: application).id(application.id)
                .disabled(model.isUninstallingApplication)
        } else {
            EmptyContentView(
                symbol: "shippingbox",
                title: String(localized: "Select an Application"),
                detail: String(localized: "The app bundle and its removable related files will appear here")
            )
        }
    }

    private func chooseApplication() {
        guard !model.isUninstallingApplication else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an application to uninstall")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let appType = UTType(filenameExtension: "app") {
            panel.allowedContentTypes = [appType]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addApplication(at: url) }
    }
}

struct FinderPermissionGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open Automation Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("Enable Finder under WonderBox in Automation. This permission is separate from Full Disk Access and administrator authorization.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

private struct ApplicationRow: View {
    let application: InstalledApplication
    let sort: ApplicationSort
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(application.name), \(application.totalSizeText)")
        .help(String(localized: "App: \(AppFormatters.bytes(application.size)) · Related data: \(application.storageUsage.map { AppFormatters.bytes($0.relatedSize) } ?? String(localized: "Measuring…"))"))
    }

    private var secondaryText: String {
        switch sort {
        case .name:
            return [application.version, application.totalSizeText]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .size:
            return [application.totalSizeText, application.version]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .installedAt:
            return String(localized: "Installed \(application.installedAt.map(AppFormatters.compactDate.string) ?? String(localized: "Unknown")) · \(application.totalSizeText)")
        case .lastUsedAt:
            return String(localized: "Used \(application.lastUsedAt.map(AppFormatters.compactDate.string) ?? String(localized: "No record")) · \(application.totalSizeText)")
        }
    }
}

private struct ApplicationDetail: View {
    @EnvironmentObject private var model: AppModel
    let application: InstalledApplication
    @State private var showConfirmation = false
    @State private var isRemoving = false

    private var selectionSummary: RelatedFileSelectionSummary { RelatedFileSelectionSummary(files: model.relatedFiles) }

    private var selectedRelatedSize: UInt64 {
        model.relatedFiles.filter(\.isSelected).reduce(0) { ApplicationStorageUsage.add($0, $1.size) }
    }
    private var selectedSizePrefix: String { model.relatedFiles.filter(\.isSelected).allSatisfy(\.isSizeComplete) ? "" : "≥ " }
    private var removesBundle: Bool { ApplicationScanner.needsBundleRemoval(application.url) }
    private var bundleSizeForTotal: UInt64 { FilePresence.check(application.url) == .missing ? 0 : application.size }
    private var totalUsageText: String {
        (application.storageUsage?.isComplete == true && application.isBundleSizeComplete ? "" : "≥ ") + AppFormatters.bytes(ApplicationStorageUsage.add(bundleSizeForTotal, application.storageUsage?.relatedSize ?? 0))
    }
    private var breakdownText: String {
        String(localized: "App: \((application.isBundleSizeComplete ? "" : "≥ ") + AppFormatters.bytes(bundleSizeForTotal)) · Related data: \(application.storageUsage.map { ($0.isComplete ? "" : "≥ ") + AppFormatters.bytes($0.relatedSize) } ?? String(localized: "Measuring…"))")
    }

    var body: some View {
        let summary = selectionSummary
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(application.name)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text(application.bundleIdentifier ?? application.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(application.url)
                    } label: {
                        Image(systemName: "play.fill")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Open app")
                    .accessibilityLabel("Open \(application.name)")
                    .disabled(!removesBundle)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([application.url])
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(application.name) in Finder")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                ApplicationMetadata(title: String(localized: "Total Usage"), value: totalUsageText)
                    .help("Includes all detected related data, regardless of which items are selected for removal.")
                Divider().frame(height: 28)
                ApplicationMetadata(
                    title: String(localized: "Install Date"),
                    value: application.installedAt.map(AppFormatters.compactDate.string) ?? String(localized: "Unknown")
                )
                Divider().frame(height: 28)
                ApplicationMetadata(
                    title: String(localized: "Last Used"),
                    value: application.lastUsedAt.map(AppFormatters.compactDate.string) ?? String(localized: "No record")
                )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                Text(breakdownText).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(breakdownText)
                Spacer(minLength: 0)
                if model.isMeasuringRelatedSizes {
                    ProgressView().controlSize(.mini)
                    Button("Stop Measuring") {
                        model.cancelRelatedSizeCalculation()
                        model.measureApplicationSizes()
                    }.buttonStyle(.borderless).font(.caption)
                } else if model.relatedFiles.contains(where: { !$0.isSizeComplete }) {
                    Button("Calculate Full Sizes") { model.measureSelectedRelatedSizes() }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(model.isScanningRelatedFiles)
                }
            }.padding(.horizontal, 22).padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Related Files").font(.headline)
                        Spacer()
                        Text("\(model.relatedFiles.count) items · \(selectedSizePrefix + AppFormatters.bytes(selectedRelatedSize))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.relatedFiles.isEmpty {
                        RelatedFileSelectionControls(selected: model.relatedFiles.filter(\.isSelected).count, total: model.relatedFiles.count, selectAll: model.setAllRelatedFiles)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if !removesBundle {
                    Text("The app is already in the Trash or removed. Only selected related files will be moved.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                if let message = model.relatedFileScanMessage {
                    InlineMessage(text: message, isError: true).padding(.horizontal, 20)
                    HStack {
                        Button("Grant Access") { model.openFullDiskAccessSettings() }
                            .disabled(!model.supportsFullDiskAccess)
                        Button("Rescan") { Task { await model.selectApplication(application) } }
                            .disabled(model.isScanningRelatedFiles || isRemoving)
                    }.padding(.horizontal, 20)
                }

                if model.isScanningRelatedFiles {
                    ProgressView("Finding related files…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.relatedFiles.isEmpty {
                    Text("No related files found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(RelatedFileGroup.groups(for: model.relatedFiles)) { group in
                                RelatedFileGroupView(group: group)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let warning = summary.warning {
                    Label {
                        HStack(spacing: 4) {
                            Text("\(summary.omittedCount) items will be kept")
                            Text(verbatim: "·")
                            Text(summary.sizeText).monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .help(warning)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(warning)
                    .accessibilityIdentifier("uninstaller.kept-items")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Will move to Trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedSizePrefix + AppFormatters.bytes(ApplicationStorageUsage.add(removesBundle ? application.size : 0, selectedRelatedSize)))
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showConfirmation = true
                    } label: {
                        Label(isRemoving ? "Uninstalling…" : removesBundle ? "Uninstall" : "Remove Related Files", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.critical)
                    .disabled(isRemoving || model.isScanningRelatedFiles || (!removesBundle && !model.relatedFiles.contains(where: \.isSelected)))
                    .accessibilityIdentifier("uninstaller.remove")
                }
            }
            .padding(18)
        }
        .confirmationDialog(
            "Uninstall \(application.name)?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(summary.confirmTitle, role: .destructive) {
                isRemoving = true
                Task {
                    await model.uninstallSelectedApplication()
                    isRemoving = false
                }
            }
            Button(summary.cancelTitle, role: .cancel) {}
        } message: {
            Text(summary.confirmationMessage(removesBundle: removesBundle))
        }
    }
}

private struct RelatedFileGroupView: View {
    @EnvironmentObject private var model: AppModel
    let group: RelatedFileGroup
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                MixedSelectionCheckbox(selected: group.selectedCount, total: group.files.count) {
                    model.setRelatedFiles(group.files, selected: group.selectedCount != group.files.count)
                }
                .accessibilityLabel("Select \(group.category.title)")
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 12)
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(group.category.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text("\(group.files.count) items").font(.caption).foregroundStyle(.secondary)
                        Text(group.files.allSatisfy { !$0.hasMeasuredSize } ? String(localized: "Not measured") :
                             (group.files.allSatisfy(\.isSizeComplete) ? "" : "≥ ") + AppFormatters.bytes(group.size)).font(.caption.monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if expanded {
                ForEach(group.files) { file in
                    RelatedFileRow(file: file)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

/// Native mixed state distinguishes a partially selected folder from a fully selected one.
struct MixedSelectionCheckbox: NSViewRepresentable {
    let selected: Int
    let total: Int
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.state = selected == 0 ? .off : selected == total ? .on : .mixed
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 18, height: 18)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

private struct RelatedFileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: RelatedFile
    @State private var expanded = false
    @State private var children: [URL] = []
    @State private var isLoading = false

    private var isDirectory: Bool {
        (try? file.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map {
            $0.isDirectory == true && $0.isSymbolicLink != true
        } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if isDirectory {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                    }
                    .buttonStyle(.plain).help("Preview folder contents")
                    .accessibilityLabel("Preview \(file.url.lastPathComponent)")
                } else { Color.clear.frame(width: 12) }
                Toggle("", isOn: Binding(get: { file.isSelected }, set: { model.setRelatedFile(file, selected: $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Select \(file.displayPath)")
                Image(systemName: isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(isDirectory ? Color.accentColor : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(file.displayPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let detail = file.association.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .help(detail)
                    }
                }
                Spacer(minLength: 4)
                Text(file.sizeText).font(.caption.monospacedDigit())
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help("Show in Finder")
            }
            .padding(.vertical, 9)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if isLoading { ProgressView().controlSize(.small) }
                    ForEach(children, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    Text("Folder selection includes all its contents. Preview shows up to 100 items.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 62).padding(.bottom, 10)
                .opacity(file.isSelected ? 1 : 0.55)
                .task {
                    isLoading = true
                    children = await Task.detached(priority: .utility) {
                        Array(FileSystemScanner.children(of: file.url).sorted {
                            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                        }.prefix(100))
                    }.value
                    isLoading = false
                }
            }
        }
        .padding(.horizontal, 7)
    }
}

private struct ApplicationMetadata: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}
