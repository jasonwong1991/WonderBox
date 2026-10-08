import Darwin
import Foundation

public struct HelperClientAuthorization: Codable {
    public let uid: uid_t
    public let requirement: String
    public init(uid: uid_t, requirement: String) {
        self.uid = uid
        self.requirement = requirement
    }
}

public struct TrashRequest: Codable {
    public let paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

public struct TrashResponse: Codable, Sendable {
    public var moved: Int = 0
    public var failed: [String] = []
    public init() {}
}

/// The daemon exposes a narrow Trash operation, never a shell or a permanent unrestricted delete API.
public enum PrivilegedTrash {
    private static let libraryRoots = [
        "Application Scripts", "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
        "HTTPStorages", "LaunchAgents", "Logs", "Preferences", "Saved Application State", "WebKit"
    ]
    private static let systemRoots = [
        "Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences", "PrivilegedHelperTools"
    ]

    public static func isAllowed(_ path: String, home: String) -> Bool {
        // Foundation's standardizedFileURL rewrites /private/var to /var on macOS. Use lexical
        // normalization here; openDirectory below deliberately rejects symlink aliases.
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !components.contains("."), !components.contains(".."),
              "/" + components.joined(separator: "/") == path else { return false }
        let url = URL(fileURLWithPath: path)
        // Only app bundles below application roots, never the roots themselves or Apple's system apps.
        for root in ["/Applications", home + "/Applications"] {
            if path.hasPrefix(root + "/"), url.pathExtension.lowercased() == "app" {
                let relative = path.dropFirst(root.count + 1).split(separator: "/")
                return !relative.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
            }
        }
        let roots = libraryRoots.map { home + "/Library/" + $0 }
            + systemRoots.map { "/Library/" + $0 }
            + [home + "/Library/Preferences/ByHost", home + "/Library/Logs/DiagnosticReports", home + "/Library/Application Support/CrashReporter"]
        return roots.contains { root in
            url.deletingLastPathComponent().path == root
                && !url.lastPathComponent.hasPrefix(".")
                && !libraryRoots.contains(url.lastPathComponent)
                && !["ByHost", "DiagnosticReports", "CrashReporter"].contains(url.lastPathComponent)
        }
    }

    /// Directory descriptors pin both parents. No symlink traversal, no overwrites, no cross-volume
    /// copy/delete fallback, and no recursive chown through links inside the moved bundle.
    public static func move(_ request: TrashRequest, uid: uid_t, gid: gid_t, home: String) -> TrashResponse {
        var response = TrashResponse()
        guard request.paths.count <= 256,
              let trash = openDirectory(home + "/.Trash") else {
            response.failed = request.paths
            return response
        }
        defer { close(trash) }
        var trashInfo = stat()
        guard fstat(trash, &trashInfo) == 0, trashInfo.st_uid == uid else {
            response.failed = request.paths
            return response
        }
        for path in request.paths {
            guard isAllowed(path, home: home),
                  let parent = openDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path) else {
                response.failed.append(path)
                continue
            }
            defer { close(parent) }
            let name = URL(fileURLWithPath: path).lastPathComponent
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT != S_IFLNK,
                  info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_NOUNLINK) == 0 else {
                response.failed.append(path)
                continue
            }
            let destination = "WonderBox-\(UUID().uuidString)"
            // A private, user-owned wrapper keeps every move unique while preserving the original
            // file name. Restoring an app from Finder needs no renamed .app bundle or merge.
            guard mkdirat(trash, destination, 0o700) == 0 else {
                response.failed.append(path)
                continue
            }
            let wrapper = openat(trash, destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard wrapper >= 0 else {
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                response.failed.append(path)
                continue
            }
            defer { close(wrapper) }
            var wrapperInfo = stat()
            guard fstat(wrapper, &wrapperInfo) == 0, wrapperInfo.st_uid == geteuid(),
                  wrapperInfo.st_mode & 0o077 == 0 else {
                response.failed.append(path)
                continue
            }
            if renameatx_np(parent, name, wrapper, name, UInt32(RENAME_EXCL)) == 0 {
                // Do this before handing the wrapper to the user, so they cannot substitute entries.
                restoreOwnership(parent: wrapper, name: name, uid: uid, gid: gid)
                _ = fchown(wrapper, uid, gid)
                response.moved += 1
            } else {
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                response.failed.append(path)
            }
        }
        return response
    }

    private static func openDirectory(_ path: String) -> Int32? {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    private static func restoreOwnership(parent: Int32, name: String, uid: uid_t, gid: gid_t) {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        // Do not transfer ownership of another location via a hard-linked regular file.
        if info.st_mode & S_IFMT != S_IFDIR && info.st_nlink > 1 { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let directory = fdopendir(dup(descriptor)) else { return }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard child != ".", child != ".." else { continue }
                restoreOwnership(parent: descriptor, name: child, uid: uid, gid: gid)
            }
        }
        _ = fchown(descriptor, uid, gid)
    }
}
