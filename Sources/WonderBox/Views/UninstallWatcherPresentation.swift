import SwiftUI

struct UninstallWatcherPresentation: View {
    @ObservedObject var controller: UninstallWatcherController
    let isBlocked: Bool
    private enum Prompt { case install, error }
    @State private var prompt: Prompt?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { offerInstallation() }
            .onChange(of: isBlocked) { _, blocked in if !blocked { offerInstallation() } }
            .onChange(of: controller.message) { _, message in if message != nil { prompt = .error } }
            .alert(prompt == .install ? "Install the Uninstall Watcher plugin?" : "Plugin Setup",
                   isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                if prompt == .install {
                    Button("Install Plugin") { Task { await controller.setInstalled(true) } }
                    Button("Not Now", role: .cancel) {}
                } else { Button("OK", role: .cancel) {} }
            } message: {
                if prompt == .install {
                    Text("Get a related-file cleanup prompt when you delete an app in Finder, even with WonderBox closed. You can install or uninstall this optional login item later in Settings.")
                } else { Text(controller.message ?? "") }
            }
            .sheet(item: Binding(
                get: { isBlocked || prompt != nil ? nil : controller.pendingEvent },
                set: { _ in }
            )) { event in
                ExternalUninstallSheet(event: event, controller: controller)
            }
    }
    private func offerInstallation() {
        guard !isBlocked, controller.pendingEvent == nil else { return }
        if controller.consumeInstallPrompt() { prompt = .install }
    }
}
