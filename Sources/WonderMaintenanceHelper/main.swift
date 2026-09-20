import Foundation

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.dropFirst() == ["clean-system-caches"] else {
    fail("usage: WonderMaintenanceHelper clean-system-caches", code: 64)
}

let manager = FileManager.default
let root = URL(fileURLWithPath: "/Library/Caches", isDirectory: true).standardizedFileURL
guard let items = try? manager.contentsOfDirectory(
    at: root,
    includingPropertiesForKeys: [.isSymbolicLinkKey],
    options: [.skipsHiddenFiles]
) else {
    fail("failed to read /Library/Caches", code: 77)
}

var removed = 0
var failed = 0
for item in items {
    let candidate = item.standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/"), candidate.path != root.path else {
        failed += 1
        continue
    }
    do {
        try manager.removeItem(at: candidate)
        removed += 1
    } catch {
        failed += 1
    }
}

if failed > 0 {
    print("系统缓存已清理 \(removed) 项，\(failed) 项受系统保护")
} else {
    print("系统缓存已清理 \(removed) 项")
}
