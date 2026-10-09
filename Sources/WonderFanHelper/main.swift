import CSMC
import Darwin
import Foundation
import Security
import WonderSupport

/// Keep in sync with `PrivilegedService.protocolVersion` in Sources/WonderBox/Services/PrivilegedService.swift.
private let protocolVersion = "6"
private let defaultSocketPath = "/var/run/com.wondercraft.WonderBox.fan.sock"
private let clientAuthorizationPath = "/Library/PrivilegedHelperTools/com.wondercraft.WonderBox.FanHelper.client.json"

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func smcFailure(_ fallback: String) -> String {
    let detail = String(cString: wc_smc_last_error())
    return detail.isEmpty ? fallback : detail
}

private func runTool(_ path: String, _ arguments: [String] = []) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// The same kernel entry point `memory_pressure -S` uses (root only). The value is `request << 16 | level`;
/// level codes are `NOTE_MEMORYSTATUS_PRESSURE_*` from the private half of <sys/event.h>, request codes are
/// the `TEST_*_TRIGGER_*` constants in xnu's kern_memorystatus_notify.c.
private enum SimulatedMemoryPressure {
    private static let sysctlName = "kern.memorypressure_manual_trigger"
    /// Notify every registered process and drop all purgeable memory.
    private static let notifyAllAndPurge: Int32 = 6
    static let normal: Int32 = 0x1
    static let critical: Int32 = 0x4
    /// Long enough for apps that read the level back on the event, short enough not to distort monitoring.
    static let holdSeconds: UInt32 = 3

    static func set(_ level: Int32) -> Bool {
        var value = (notifyAllAndPurge << 16) | level
        return sysctlbyname(sysctlName, nil, nil, &value, MemoryLayout<Int32>.size) == 0
    }
}

/// Reclaims memory the way macOS itself does under pressure: every process is told to release caches
/// (compressed pages owned by those caches are freed with them), then the file cache is dropped.
private func optimizeMemory() -> String {
    var steps: [String] = []
    if SimulatedMemoryPressure.set(SimulatedMemoryPressure.critical) {
        // Always leave manual-testing mode, or the kernel's real pressure handling stays disabled.
        defer { _ = SimulatedMemoryPressure.set(SimulatedMemoryPressure.normal) }
        sleep(SimulatedMemoryPressure.holdSeconds)
        steps.append("pressure")
    }
    if runTool("/usr/sbin/purge") {
        steps.append("purge")
    }
    guard !steps.isEmpty else { return "error The system memory tools are unavailable\n" }
    return "ok \(steps.joined(separator: " "))\n"
}

private func handle(_ request: String, authorizedUID: uid_t? = nil) -> String {
    let fields = request.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard let command = fields.first else { return "error Empty command\n" }
    switch command {
    case "version":
        return "ok \(protocolVersion)\n"
    case "status":
        guard wc_smc_is_available() == 1 else { return "error AppleSMC is unavailable\n" }
        return "ok fans=\(wc_smc_fan_count()) control=\(wc_smc_fan_control_capabilities())\n"
    case "set-auto":
        guard fields.count == 1 else { return "error Invalid arguments for set-auto\n" }
        guard wc_smc_is_available() == 1 else { return "error AppleSMC is unavailable\n" }
        guard wc_smc_set_all_fans_auto() == 0 else {
            return "error \(smcFailure("Failed to restore automatic fan control"))\n"
        }
        return "ok Automatic fan control restored\n"
    case "set-rpm":
        guard fields.count == 2,
              let rpm = Double(fields[1]),
              (800...10_000).contains(rpm)
        else { return "error RPM must be between 800 and 10000\n" }
        guard wc_smc_is_available() == 1 else { return "error AppleSMC is unavailable\n" }
        guard wc_smc_set_all_fans_rpm(rpm) == 0 else {
            return "error \(smcFailure("Failed to set the fan target speed"))\n"
        }
        return "ok Fan target speed applied\n"
    case "optimize-memory":
        guard fields.count == 1 else { return "error Invalid arguments for optimize-memory\n" }
        return optimizeMemory()
    case "trash":
        guard fields.count == 2, let uid = authorizedUID, uid != 0,
              let user = getpwuid(uid), let directory = user.pointee.pw_dir,
              let data = Data(base64Encoded: String(fields[1])),
              let request = try? JSONDecoder().decode(TrashRequest.self, from: data), request.paths.count <= 256 else {
            return "error Invalid uninstall request\n"
        }
        let result = PrivilegedTrash.move(request, uid: uid, gid: user.pointee.pw_gid, home: String(cString: directory))
        guard let encoded = try? JSONEncoder().encode(result) else { return "error Invalid uninstall response\n" }
        return "ok \(encoded.base64EncodedString())\n"
    default:
        return "error Unsupported command\n"
    }
}

private func clientAuthorization() -> HelperClientAuthorization? {
    let descriptor = open(clientAuthorizationPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
          info.st_size > 0, info.st_size < 16_384,
          let data = try? file.readToEnd() else { return nil }
    return try? JSONDecoder().decode(HelperClientAuthorization.self, from: data)
}

/// Audit-token identity avoids PID reuse between looking up the caller and checking its signature.
private func authorizedUser(_ client: Int32) -> uid_t? {
    guard let authorization = clientAuthorization() else { return nil }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == authorization.uid else { return nil }
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
          size == MemoryLayout<audit_token_t>.size else { return nil }
    let data = withUnsafeBytes(of: token) { Data($0) }
    var code: SecCode?
    var requirement: SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
          let code, SecRequirementCreateWithString(authorization.requirement as CFString, [], &requirement) == errSecSuccess,
          let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
    return uid
}

private func writeReply(_ response: String, to client: Int32) {
    let data = Data(response.utf8)
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            offset += count
        }
    }
}

private func serve(socketPath: String) -> Never {
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        fail("socket path is too long", code: 64)
    }
    signal(SIGPIPE, SIG_IGN)
    unlink(socketPath)

    let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { fail("failed to create socket", code: 71) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    socketPath.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                _ = strncpy($0, source, pathCapacity - 1)
            }
        }
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        Darwin.close(server)
        fail("failed to bind socket", code: 71)
    }
    _ = chown(socketPath, 0, 20) // root:staff
    _ = chmod(socketPath, 0o660)
    guard Darwin.listen(server, 8) == 0 else {
        Darwin.close(server)
        fail("failed to listen on socket", code: 71)
    }

    let controlQueue = DispatchQueue(label: "com.wondercraft.WonderBox.helper.control")
    let trashQueue = DispatchQueue(label: "com.wondercraft.WonderBox.helper.trash")

    while true {
        let client = Darwin.accept(server, nil, nil)
        guard client >= 0 else { continue }
        autoreleasepool {
            var queued = false
            defer { if !queued { Darwin.close(client) } }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let uid = authorizedUser(client) else {
                writeReply("error Background service client authorization failed\n", to: client)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            while request.count < 65_536 {
                let count = Darwin.read(client, &buffer, min(buffer.count, 65_536 - request.count))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                request.append(contentsOf: buffer.prefix(count))
                if request.contains(10) { break }
            }
            guard request.last == 10 else { return }
            let text = String(decoding: request, as: UTF8.self)
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first
            // Health checks stay responsive during a large application's ownership transfer. Otherwise
            // ensureReady could time out and reinstall (killing the daemon in the middle of a move).
            if command == "version" || command == "status" {
                writeReply(handle(text, authorizedUID: uid), to: client)
            } else {
                queued = true
                let queue = command == "trash" ? trashQueue : controlQueue
                queue.async {
                    autoreleasepool {
                        defer { Darwin.close(client) }
                        writeReply(handle(text, authorizedUID: uid), to: client)
                    }
                }
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--daemon" {
    serve(socketPath: arguments.count > 1 ? arguments[1] : defaultSocketPath)
}

guard let command = arguments.first else {
    fail("usage: WonderFanHelper version | status | set-auto | set-rpm RPM | optimize-memory | --daemon [SOCKET]", code: 64)
}

if command == "version" {
    print(protocolVersion)
    exit(0)
}
if command == "optimize-memory" {
    let response = handle(command)
    guard response.hasPrefix("ok ") else {
        fail(response.replacingOccurrences(of: "error ", with: "").trimmingCharacters(in: .whitespacesAndNewlines), code: 77)
    }
    print(response.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines))
    exit(0)
}
guard wc_smc_is_available() == 1 else {
    fail("AppleSMC is not available on this Mac", code: 69)
}
switch command {
case "status":
    let count = wc_smc_fan_count()
    print("fans=\(count)")
    print("control=\(wc_smc_fan_control_capabilities())")
    for index in 0..<count {
        var reading = WCFanReading()
        if wc_smc_read_fan(index, &reading) == 0 {
            print("fan\(index)=\(String(format: "%.0f", reading.current_rpm))")
        }
    }
case "set-auto", "set-rpm":
    let response = handle(arguments.joined(separator: " "))
    guard response.hasPrefix("ok ") else {
        fail(response.replacingOccurrences(of: "error ", with: "").trimmingCharacters(in: .whitespacesAndNewlines), code: 77)
    }
    print(response.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines))
default:
    fail("unknown command", code: 64)
}
