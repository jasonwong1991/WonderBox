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
            case .size: "按大小"
            case .name: "按名称"
            case .modified: "按修改时间"
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
                title: "磁盘分析",
                subtitle: displayPath(directory),
                actionTitle: "重新扫描",
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
                    ? "完全磁盘访问尚未授权；可前往授权，或手动选择一个目录。"
                    : "请选择需要分析的目录，WonderBox 会使用系统目录授权。"
            }
        }
        .onChange(of: model.fullDiskAccessStatus) { _, status in
            if status == .authorized, items.isEmpty {
                scan()
            }
        }
        .confirmationDialog(
            "将所选项目移入废纸篓？",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive, action: removeSelected)
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(selected.count) 项，约 \(AppFormatters.bytes(selectedSize))。")
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.supportsFullDiskAccess ? "完整扫描需要完全磁盘访问" : "请选择要分析的目录")
                    .font(.subheadline.weight(.medium))
                Text(model.supportsFullDiskAccess
                    ? "授权一次后，重新扫描不会再逐个请求目录权限。"
                    : "App Store 沙盒使用系统目录选择授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.supportsFullDiskAccess {
                Button("完全授权") { model.openFullDiskAccessSettings() }
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
            .help("返回上一级扫描")

            Button {
                chooseDirectory()
            } label: {
                Label("选择目录", systemImage: "folder.badge.plus")
            }
            .disabled(isScanning)

            Button {
                NSWorkspace.shared.open(directory)
            } label: {
                Image(systemName: "folder")
            }
            .help("在 Finder 中打开")

            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(DiskSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
            }

            Spacer()

            TextField("搜索文件或文件夹", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Label("\(items.count) 项", systemImage: "doc.on.doc")
            Divider().frame(height: 16)
            Label("当前层共 \(AppFormatters.bytes(items.reduce(0) { $0 + $1.size }))", systemImage: "externaldrive")
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
                Text("正在计算大小")
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
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("大小").frame(width: 100, alignment: .trailing)
                Text("修改时间").frame(width: 110, alignment: .trailing)
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
                    title: search.isEmpty ? "当前目录没有可显示项目" : "没有匹配项目",
                    detail: search.isEmpty ? "可选择其他目录继续分析" : "请更换搜索关键词"
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
            Text(item.size > 0 ? AppFormatters.bytes(item.size) : "未计算")
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
                    .help("扫描此文件夹")
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
            Text(selected.isEmpty ? "选择项目后可在 Finder 中查看或移入废纸篓" : "已选 \(selected.count) 项 · \(AppFormatters.bytes(selectedSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let urls = items.filter { selected.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .disabled(selected.isEmpty)
            Button(role: .destructive) {
                confirmRemoval = true
            } label: {
                Label("移入废纸篓", systemImage: "trash")
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
                message = "未读取到项目；受保护目录可通过“选择目录”授予访问权限"
            }
        }
    }

    private func requestScan() {
        guard model.fullDiskAccessStatus == .authorized || hasScopedDirectoryAccess else {
            message = "请先完成完全授权，或使用“选择目录”授予单个目录访问。"
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
        panel.prompt = "扫描"
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
                ? "已将 \(result.removed) 项移入废纸篓"
                : "已移入 \(result.removed) 项，\(result.failed) 项未处理"
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
