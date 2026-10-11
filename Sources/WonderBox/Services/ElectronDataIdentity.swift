import Darwin
import Foundation

struct ElectronDataIdentity: Equatable, Sendable {
    var names: [String] = []
    var legacyNames: [String] = []
    var bytesRead = 0
}

/// Inspect only Electron's root package and declared bootstrap entry. No JavaScript runs,
/// archives are never unpacked, and dependency manifests/source maps/assets are not searched.
enum ElectronDataIdentityScanner {
    static let maximumHeaderBytes = 2 * 1_024 * 1_024
    static let maximumPackageBytes = 64 * 1_024
    static let maximumSourceBytes = 1_024 * 1_024
    private static let genericPackageNames: Set<String> = ["app", "application", "electron", "main", "default"]
    private static let pathPattern = try! NSRegularExpression(pattern:
        #"\.(?:join|resolve)\s*\(\s*[A-Za-z_$][A-Za-z0-9_.$]{0,80}\s*,\s*(?:"\.\."|'\.\.')\s*,\s*(?:"([^"\\\r\n]{1,128})"|'([^'\\\r\n]{1,128})')"#)
    private static let userDataPattern = try! NSRegularExpression(pattern: #"\.getPath\s*\(\s*(?:"userData"|'userData')\s*\)"#)

    static func inspect(_ bundle: URL, productNames: [String]) -> ElectronDataIdentity {
        var result = ElectronDataIdentity()
        let resources = bundle.appendingPathComponent("Contents/Resources")
        guard !Task.isCancelled, ApplicationIdentityScanner.noSymlinkComponents(resources, below: bundle),
              ["Electron Framework.framework", "Electron.framework"].contains(where: {
                  ApplicationIdentityScanner.isRealDirectory(bundle.appendingPathComponent("Contents/Frameworks/" + $0))
              }) else { return result }

        func loose(_ relative: String, maximum: Int) -> Data? {
            let url = resources.appendingPathComponent(relative)
            guard ApplicationIdentityScanner.noSymlinkComponents(url, below: bundle),
                  let file = BoundedFile(url) else { return nil }
            defer { file.close() }
            guard file.size <= UInt64(maximum) else { return nil }
            let data = file.read(offset: 0, count: Int(file.size))
            result.bytesRead += data?.count ?? 0
            return data
        }
        var archive: Archive?
        var package: [String: Any]?
        var looseRoot = ""
        let url = resources.appendingPathComponent("app.asar")
        if ApplicationIdentityScanner.noSymlinkComponents(url, below: bundle), let reader = Archive(url) {
            if let data = reader.read("package.json", maximum: maximumPackageBytes, unpacked: { relative, maximum in
                loose("app.asar.unpacked/" + relative, maximum: maximum)
            }), let parsed = json(data) { archive = reader; package = parsed }
            else { result.bytesRead += reader.bytesRead; reader.file.close() }
        }
        if package == nil {
            for location in ["app/package.json", "package.json"] {
                if let bytes = loose(location, maximum: maximumPackageBytes), let parsed = json(bytes) {
                    package = parsed; looseRoot = location == "app/package.json" ? "app/" : ""; break
                }
            }
        }
        defer { archive?.file.close() }
        guard let package, !Task.isCancelled else {
            result.bytesRead += archive?.bytesRead ?? 0
            return result
        }
        // Electron prefers productName over name for its default userData directory.
        if let name = (package["productName"] as? String) ?? (package["name"] as? String),
           validName(name), !genericPackageNames.contains(name.lowercased()) { result.names = [name] }
        let main = (package["main"] as? String) ?? "index.js"
        if let entry = normalizedEntry(main) {
            for relative in [entry, entry + ".js", entry + "/index.js"] {
                if Task.isCancelled { break }
                let source: Data?
                if let archive {
                    source = archive.read(relative, maximum: maximumSourceBytes, unpacked: { relative, maximum in
                        loose("app.asar.unpacked/" + relative, maximum: maximum)
                    })
                } else {
                    source = loose(looseRoot + relative, maximum: maximumSourceBytes)
                }
                if let source, let text = String(data: source, encoding: .utf8) {
                    result.legacyNames = legacyNames(in: text, productNames: productNames + result.names)
                    break
                }
            }
        }
        result.bytesRead += archive?.bytesRead ?? 0
        return result
    }

    static func legacyNames(in source: String, productNames: [String]) -> [String] {
        guard !Task.isCancelled else { return [] }
        let text = source as NSString
        var result = Set<String>()
        let bases = productNames.filter { validName($0) && $0.count >= 4 && !genericPackageNames.contains($0.lowercased()) }
        pathPattern.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let name = text.substring(with: range)
            guard validName(name), bases.contains(where: { base in
                let name = name.lowercased(), base = base.lowercased()
                guard name.hasPrefix(base), name.count > base.count else { return false }
                return [" ", "-", "_"].contains(String(name.dropFirst(base.count).prefix(1)))
            }) else { return }
            // This is explicitly a sibling path in bootstrap migration code near a userData
            // lookup, not a broad product-prefix rule. It remains opt-in for other editions.
            let start = max(0, match.range.location - 2_048)
            let end = min(text.length, NSMaxRange(match.range) + 2_048)
            let context = text.substring(with: NSRange(location: start, length: end - start))
            let lower = context.lowercased()
            guard userDataPattern.firstMatch(in: context, range: NSRange(location: 0, length: (context as NSString).length)) != nil,
                  ["migrat", "renamesync", "rename(", "copysync", "copyfile"].contains(where: { lower.contains($0) })
            else { return }
            result.insert(name)
        }
        return result.sorted()
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 192 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !RelatedFileScanner.sharedLibraryDirectories.contains(value.lowercased())
    }

    private static func normalizedEntry(_ value: String) -> String? {
        let value = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 512, !value.contains("\\"), !value.utf8.contains(0),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private final class BoundedFile {
        let fd: Int32
        let size: UInt64
        private var closed = false
        init?(_ url: URL) {
            var expected = stat()
            guard lstat(url.path, &expected) == 0, expected.st_mode & S_IFMT == S_IFREG,
                  expected.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                  info.st_dev == expected.st_dev, info.st_ino == expected.st_ino,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { Darwin.close(fd); return nil }
            self.fd = fd; size = UInt64(info.st_size)
        }
        func close() { if !closed { Darwin.close(fd); closed = true } }
        deinit { close() }
        func read(offset: UInt64, count: Int) -> Data? {
            guard !Task.isCancelled, !closed, count >= 0, offset <= size,
                  UInt64(count) <= size - offset, offset <= UInt64(Int64.max) else { return nil }
            var result = Data(count: count)
            let bytes = result.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pread(fd, base, count, off_t(offset))
            }
            return bytes == count ? result : nil
        }
    }

    private final class Archive {
        let file: BoundedFile
        let headerSize: UInt64
        let files: [String: Any]
        var bytesRead: Int
        init?(_ url: URL) {
            guard let file = BoundedFile(url) else { return nil }
            guard let prefix = file.read(offset: 0, count: 8), prefix.uint32LE(at: 0) == 4,
                  let size = prefix.uint32LE(at: 4), size >= 8, size <= maximumHeaderBytes,
                  let header = file.read(offset: 8, count: Int(size)),
                  let payloadSize = header.uint32LE(at: 0), payloadSize == size - 4,
                  let length = header.uint32LE(at: 4), length <= size - 8,
                  let values = json(header.subdata(in: 8..<(8 + Int(length)))), let files = values["files"] as? [String: Any]
            else { file.close(); return nil }
            self.file = file; headerSize = UInt64(size); self.files = files; bytesRead = 8 + Int(size)
        }
        func read(_ path: String, maximum: Int, unpacked: (String, Int) -> Data?) -> Data? {
            guard let normalized = normalizedEntry(path) else { return nil }
            var entries = files
            var node: [String: Any]?
            let components = normalized.split(separator: "/")
            for (index, component) in components.enumerated() {
                guard let entry = entries[String(component)] as? [String: Any], entry["link"] == nil else { return nil }
                node = entry
                if index < components.count - 1 {
                    guard let children = entry["files"] as? [String: Any] else { return nil }
                    entries = children
                }
            }
            guard let node, node["files"] == nil, let number = node["size"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue <= Double(maximum), Double(number.intValue) == number.doubleValue else { return nil }
            if node["unpacked"] as? Bool == true { return unpacked(normalized, maximum) }
            guard let offset = node["offset"] as? String, !offset.isEmpty, offset.count <= 20,
                  offset.utf8.allSatisfy({ (48...57).contains($0) }), let relative = UInt64(offset),
                  relative <= UInt64.max - headerSize - 8 else { return nil }
            let data = file.read(offset: 8 + headerSize + relative, count: number.intValue)
            bytesRead += data?.count ?? 0
            return data
        }
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= 4, offset <= count - 4 else { return nil }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
