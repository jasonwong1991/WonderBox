import AppKit
import SwiftUI

struct CleanerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConfirmation = false
    @State private var isCleaning = false
    @State private var detailKind: CleanupKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: String(localized: "Cleanup"),
                    subtitle: model.cleanupScanMode.detail,
                    actionTitle: String(localized: "Rescan"),
                    actionSymbol: "arrow.clockwise",
                    isWorking: model.isScanningStorage,
                    action: { Task { await model.scanStorage() } }
                )

                if let message = model.operationMessage {
                    InlineMessage(text: message, dismiss: model.dismissOperationMessage)
                }

                scanModeControl

                cleanupSummary

                VStack(spacing: 10) {
                    ForEach(model.cleanupCategories) { category in
                        CleanupCategoryRow(
                            category: category,
                            selectionChanged: { selected in
                                model.setCleanupCategory(category, selected: selected)
                            },
                            showDetails: { detailKind = category.kind }
                        )
                    }
                }

                HStack {
                    Label(cleanupPolicyText, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showConfirmation = true
                    } label: {
                        Label(isCleaning ? "Cleaning…" : "Clean Selected", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xE45E65))
                    .disabled(model.selectedCleanupItemCount == 0 || model.isScanningStorage || isCleaning)
                }
            }
            .padding(28)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .onAppear {
            guard model.cleanupCategories.allSatisfy({ $0.itemCount == 0 }) else { return }
            Task { await model.scanStorage() }
        }
        .confirmationDialog(
            "Clean the selected items?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean \(cleanupAmountText)", role: .destructive) {
                isCleaning = true
                Task {
                    await model.cleanSelectedCategories()
                    isCleaning = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.cleanupScanMode == .deep
                ? String(localized: "App leftovers, backups and downloads go to the Trash; caches are deleted and rebuilt on demand.")
                : String(localized: "Caches are rebuilt the next time an app runs; installers go to the Trash."))
        }
        .sheet(item: $detailKind) { kind in
            CleanupDetailSheet(kind: kind)
                .environmentObject(model)
        }
    }

    private var scanModeControl: some View {
        HStack(spacing: 16) {
            Picker("Scan Mode", selection: Binding(
                get: { model.cleanupScanMode },
                set: { mode in Task { await model.setCleanupScanMode(mode) } }
            )) {
                ForEach(CleanupScanMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.isScanningStorage || isCleaning)

            if model.cleanupScanMode == .deep {
                Label("Extra categories start unselected and can be restored from the Trash", systemImage: "shield.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var cleanupSummary: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0xE45E65).opacity(0.1))
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE45E65))
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.isScanningStorage ? "Analyzing" : "Reclaimable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(cleanupAmountText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            if model.isScanningStorage {
                ProgressView()
                    .controlSize(.small)
            } else {
                StatusPill(
                    text: String(localized: "\(model.cleanupCategories.filter(\.isSelected).count) categories selected"),
                    color: Color(hex: 0x3178F6)
                )
            }
        }
        .appPanel()
    }

    private var cleanupAmountText: String {
        if model.selectedCleanupSize > 0 {
            return AppFormatters.bytes(model.selectedCleanupSize)
        }
        return String(localized: "\(model.selectedCleanupItemCount) items")
    }

    private var cleanupPolicyText: String {
        model.cleanupScanMode == .deep
            ? String(localized: "Leftovers, backups, downloads and installers go to the Trash; package manager and browser caches are deleted")
            : String(localized: "Installers go to the Trash; other selected items are deleted")
    }
}

private struct CleanupCategoryRow: View {
    let category: CleanupCategory
    let selectionChanged: (Bool) -> Void
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(category.kind.tint)
                .frame(width: 38, height: 38)
                .background(category.kind.tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(category.kind.title)
                        .font(.subheadline.weight(.semibold))
                    if category.kind.isDeepOnly {
                        Text("Deep")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(category.kind.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(category.kind.tint.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Text(category.accessMessage ?? "\(category.kind.detail) · \(itemCountText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(categorySizeText)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
                .help(category.unsizedItemCount > 0 ? "\(category.unsizedItemCount) items were too large to size in time; the real total may be higher" : "")
            if !category.items.isEmpty {
                Button(action: showDetails) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .help("View and select items")
                .accessibilityLabel("View \(category.kind.title) items")
            }
            Toggle("", isOn: Binding(
                get: { category.isSelected },
                set: selectionChanged
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(category.accessMessage != nil)
            .accessibilityLabel("Select \(category.kind.title)")
        }
        .appPanel(padding: 13)
    }

    private var categorySizeText: String {
        guard category.accessMessage == nil else { return "--" }
        let size = AppFormatters.bytes(category.size)
        return category.unsizedItemCount > 0 ? "≥ \(size)" : size
    }

    private var itemCountText: String {
        let selected = category.items.filter(\.isSelected).count
        if !category.items.isEmpty, selected != category.itemCount {
            return String(localized: "\(selected) of \(category.itemCount) items selected")
        }
        return String(localized: "\(category.itemCount) items")
    }
}

private struct CleanupDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: CleanupKind

    private var category: CleanupCategory? {
        model.cleanupCategories.first { $0.kind == kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.title2.bold())
                    Text("Choose the items to clean")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All") { setAll(true) }
                Button("Deselect All") { setAll(false) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(category?.items ?? []) { item in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { item.isSelected },
                                set: { model.setCleanupItem(kind: kind, item: item, selected: $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .foregroundStyle(kind.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(
                                    of: FileManager.default.homeDirectoryForCurrentUser.path,
                                    with: "~"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                if let modifiedAt = item.modifiedAt {
                                    Text("Modified \(AppFormatters.compactDate.string(from: modifiedAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text(item.isSizeEstimated ? AppFormatters.bytes(item.size) : String(localized: "Not sized"))
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(item.isSizeEstimated ? .primary : .secondary)
                                .frame(width: 90, alignment: .trailing)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 58)
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func setAll(_ selected: Bool) {
        guard let category else { return }
        model.setCleanupCategory(category, selected: selected)
    }
}
