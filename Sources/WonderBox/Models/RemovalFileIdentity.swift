import Darwin
import Foundation

/// Confirmation covers the object that was displayed, not a replacement at the
/// same path. Directory mtime changes are allowed; inode/type changes are not.
struct RemovalFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t

    init?(_ url: URL) {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        device = info.st_dev; inode = info.st_ino; type = info.st_mode & S_IFMT
    }
    func stillMatches(_ url: URL) -> Bool {
        self == Self(url) && url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }
}
