import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: "应用卸载",
                subtitle: "应用与关联文件",
                actionTitle: "选择应用",
                actionSymbol: "plus",
                isWorking: model.isScanningApplications,
                action: chooseApplication
            )

            if let message = model.operationMessage {
                InlineMessage(text: message, dismiss: model.dismissOperationMessage)
            }

            HSplitView {
                applicationList
                    .frame(minWidth: 320, idealWidth: 370, maxWidth: 440)
                applicationDetail
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            .appPanel(padding: 0)
        }
        .padding(28)
        .onAppear {
            guard model.applications.isEmpty else { return }
            Task { await model.scanApplications() }
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: $model.applicationSearch)
                    .textFieldStyle(.plain)
                if !model.applicationSearch.isEmpty {
                    Button {
                        model.applicationSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Picker("筛选", selection: $model.applicationFilter) {
                ForEach(ApplicationFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(model.applicationFilter.detail)
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Picker("排序", selection: $model.applicationSort) {
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
                .help(model.applicationSortAscending ? "当前升序，点按切换降序" : "当前降序，点按切换升序")
                .accessibilityLabel(model.applicationSortAscending ? "切换为降序" : "切换为升序")

                Spacer()

                Text(model.applicationSort.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if model.isScanningApplications && model.applications.isEmpty {
                ProgressView("正在扫描应用…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredApplications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(model.applications.isEmpty ? "未发现应用" : "没有符合条件的应用")
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

            HStack {
                Text("\(model.filteredApplications.count) 个 · \(AppFormatters.bytes(model.filteredApplicationSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.scanApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新扫描")
                .disabled(model.isScanningApplications)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var applicationDetail: some View {
        if let application = model.selectedApplication {
            ApplicationDetail(application: application)
        } else {
            EmptyContentView(
                symbol: "shippingbox",
                title: "选择一个应用",
                detail: "将显示应用本体和可移除的关联文件"
            )
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要卸载的应用"
        panel.prompt = "选择"
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
        .accessibilityLabel("\(application.name)，\(AppFormatters.bytes(application.size))")
    }

    private var secondaryText: String {
        switch sort {
        case .name:
            return [application.version, AppFormatters.bytes(application.size)]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .size:
            return [AppFormatters.bytes(application.size), application.version]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .installedAt:
            return "安装 \(application.installedAt.map(AppFormatters.compactDate.string) ?? "未知") · \(AppFormatters.bytes(application.size))"
        case .lastUsedAt:
            return "使用 \(application.lastUsedAt.map(AppFormatters.compactDate.string) ?? "无记录") · \(AppFormatters.bytes(application.size))"
        }
    }
}

private struct ApplicationDetail: View {
    @EnvironmentObject private var model: AppModel
    let application: InstalledApplication
    @State private var showConfirmation = false
    @State private var isRemoving = false

    private var selectedRelatedSize: UInt64 {
        model.relatedFiles.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(application.name)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
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
                    .help("打开应用")
                    .accessibilityLabel("打开\(application.name)")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([application.url])
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中显示")
                    .accessibilityLabel("在 Finder 中显示\(application.name)")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                ApplicationMetadata(title: "应用大小", value: AppFormatters.bytes(application.size))
                Divider().frame(height: 28)
                ApplicationMetadata(
                    title: "安装日期",
                    value: application.installedAt.map(AppFormatters.compactDate.string) ?? "未知"
                )
                Divider().frame(height: 28)
                ApplicationMetadata(
                    title: "最近使用",
                    value: application.lastUsedAt.map(AppFormatters.compactDate.string) ?? "无记录"
                )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("关联文件")
                        .font(.headline)
                    Spacer()
                    if !model.relatedFiles.isEmpty {
                        Button("全选") { model.setAllRelatedFiles(true) }
                            .buttonStyle(.borderless)
                        Button("取消全选") { model.setAllRelatedFiles(false) }
                            .buttonStyle(.borderless)
                    }
                    Text("\(model.relatedFiles.count) 项 · \(AppFormatters.bytes(selectedRelatedSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                if model.isScanningRelatedFiles {
                    ProgressView("正在查找关联文件…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.relatedFiles.isEmpty {
                    Text("未发现关联文件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.relatedFiles) { file in
                                HStack(spacing: 8) {
                                    Toggle(isOn: Binding(
                                        get: { file.isSelected },
                                        set: { model.setRelatedFile(file, selected: $0) }
                                    )) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.displayPath)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(AppFormatters.bytes(file.size))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer(minLength: 4)
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("在 Finder 中显示")
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 7)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("将移入废纸篓")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AppFormatters.bytes(application.size + selectedRelatedSize))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                Spacer()
                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    Label(isRemoving ? "正在卸载" : "卸载应用", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.critical)
                .disabled(isRemoving || model.isScanningRelatedFiles)
            }
            .padding(18)
        }
        .confirmationDialog(
            "卸载 \(application.name)？",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive) {
                isRemoving = true
                Task {
                    await model.uninstallSelectedApplication()
                    isRemoving = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用本体与已勾选的关联文件将移入废纸篓。")
        }
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
