import AppKit
import Carbon
import Foundation

/// Ask Finder to perform its user-session Trash operation for items FileManager could not move.
/// A standalone root daemon does not inherit the app's privacy grants. Do not ask users to
/// authorize that daemon (or install it) just to retry a Trash operation.
enum SystemTrashService {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let queue = DispatchQueue(label: "com.wondercraft.WonderBox.finder-uninstall", qos: .userInitiated)
    /// Created on main, then transferred once to queue. Neither object is accessed concurrently.
    private struct Invocation: @unchecked Sendable {
        let script: NSAppleScript
        let event: NSAppleEventDescriptor

        func execute(requested: [URL]) -> Reply {
            dispatchPrecondition(condition: .onQueue(queue))
            return autoreleasepool {
                var error: NSDictionary?
                let result = script.executeAppleEvent(event, error: &error)
                if let error {
                    return Reply(error: scriptError(code: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -2700,
                                                   message: error[NSAppleScript.errorMessage] as? String))
                }
                return decode(result, requested: requested)
            }
        }
    }
    struct Reply {
        var submitted: Set<URL> = []
        var error: NSError?
    }

    struct Outcome {
        var moved = 0
        var failed: [URL] = []
        var error: NSError?

        var isCancelled: Bool { error.map(SystemTrashService.isCancellation) ?? false }
        var needsFinderPermission: Bool { error?.domain == NSOSStatusErrorDomain && error?.code == -1743 }

        var message: String? {
            guard !failed.isEmpty else { return nil }
            if isCancelled {
                return String(localized: "Removal was cancelled. Items not moved are still selected; you can retry.")
            }
            if needsFinderPermission {
                return String(localized: "Allow WonderBox to control Finder in System Settings > Privacy & Security > Automation")
            }
            if error?.domain == NSOSStatusErrorDomain && error?.code == -1712 {
                return String(localized: "Finder has not finished responding and may still be moving items. Check Finder before retrying.")
            }
            if let error {
                // Report the system operation's actual error, not an inference about Full Disk Access.
                return String(localized: "macOS did not move some items to the Trash: \(error.localizedDescription)")
                    + " (\(error.domain) \(error.code))"
            }
            return String(localized: "Some items are still in their original location. Show them in Finder to review them, or export diagnostic logs from Settings.")
        }
    }

    @MainActor
    static func trash(_ urls: [URL]) async -> Outcome {
        await trash(urls, recycle: recycle)
    }

    /// Injectable system boundary: unit tests never launch Finder or display authentication UI.
    @MainActor
    static func trash(_ urls: [URL], recycle: ([URL]) async -> Reply,
                      presence: (URL) -> FilePresence = FilePresence.check) async -> Outcome {
        var seen = Set<URL>()
        let requested = urls.filter {
            $0.isFileURL && seen.insert($0.standardizedFileURL).inserted && presence($0) != .missing
        }
        guard !requested.isEmpty else { return Outcome() }
        // One batch, not one authorization dialog per failed file. Never retry after cancellation.
        let reply = await recycle(requested)
        var result = Outcome(error: reply.error)
        for url in requested {
            if presence(url) == .missing {
                // Count disappearance only after Finder confirms receiving our batch.
                // Partial progress before cancellation must not be lost.
                if reply.submitted.contains(url) { result.moved += 1 }
            } else {
                // An inaccessible source is unknown, not evidence of successful removal.
                result.failed.append(url)
            }
        }
        var metrics: [DiagnosticMetric: Int64] = [.count: Int64(result.moved), .failed: Int64(result.failed.count)]
        if let error = reply.error { metrics[.errorCode] = Int64(error.code) }
        DiagnosticLogger.shared.record(.systemTrashFinished,
                                       outcome: result.isCancelled ? .cancelled : result.failed.isEmpty ? .success : .partial,
                                       errorFamily: result.failed.isEmpty ? nil : .fileSystem, metrics: metrics)
        return result
    }

    @MainActor
    private static func recycle(_ urls: [URL]) async -> Reply {
        // Instantiate on main, execute serially off-main so Finder's UI never freezes WonderBox.
        guard let script = NSAppleScript(source: finderScript) else {
            return Reply(error: NSError(domain: NSOSStatusErrorDomain, code: -2700))
        }
        let event = prepareEvent(urls, isApplicationActive: NSApplication.shared.isActive) {
            // On macOS 14+, activation is cooperative. Allow Finder to take focus before its
            // AppleScript activate command, not after its authentication UI has already appeared.
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleIdentifier).first {
                NSApplication.shared.yieldActivation(to: finder)
            } else {
                NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: finderBundleIdentifier)
            }
        }
        let invocation = Invocation(script: script, event: event)
        return await withCheckedContinuation { continuation in
            queue.async {
                // Do not activate WonderBox on completion or schedule a delayed activation:
                // that can steal focus from SecurityAgent or an app the user switched to.
                continuation.resume(returning: invocation.execute(requested: urls))
            }
        }
    }

    /// Only hand off our own foreground session. A user who switched away during the initial
    /// file operation should not have their new foreground app displaced by this fallback.
    @MainActor
    static func prepareEvent(_ urls: [URL], isApplicationActive: Bool,
                             yieldActivation: () -> Void) -> NSAppleEventDescriptor {
        if isApplicationActive { yieldActivation() }
        return makeEvent(urls, activateFinder: isApplicationActive)
    }

    /// Paths are Apple-event data, never interpolated into executable script source.
    static func makeEvent(_ urls: [URL], activateFinder: Bool = false) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "movetotrash"), forKeyword: AEKeyword(keyASSubroutineName))
        let paths = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() { paths.insert(NSAppleEventDescriptor(string: url.path), at: index + 1) }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(paths, at: 1)
        arguments.insert(NSAppleEventDescriptor(boolean: activateFinder), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    static func decode(_ descriptor: NSAppleEventDescriptor?, requested: [URL]) -> Reply {
        guard let descriptor, descriptor.numberOfItems == 3,
              let submitted = descriptor.atIndex(1), [typeBoolean, typeTrue, typeFalse].contains(submitted.descriptorType),
              let code = descriptor.atIndex(2), code.descriptorType == typeSInt32,
              let message = descriptor.atIndex(3), message.stringValue != nil else {
            return Reply(error: scriptError(code: -2700, message: String(localized: "Finder returned an invalid Trash response.")))
        }
        var result = Reply(submitted: submitted.booleanValue ? Set(requested) : [])
        if code.int32Value != 0 { result.error = scriptError(code: Int(code.int32Value), message: message.stringValue) }
        return result
    }

    private static func scriptError(code: Int, message: String?) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: code,
                userInfo: message.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
    }

    static let finderScript = """
    on moveToTrash(filePaths, shouldActivateFinder)
        set targets to {}
        repeat with filePath in filePaths
            set end of targets to (POSIX file (contents of filePath)) as alias
        end repeat
        set failureCode to 0
        set failureMessage to ""
        try
            with timeout of 600 seconds
                tell application id "com.apple.finder"
                    -- Activate BEFORE delete: activating after the dialog appears can itself
                    -- take focus away from the system authentication window.
                    if shouldActivateFinder then activate
                    delete targets
                end tell
            end timeout
        on error messageText number messageCode
            set failureCode to messageCode
            set failureMessage to messageText
        end try
        -- Finder may return no destination objects and can replace inodes while trashing.
        -- Report the attempted batch; Swift verifies every original URL with lstat afterwards.
        return {true, failureCode, failureMessage}
    end moveToTrash
    """

    static func isCancellation(_ error: NSError) -> Bool {
        var current: NSError? = error
        // Bound traversal, including malformed/cyclic underlying-error chains.
        for _ in 0..<8 {
            guard let value = current else { return false }
            if (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError)
                || (value.domain == NSOSStatusErrorDomain && value.code == -128) { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
