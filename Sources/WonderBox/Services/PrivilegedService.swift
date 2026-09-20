import Darwin
import Foundation

struct PrivilegedServiceResult: Sendable {
    let succeeded: Bool
    let message: String
}

/// Client for the root helper daemon shared by fan control and system-wide memory maintenance.
enum PrivilegedService {
    /// Keep in sync with `protocolVersion` in Sources/WonderFanHelper/main.swift.
    static let protocolVersion = "4"
    private static let socketPath = "/var/run/com.wondercraft.WonderBox.fan.sock"
    private static let helperLabel = "com.wondercraft.WonderBox.FanHelper"
    private static let helperName = "WonderFanHelper"
    /// Memory optimization holds the connection for several seconds; never block a caller indefinitely.
    private static let replyTimeout = timeval(tv_sec: 30, tv_usec: 0)

    enum Reply: Sendable {
        case success(String)
        case failure(String)
        case unavailable
    }

    @MainActor
    static func ensureReady() async -> PrivilegedServiceResult {
        var ready = await Task.detached(priority: .userInitiated) {
            serviceVersion() == protocolVersion
        }.value
        if !ready {
            let installation = install()
            guard installation.succeeded else { return installation }
            ready = await Task.detached(priority: .userInitiated) {
                for _ in 0..<30 {
                    if serviceVersion() == protocolVersion { return true }
                    usleep(100_000)
                }
                return false
            }.value
        }
        return PrivilegedServiceResult(
            succeeded: ready,
            message: ready ? String(localized: "Background service is ready") : String(localized: "Background service failed to start")
        )
    }

    static func send(_ command: String) -> Reply {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unavailable }
        defer { Darwin.close(descriptor) }
        var timeout = replyTimeout
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

        let request = command + "\n"
        let written = request.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        guard written == request.utf8.count else { return .unavailable }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return .unavailable }
        let response = String(decoding: bytes.prefix(count), as: UTF8.self)
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
    private static func install() -> PrivilegedServiceResult {
        guard let helper = HelperLocator.executable(named: helperName),
              let launchDaemon = HelperLocator.resource(named: "\(helperLabel).plist")
        else {
            return PrivilegedServiceResult(succeeded: false, message: String(localized: "Background service files are missing from the app bundle"))
        }
        let installedHelper = "/Library/PrivilegedHelperTools/\(helperLabel)"
        let installedPlist = "/Library/LaunchDaemons/\(helperLabel).plist"
        let quote = AdministratorShell.quote
        let commands = [
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(quote(helper.path)) \(quote(installedHelper))",
            "/usr/bin/install -o root -g wheel -m 644 \(quote(launchDaemon.path)) \(quote(installedPlist))",
            "/bin/launchctl bootout system \(quote(installedPlist)) >/dev/null 2>&1 || true",
            "/bin/rm -f \(quote(socketPath))",
            "/bin/launchctl bootstrap system \(quote(installedPlist))"
        ]
        switch AdministratorShell.run(commands.joined(separator: "; ")) {
        case .success:
            return PrivilegedServiceResult(succeeded: true, message: String(localized: "Background service installed"))
        case let .failure(failure):
            return PrivilegedServiceResult(
                succeeded: false,
                message: failure.isCancelled ? String(localized: "Administrator authorization cancelled") : failure.message
            )
        }
    }

    private static func serviceVersion() -> String? {
        guard case let .success(version) = send("version") else { return nil }
        return version
    }
}
