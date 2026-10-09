import SwiftUI

/// Views own their refresh actions (including directory/security-scope state). Both the toolbar
/// and keyboard command dispatch here, so refreshing never falls back to an unrelated tab.
@MainActor
final class SectionRefreshController: ObservableObject {
    private struct Entry {
        let owner: UUID
        var busy: Bool
        let action: @MainActor () async -> Void
    }
    private var entries: [AppSection: Entry] = [:]
    @Published private(set) var running: [AppSection: UUID] = [:]
    @Published private(set) var revision = 0

    func register(_ section: AppSection, owner: UUID, busy: Bool, action: @escaping @MainActor () async -> Void) {
        entries[section] = Entry(owner: owner, busy: busy, action: action)
        revision += 1
    }

    func setBusy(_ busy: Bool, section: AppSection, owner: UUID) {
        guard entries[section]?.owner == owner, entries[section]?.busy != busy else { return }
        entries[section]?.busy = busy
        revision += 1
    }

    func unregister(_ section: AppSection, owner: UUID) {
        guard entries[section]?.owner == owner else { return }
        entries.removeValue(forKey: section)
        revision += 1
    }

    func canRefresh(_ section: AppSection) -> Bool {
        entries[section]?.busy == false && running[section] == nil
    }

    func refresh(_ section: AppSection) async {
        guard canRefresh(section), let entry = entries[section] else { return }
        running[section] = entry.owner
        defer { if running[section] == entry.owner { running.removeValue(forKey: section) } }
        await entry.action()
    }
}

extension View {
    func sectionRefresh(_ section: AppSection, busy: Bool = false, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(SectionRefreshRegistration(section: section, busy: busy, action: action))
    }
}

private struct SectionRefreshRegistration: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var owner = UUID()
    let section: AppSection
    let busy: Bool
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { model.sectionRefresh.register(section, owner: owner, busy: busy, action: action) }
            .onChange(of: busy) { _, busy in model.sectionRefresh.setBusy(busy, section: section, owner: owner) }
            .onDisappear { model.sectionRefresh.unregister(section, owner: owner) }
    }
}

struct CurrentSectionRefreshButton: View {
    @ObservedObject var controller: SectionRefreshController
    let section: AppSection
    var compact = false

    var body: some View {
        Button {
            let target = section
            Task { await controller.refresh(target) }
        } label: {
            if compact {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(controller.running[section] == nil ? 1 : 0)
                    if controller.running[section] != nil { ProgressView().controlSize(.small) }
                }.frame(width: 16, height: 16)
            } else {
                Text("Refresh Current Tab")
            }
        }
        .disabled(!controller.canRefresh(section))
        .help(String(localized: "Refresh \(section.title)"))
        .accessibilityLabel(String(localized: "Refresh \(section.title)"))
        .accessibilityIdentifier("current-section.refresh")
    }
}
