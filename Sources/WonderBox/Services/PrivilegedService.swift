import AppKit
import Darwin
import Foundation
import Security
import WonderSupport

struct PrivilegedServiceResult: Sendable {
    let succeeded: Bool
    let message: String
}

/// Client for the root helper daemon shared by fan control, memory maintenance and protected app removal.
enum PrivilegedService {
    /// Keep in sync with `protocolVersion` in Sources/WonderFanHelper/main.swift.
    static let protocolVersion = "6"
    private static let socketPath = "/var/run/com.wondercraft.WonderBox.fan.sock"
    private static let helperLabel = "com.wondercraft.WonderBox.FanHelper"
    private static let helperName = "WonderFanHelper"
    static let clientAuthorizationPath = "/Library/PrivilegedHelperTools/com.wondercraft.WonderBox.FanHelper.client.json"
    static let installedHelperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.wondercraft.WonderBox.FanHelper")
    // v6 adds compact per-item failure details to a response containing the original paths.
    private static let maximumReplySize = 131_072
    @MainActor private static var readinessTask: Task<PrivilegedServiceResult, Never>?

    enum Reply: Sendable {
        case success(String)
        case failure(String)
        case unavailable
    }

    @MainActor
    static func ensureReady() async -> PrivilegedServiceResult {
        if let readinessTask { return await readinessTask.value }
        let task = Task { await prepareService() }
        readinessTask = task
        defer { readinessTask = nil }
        return await task.value
    }

    @MainActor
    private static func prepareService() async -> PrivilegedServiceResult {
        var ready = await Task.detached(priority: .userInitiated) {
            serviceVersion() == protocolVersion
        }.value
        if !ready {
            let installation = install()
            guard installation.succeeded else {
                DiagnosticLogger.shared.record(.helperPreparation, outcome: .failure, errorFamily: .helper)
                return installation
            }
            ready = await Task.detached(priority: .userInitiated) {
                for _ in 0..<30 {
                    if serviceVersion() == protocolVersion { return true }
                    usleep(100_000)
                }
                return false
            }.value
        }
        DiagnosticLogger.shared.record(.helperPreparation, outcome: ready ? .success : .failure, errorFamily: ready ? nil : .helper)
        return PrivilegedServiceResult(
            succeeded: ready,
            message: ready ? String(localized: "Background service is ready") : String(localized: "Background service failed to start")
        )
    }

    static func send(_ command: String, timeoutSeconds: Int = 30) -> Reply {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unavailable }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else { return .unavailable }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    _ = strncpy($0, source, pathCapacity - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return .unavailable }

        // A substituted local socket must not impersonate the installed root daemon.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == 0 else { return .unavailable }

        let request = command + "\n"
        let data = Data(request.utf8)
        guard data.count <= 65_536 else { return .failure(String(localized: "Too many files in the uninstall request")) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written else { return .unavailable }
        var reply = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while reply.count < maximumReplySize {
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, maximumReplySize - reply.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return .unavailable }
            reply.append(contentsOf: bytes.prefix(count))
            if reply.contains(10) { break }
        }
        guard reply.last == 10 else { return .unavailable }
        let response = String(decoding: reply, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The daemon speaks English; its messages are catalog keys on this side.
        if response.hasPrefix("ok ") {
            return .success(L10n.message(String(response.dropFirst(3))))
        }
        if response.hasPrefix("error ") {
            return .failure(L10n.message(String(response.dropFirst(6))))
        }
        return .failure(String(localized: "Background service returned an invalid response"))
    }

    @MainActor
    static func trash(_ urls: [URL]) async -> Result<TrashResponse, PrivilegedServiceFailure> {
        do {
            try FileManager.default.createDirectory(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        } catch {
            return .failure(PrivilegedServiceFailure(message: error.localizedDescription))
        }
        let ready = await ensureReady()
        guard ready.succeeded else { return .failure(PrivilegedServiceFailure(message: ready.message)) }
        guard let data = try? JSONEncoder().encode(TrashRequest(paths: urls.map(\.path))) else {
            return .failure(PrivilegedServiceFailure(message: String(localized: "Invalid uninstall request")))
        }
        let command = "trash " + data.base64EncodedString()
        let reply = await Task.detached(priority: .userInitiated) { send(command, timeoutSeconds: 120) }.value
        switch reply {
        case let .success(payload):
            guard let data = Data(base64Encoded: payload), let result = try? JSONDecoder().decode(TrashResponse.self, from: data) else {
                return .failure(PrivilegedServiceFailure(message: String(localized: "Background service returned an invalid response")))
            }
            var metrics: [DiagnosticMetric: Int64] = [.count: Int64(result.moved), .failed: Int64(result.failed.count)]
            if let failure = result.failures.first {
                metrics[.errorCode] = Int64(failure.errorCode)
                metrics[.failureStage] = Int64(failure.stage.rawValue)
            }
            DiagnosticLogger.shared.record(.helperTrashFinished, outcome: result.failed.isEmpty ? .success : .partial,
                                           errorFamily: result.failed.isEmpty ? nil : .fileSystem, metrics: metrics)
            return .success(result)
        case let .failure(message): return .failure(PrivilegedServiceFailure(message: message))
        case .unavailable: return .failure(PrivilegedServiceFailure(message: String(localized: "Lost connection to the background service")))
        }
    }

    struct PrivilegedServiceFailure: Error { let message: String }

    @MainActor
    static func revealInstalledHelper() {
        NSWorkspace.shared.activateFileViewerSelecting([installedHelperURL])
    }

    @MainActor
    private static func install() -> PrivilegedServiceResult {
        guard let helper = HelperLocator.executable(named: helperName),
              let launchDaemon = HelperLocator.resource(named: "\(helperLabel).plist")
        else {
            return PrivilegedServiceResult(succeeded: false, message: String(localized: "Background service files are missing from the app bundle"))
        }
        let installedHelper = "/Library/PrivilegedHelperTools/\(helperLabel)"
        let installedPlist = "/Library/LaunchDaemons/\(helperLabel).plist"
        let quote = AdministratorShell.quote
        // Bind the persistent service to this signed app and the authorizing user, not all staff
        // processes. Ad-hoc builds get a cdhash requirement, so replacing the binary needs approval.
        guard let requirement = clientRequirement(),
              let authorization = try? JSONEncoder().encode(HelperClientAuthorization(uid: getuid(), requirement: requirement)) else {
            return PrivilegedServiceResult(succeeded: false, message: String(localized: "The application signature could not be verified"))
        }
        // `install` copies the quarantine xattr from a browser-downloaded bundle; launchd refuses
        // to load quarantined helpers with "Bootstrap failed: 5: Input/output error", so clear it.
        let commands = [
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(quote(helper.path)) \(quote(installedHelper))",
            "/usr/bin/install -o root -g wheel -m 644 \(quote(launchDaemon.path)) \(quote(installedPlist))",
            "(/bin/echo \(quote(authorization.base64EncodedString())) | /usr/bin/base64 -D > \(quote(clientAuthorizationPath)))",
            "/usr/sbin/chown root:wheel \(quote(clientAuthorizationPath))",
            "/bin/chmod 600 \(quote(clientAuthorizationPath))",
            "(/usr/bin/xattr -d com.apple.quarantine \(quote(installedHelper)) >/dev/null 2>&1 || true)",
            "(/usr/bin/xattr -d com.apple.quarantine \(quote(installedPlist)) >/dev/null 2>&1 || true)",
            "(/bin/launchctl bootout system \(quote(installedPlist)) >/dev/null 2>&1 || true)",
            "/bin/rm -f \(quote(socketPath))",
            "(/bin/launchctl enable system/\(helperLabel) >/dev/null 2>&1 || true)",
            "/bin/launchctl bootstrap system \(quote(installedPlist))"
        ]
        switch AdministratorShell.run(commands.joined(separator: " && ")) {
        case .success:
            DiagnosticLogger.shared.record(.helperInstallation)
            return PrivilegedServiceResult(succeeded: true, message: String(localized: "Background service installed"))
        case let .failure(failure):
            DiagnosticLogger.shared.record(.helperInstallation, outcome: failure.isCancelled ? .cancelled : .failure, errorFamily: .helper,
                                           metrics: [.errorCode: Int64(failure.code)])
            return PrivilegedServiceResult(
                succeeded: false,
                message: failure.isCancelled ? String(localized: "Administrator authorization cancelled") : failure.message
            )
        }
    }

    private static func clientRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func serviceVersion() -> String? {
        guard case let .success(version) = send("version") else { return nil }
        return version
    }
}
