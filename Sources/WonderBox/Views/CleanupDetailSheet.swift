import AppKit
import SwiftUI

struct CleanupDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let category: CleanupCategory?
    @State private var selected: Set<URL>
    @State private var search = ""
    @State private var expandedApps = Set<String>()
    @State private var ordering: CleanupDetailOrdering

    init(category: CleanupCategory?, initiallyExpandedApps: Set<String> = [], ordering: CleanupDetailOrdering? = nil) {
        self.category = category
        _selected = State(initialValue: Set(category?.items.filter(\.isSelected).map(\.id) ?? []))
        _expandedApps = State(initialValue: initiallyExpandedApps)
        let grouped = category.map { [.caches, .browserCaches, .wechatCaches, .wecomCaches].contains($0.kind) } ?? true
        _ordering = State(initialValue: ordering ?? CleanupDetailOrdering(field: grouped ? .name : .size, ascending: grouped))
    }

    private var kind: CleanupKind { category?.kind ?? .caches }
    private var items: [CleanupItem] { category?.items ?? [] }
    private var isGrouped: Bool { [.caches, .browserCaches, .wechatCaches, .wecomCaches].contains(kind) }
    private var visibleIDs: Set<URL> {
        if isGrouped { return Set(displayedGroups.flatMap(\.items).map(\.id)) }
        return Set(displayedItems.map(\.id))
    }
    private var allSelected: Bool { !visibleIDs.isEmpty && visibleIDs.isSubset(of: selected) }
    private var isBlocked: Bool { category?.accessMessage != nil }
    private var selectedSize: UInt64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    private var selectedSizeText: String {
        (items.contains { selected.contains($0.id) && !$0.isSizeEstimated } ? "≥ " : "") + AppFormatters.bytes(selectedSize)
    }
    private var groups: [ApplicationCacheGroup] { ApplicationCacheGroup.groups(items) }
    private var displayedGroups: [ApplicationCacheGroup] {
        ordering.groups(groups.filter { group in search.isEmpty || group.application.name.localizedCaseInsensitiveContains(search)
            || group.items.contains { $0.url.path.localizedCaseInsensitiveContains(search) } })
    }
    private var displayedItems: [CleanupItem] {
        ordering.items(items.filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title).font(.title2.bold())
                        Text(isGrouped ? "Select an app, or expand it to choose individual cache folders" : "Choose the items to clean")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected { selected.subtract(visibleIDs) } else { selected.formUnion(visibleIDs) }
                    }
                    .disabled(visibleIDs.isEmpty || isBlocked)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Done") {
                        model.applyCleanupSelection(kind: kind, selection: selected, displayedItems: Set(items.map(\.id)))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBlocked)
                }
                TextField(isGrouped ? "Search apps or cache folders" : "Search files or folders", text: $search)
                    .textFieldStyle(.roundedBorder)
                if let message = category?.accessMessage { InlineMessage(text: message) }
                if [.wechatCaches, .wecomCaches].contains(kind) {
                    Text("Only listed caches go to the Trash. Chat databases and downloaded attachments are not selected.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 12) {
                sortButton(.name)
                Spacer()
                sortButton(.size).frame(width: 90, alignment: .trailing)
                Color.clear.frame(width: 16, height: 1)
            }
            .font(.caption.weight(.medium))
            .padding(.leading, isGrouped ? 96 : 82).padding(.trailing, 20).padding(.vertical, 9)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.subtleBackground)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isGrouped {
                        ForEach(displayedGroups) { group in
                            applicationGroup(group)
                            Divider().padding(.leading, 72)
                        }
                    } else {
                        ForEach(displayedItems) { item in
                            itemRow(item)
                            Divider().padding(.leading, 56)
                        }
                    }
                    if items.isEmpty {
                        EmptyContentView(symbol: kind.symbol, title: String(localized: "No items found"),
                                         detail: String(localized: "Rescan after granting access or choosing another category"))
                            .frame(minHeight: 160)
                    } else if isGrouped && displayedGroups.isEmpty {
                        Text("No Matching Applications").foregroundStyle(.secondary).padding(30)
                    }
                }
            }
            Divider()
            HStack {
                if isGrouped { Text("\(groups.filter { $0.id != "unidentified" }.count) apps").foregroundStyle(.secondary) }
                Spacer()
                Text("\(selected.count) selected · \(selectedSizeText)").monospacedDigit()
            }
            .font(.caption).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private func applicationGroup(_ group: ApplicationCacheGroup) -> some View {
        let count = group.selectedCount(in: selected)
        let expanded = expandedApps.contains(group.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                MixedSelectionCheckbox(selected: count, total: group.items.count) {
                    let ids = Set(group.items.map(\.id))
                    if count == group.items.count { selected.subtract(ids) } else { selected.formUnion(ids) }
                }
                .disabled(isBlocked)
                .accessibilityLabel("Select caches for \(group.application.name)")
                if let url = group.application.bundleURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 34, height: 34)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 34, height: 34)
                }
                Button {
                    if expanded { expandedApps.remove(group.id) } else { expandedApps.insert(group.id) }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.application.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("\(group.items.count) cache locations · \(count) selected").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(group.isSizeEstimated ? "" : "≥ ")\(AppFormatters.bytes(group.size))")
                            .font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show caches for \(group.application.name)")
            }
            .padding(.horizontal, 20).frame(minHeight: 72)
            if expanded {
                ForEach(ordering.items(group.items)) { item in
                    itemRow(item, nested: true)
                }
            }
        }
    }

    private func itemRow(_ item: CleanupItem, nested: Bool = false) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selected.contains(item.id) }, set: {
                if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(isBlocked)
            .accessibilityLabel("Select \(item.url.lastPathComponent)")
            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(kind.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(isGrouped ? cacheTitle(item.url) : item.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                if !isGrouped, let date = item.modifiedAt {
                    Text("Modified \(AppFormatters.compactDate.string(from: date))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(item.isSizeEstimated ? AppFormatters.bytes(item.size) : String(localized: "Not sized"))
                .font(.system(.subheadline, design: .rounded, weight: .medium)).monospacedDigit()
                .foregroundStyle(item.isSizeEstimated ? .primary : .secondary).frame(width: 90, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).help("Show in Finder")
                .accessibilityLabel("Show in Finder")
        }
        .padding(.leading, nested ? 72 : 20).padding(.trailing, 20).frame(minHeight: 58)
        .background(nested ? Color.subtleBackground : Color.clear)
    }

    private func sortButton(_ field: CleanupDetailSort) -> some View {
        Button { ordering.select(field) } label: {
            HStack(spacing: 5) {
                Text(field.title)
                Image(systemName: ordering.field == field ? (ordering.ascending ? "chevron.up" : "chevron.down") : "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ordering.field == field ? Color.primary : Color.secondary)
        .help(field == .size ? "Sort by size" : "Sort by name")
        .accessibilityLabel(field == .size ? "Sort by size" : "Sort by name")
        .accessibilityValue(ordering.field == field
                            ? (ordering.ascending ? String(localized: "Ascending") : String(localized: "Descending"))
                            : String(localized: "Not sorted"))
    }

    private func cacheTitle(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "GPUCache", "ShaderCache", "GrShaderCache", "DawnCache": String(localized: "Graphics and Shader Cache")
        case "Code Cache", "ScriptCache": String(localized: "Script Cache")
        case "NetworkCache", "CacheStorage": String(localized: "Web Cache")
        case "Caches", "Cache": String(localized: "Application Cache")
        default: url.lastPathComponent
        }
    }
}
