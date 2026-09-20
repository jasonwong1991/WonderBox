import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("suppressFullDiskAccessPrompt") private var suppressFullDiskAccessPrompt = false
    @State private var showFullDiskAccessPrompt = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand

                List(AppSection.allCases, selection: $model.selection) { section in
                    NavigationLink(value: section) {
                        Label {
                            Text(section.title)
                                .font(.system(size: 14, weight: .medium))
                        } icon: {
                            Image(systemName: section.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(section.tint)
                        }
                    }
                    .accessibilityLabel(section.title)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 250)
            .background(.ultraThinMaterial)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshMetrics() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Status")
                .accessibilityLabel("Refresh Status")
            }
        }
        .onAppear {
            showFullDiskAccessPrompt = model.shouldOfferFullDiskAccess(suppressed: suppressFullDiskAccessPrompt)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshFullDiskAccessStatus()
            if model.fullDiskAccessStatus == .authorized {
                showFullDiskAccessPrompt = false
            }
        }
        .sheet(isPresented: $showFullDiskAccessPrompt) {
            FullDiskAccessPrompt(
                isPresented: $showFullDiskAccessPrompt,
                suppressFuturePrompts: $suppressFullDiskAccessPrompt
            )
            .environmentObject(model)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 31, height: 31)

            VStack(alignment: .leading, spacing: 1) {
                Text("WonderBox")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("SYSTEM TOOLKIT")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isMonitoring ? Color.healthy : Color.secondary)
                .frame(width: 7, height: 7)
            Text(model.isMonitoring ? "Live monitoring" : "Monitoring paused")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("3s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection ?? .overview {
        case .overview: OverviewView()
        case .memory: MemoryView()
        case .fan: FanView()
        case .awake: AwakeView()
        case .applications: ApplicationsView()
        case .cleaner: CleanerView()
        case .storage: DiskAnalyzerView()
        case .settings: SettingsView()
        }
    }
}

private struct FullDiskAccessPrompt: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @Binding var suppressFuturePrompts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow Full Disk Scanning")
                        .font(.title2.bold())
                    Text("WonderBox")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("With access granted, WonderBox can analyze your home folder, app data and protected folders without asking for each directory. Scan results never leave this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don’t ask again", isOn: $suppressFuturePrompts)

            HStack {
                Button("Not Now") {
                    isPresented = false
                }
                Spacer()
                Button {
                    model.openFullDiskAccessSettings()
                    isPresented = false
                } label: {
                    Label("Grant Full Disk Access", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}
