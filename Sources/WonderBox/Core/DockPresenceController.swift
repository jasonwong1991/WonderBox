import AppKit
import SwiftUI

/// Keeps the Dock icon in step with the main window: WonderBox is a regular Dock app while the window is
/// open and becomes a menu-bar-only accessory once it closes. Without the menu bar shortcut there is nothing
/// left to come back to, so the user is asked to turn it on or quit instead.
@MainActor
final class DockPresenceController: NSObject, NSApplicationDelegate, ObservableObject {
    private var observers: [NSObjectProtocol] = []
    private var hasMainWindow = false

    // Same keys and defaults as the `@AppStorage` properties in the App and Settings; writes propagate
    // back to those bindings through UserDefaults.
    private var menuBarEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBar") }
    }

    private var confirmQuitOnClose: Bool {
        get { UserDefaults.standard.object(forKey: "confirmQuitOnClose") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "confirmQuitOnClose") }
    }

    /// SwiftUI quits a single-`Window` app as soon as that window closes; `windowDidClose` decides instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// SwiftUI does not always present a `Window` scene at launch (observed on plain launches with no state
    /// to restore). A reopen takes the same path as a Dock click and shows the window; for a `Window` scene it
    /// is idempotent, so a late-but-normal presentation is unaffected.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.hasMainWindow else { return }
            self.requestReopen()
        }
    }

    /// Sends ourselves the reopen Apple event; SwiftUI answers it by presenting the primary `Window`.
    /// Calling the delegate's `applicationShouldHandleReopen` directly does nothing — SwiftUI handles the event itself.
    private func requestReopen() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    /// Call before opening the main window from inside the app (menu bar). The Dock icon has to exist
    /// before the window is ordered front, otherwise the app stays behind the previously active one.
    func willShowMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The main window reports itself here when SwiftUI first builds it. SwiftUI reuses the same `NSWindow`
    /// on reopen, so becoming key (not view attachment) is what marks each later appearance.
    func track(_ window: NSWindow) {
        hasMainWindow = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.windowDidAppear() }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                // Let the close finish first so neither the alert nor the policy switch fights a half-closed window.
                Task { @MainActor in self?.windowDidClose() }
            }
        ]
        windowDidAppear()
    }

    /// Safety net for reopen paths that bypass `willShowMainWindow()` and LaunchServices (which restores the
    /// Dock icon itself on `open`), such as a reopen Apple event.
    private func windowDidAppear() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func windowDidClose() {
        if menuBarEnabled {
            NSApp.setActivationPolicy(.accessory)
        } else if confirmQuitOnClose {
            askToStayInMenuBar()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func askToStayInMenuBar() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep WonderBox in the menu bar?")
        alert.informativeText = String(localized: "The menu bar shortcut is off, so closing the window leaves no way back to WonderBox. Turn it on to stay one click away, or quit now.")
        alert.addButton(withTitle: String(localized: "Show in Menu Bar"))
        alert.addButton(withTitle: String(localized: "Quit Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            confirmQuitOnClose = false
        }
        if response == .alertFirstButtonReturn {
            menuBarEnabled = true
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.terminate(nil)
        }
    }
}

extension View {
    /// Hands the hosting `NSWindow` to `controller`; SwiftUI exposes no other handle to a scene's window.
    func reportsMainWindow(to controller: DockPresenceController) -> some View {
        background(MainWindowReporter(controller: controller))
    }
}

private struct MainWindowReporter: NSViewRepresentable {
    let controller: DockPresenceController

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindow = { [controller] window in controller.track(window) }
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}
}

private final class WindowTrackingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}
