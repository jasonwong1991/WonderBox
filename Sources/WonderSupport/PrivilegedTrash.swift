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
    public var failures: [TrashFailure] = []
    public init() {}

    enum CodingKeys: String, CodingKey { case moved, failed, failures }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        moved = try values.decode(Int.self, forKey: .moved)
        failed = try values.decode([String].self, forKey: .failed)
        failures = try values.decodeIfPresent([TrashFailure].self, forKey: .failures) ?? []
    }
}

/// Request indices keep error details compact; no paths or localized descriptions enter diagnostics.
public struct TrashFailure: Codable, Sendable, Equatable {
    public enum Stage: Int, Codable, Sendable {
        case request = 1, trashDirectory, sourceParent, sourceItem, lockedItem, unsafePath, destination, move
    }
    public let index: Int
    public let stage: Stage
    public let errorCode: Int32
    public init(index: Int, stage: Stage, errorCode: Int32) {
        self.index = index
        self.stage = stage
        self.errorCode = errorCode
    }
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
        move(request, uid: uid, gid: gid, home: home, directoryOpener: openDirectory)
    }

    // Injection is internal to WonderSupport, solely for deterministic permission-failure tests.
    static func move(_ request: TrashRequest, uid: uid_t, gid: gid_t, home: String,
                     directoryOpener: (String) -> Int32?) -> TrashResponse {
        var response = TrashResponse()
        func fail(_ index: Int, _ stage: TrashFailure.Stage, _ code: Int32) {
            response.failed.append(request.paths[index])
            response.failures.append(TrashFailure(index: index, stage: stage, errorCode: code))
        }
        func failAll(_ stage: TrashFailure.Stage, _ code: Int32) {
            for index in request.paths.indices { fail(index, stage, code) }
        }
        guard request.paths.count <= 256 else {
            failAll(.request, E2BIG)
            return response
        }
        guard !request.paths.isEmpty else { return response }
        guard let trash = directoryOpener(home + "/.Trash") else {
            failAll(.trashDirectory, errno)
            return response
        }
        defer { close(trash) }
        var trashInfo = stat()
        guard fstat(trash, &trashInfo) == 0 else {
            failAll(.trashDirectory, errno)
            return response
        }
        guard trashInfo.st_uid == uid else {
            failAll(.trashDirectory, EACCES)
            return response
        }
        for (index, path) in request.paths.enumerated() {
            guard isAllowed(path, home: home) else {
                fail(index, .unsafePath, EINVAL)
                continue
            }
            guard let parent = directoryOpener(URL(fileURLWithPath: path).deletingLastPathComponent().path) else {
                fail(index, .sourceParent, errno)
                continue
            }
            defer { close(parent) }
            let name = URL(fileURLWithPath: path).lastPathComponent
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                fail(index, .sourceItem, errno)
                continue
            }
            guard info.st_mode & S_IFMT != S_IFLNK else {
                fail(index, .unsafePath, ELOOP)
                continue
            }
            guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_NOUNLINK) == 0 else {
                fail(index, .lockedItem, EPERM)
                continue
            }
            let destination = "WonderBox-\(UUID().uuidString)"
            // A private, user-owned wrapper keeps every move unique while preserving the original
            // file name. Restoring an app from Finder needs no renamed .app bundle or merge.
            guard mkdirat(trash, destination, 0o700) == 0 else {
                fail(index, .destination, errno)
                continue
            }
            let wrapper = openat(trash, destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard wrapper >= 0 else {
                let code = errno
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                fail(index, .destination, code)
                continue
            }
            defer { close(wrapper) }
            var wrapperInfo = stat()
            guard fstat(wrapper, &wrapperInfo) == 0 else {
                fail(index, .destination, errno)
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                continue
            }
            guard wrapperInfo.st_uid == geteuid(), wrapperInfo.st_mode & 0o077 == 0 else {
                fail(index, .destination, EACCES)
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                continue
            }
            if renameatx_np(parent, name, wrapper, name, UInt32(RENAME_EXCL)) == 0 {
                // Do this before handing the wrapper to the user, so they cannot substitute entries.
                restoreOwnership(parent: wrapper, name: name, uid: uid, gid: gid)
                _ = fchown(wrapper, uid, gid)
                response.moved += 1
            } else {
                let code = errno
                _ = unlinkat(trash, destination, AT_REMOVEDIR)
                fail(index, .move, code)
            }
        }
        return response
    }

    private static func openDirectory(_ path: String) -> Int32? {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            guard next >= 0 else { errno = code; return nil }
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
