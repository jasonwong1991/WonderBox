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
                    title: "空间清理",
                    subtitle: model.cleanupScanMode.detail,
                    actionTitle: "重新扫描",
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
                        Label(isCleaning ? "正在清理" : "清理所选项目", systemImage: "sparkles")
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
            "清理所选项目？",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理 \(cleanupAmountText)", role: .destructive) {
                isCleaning = true
                Task {
                    await model.cleanSelectedCategories()
                    isCleaning = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.cleanupScanMode == .deep
                ? "应用残留、备份与下载文件会移入废纸篓；各类缓存会直接删除并按需重建。"
                : "缓存会在应用再次运行时按需重建，安装包会移入废纸篓。")
        }
        .sheet(item: $detailKind) { kind in
            CleanupDetailSheet(kind: kind)
                .environmentObject(model)
        }
    }

    private var scanModeControl: some View {
        HStack(spacing: 16) {
            Picker("扫描模式", selection: Binding(
                get: { model.cleanupScanMode },
                set: { mode in Task { await model.setCleanupScanMode(mode) } }
            )) {
                ForEach(CleanupScanMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(model.isScanningStorage || isCleaning)

            if model.cleanupScanMode == .deep {
                Label("新增项目默认不选，清理后可从废纸篓恢复", systemImage: "shield.checkered")
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
                Text(model.isScanningStorage ? "正在分析" : "约可清理")
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
                    text: "\(model.cleanupCategories.filter(\.isSelected).count) 类已选",
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
        return "\(model.selectedCleanupItemCount) 项"
    }

    private var cleanupPolicyText: String {
        model.cleanupScanMode == .deep
            ? "残留、备份、下载与安装包移入废纸篓；包管理与浏览器缓存直接删除"
            : "安装包将移入废纸篓，其余选中项将直接清理"
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
                        Text("深度")
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
                .help(category.unsizedItemCount > 0 ? "\(category.unsizedItemCount) 项体积过大未在限时内统计完，实际可能更多" : "")
            if !category.items.isEmpty {
                Button(action: showDetails) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .help("查看并选择项目")
                .accessibilityLabel("查看\(category.kind.title)项目")
            }
            Toggle("", isOn: Binding(
                get: { category.isSelected },
                set: selectionChanged
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(category.accessMessage != nil)
            .accessibilityLabel("选择\(category.kind.title)")
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
            return "已选 \(selected) / \(category.itemCount) 项"
        }
        return "\(category.itemCount) 项"
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
                    Text("选择需要清理的具体项目")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选") { setAll(true) }
                Button("取消全选") { setAll(false) }
                Button("完成") { dismiss() }
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
                                    Text("修改于 \(AppFormatters.compactDate.string(from: modifiedAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text(item.isSizeEstimated ? AppFormatters.bytes(item.size) : "未统计")
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
                            .help("在 Finder 中显示")
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
