import CSMC
import Darwin
import Foundation

/// Keep in sync with `PrivilegedService.protocolVersion` in Sources/WonderBox/Services/PrivilegedService.swift.
private let protocolVersion = "4"
private let defaultSocketPath = "/var/run/com.wondercraft.WonderBox.fan.sock"

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

private func handle(_ request: String) -> String {
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
    default:
        return "error Unsupported command\n"
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

    while true {
        let client = Darwin.accept(server, nil, nil)
        guard client >= 0 else { continue }
        autoreleasepool {
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(client, &buffer, buffer.count)
            let request = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
            let response = handle(request)
            response.withCString { bytes in
                _ = Darwin.write(client, bytes, strlen(bytes))
            }
            Darwin.close(client)
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
