import Foundation

/// Compare semantic versions numerically; never downgrade or mistake 0.10 for 0.1.
struct AppVersion: Comparable, Equatable, Sendable {
    let components: [Int]
    let prerelease: [String]

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let buildParts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
              buildParts.count == 1 || Self.validIdentifiers(String(buildParts[1])) else { return nil }
        let parts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        let parsed = numbers.compactMap { part -> Int? in
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        guard parsed.count == 3 else { return nil }
        components = parsed
        if parts.count == 2 {
            guard Self.validIdentifiers(String(parts[1])) else { return nil }
            prerelease = parts[1].split(separator: ".").map(String.init)
            guard prerelease.allSatisfy({ identifier in
                !identifier.allSatisfy(\.isNumber) || identifier.count == 1 || !identifier.hasPrefix("0")
            }) else { return nil }
        } else {
            prerelease = []
        }
    }

    private static func validIdentifiers(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let aNumeric = a.allSatisfy(\.isNumber), bNumeric = b.allSatisfy(\.isNumber)
            if aNumeric && bNumeric { return a.count == b.count ? a < b : a.count < b.count }
            if aNumeric != bNumeric { return aNumeric }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    func availableUpdate(after current: String) throws -> AvailableUpdate? {
        guard !draft, !prerelease,
              let version = AppVersion(tagName), version.prerelease.isEmpty,
              let installed = AppVersion(current),
              UpdateSource.isReleasePage(htmlURL, tag: tagName) else { throw UpdateError.invalidRelease }
        guard installed < version else { return nil }
        let number = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let expectedName = "WonderBox-\(number).zip"
        guard let asset = assets.first(where: { $0.name == expectedName }),
              asset.size > 0, asset.size <= UpdateSource.maximumDownloadSize,
              UpdateSource.isAssetURL(asset.browserDownloadURL, tag: tagName, name: asset.name) else {
            throw UpdateError.missingAsset
        }
        // A malformed advertised digest is an error, not a reason to silently weaken validation.
        let checksum: String?
        if let digest = asset.digest {
            guard digest.hasPrefix("sha256:"), UpdateSource.isSHA256(String(digest.dropFirst(7))) else {
                throw UpdateError.invalidChecksum
            }
            checksum = String(digest.dropFirst(7)).lowercased()
        } else { checksum = nil }
        let sums = assets.first { $0.name == "SHA256SUMS" && $0.size > 0 && $0.size <= 65_536 }
        let checksumURL = sums.flatMap {
            UpdateSource.isAssetURL($0.browserDownloadURL, tag: tagName, name: $0.name) ? $0.browserDownloadURL : nil
        }
        guard checksum != nil || checksumURL != nil else { throw UpdateError.invalidChecksum }
        return AvailableUpdate(version: number, releaseURL: htmlURL, notes: String((body ?? "").prefix(16_384)),
                               asset: asset, sha256: checksum, checksumURL: checksumURL)
    }
}

struct AvailableUpdate: Sendable {
    let version: String
    let releaseURL: URL
    let notes: String
    let asset: GitHubRelease.Asset
    let sha256: String?
    let checksumURL: URL?
}

enum UpdateSource {
    static let repositoryPath = "/jasonwong1991/WonderBox/releases"
    static let latestURL = URL(string: "https://api.github.com/repos/jasonwong1991/WonderBox/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/jasonwong1991/WonderBox/releases")!
    static let latestPageURL = URL(string: "https://github.com/jasonwong1991/WonderBox/releases/latest")!
    static let maximumDownloadSize: Int64 = 200 * 1_024 * 1_024
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private static func isHTTPS(_ url: URL, host: String) -> Bool {
        url.scheme == "https" && url.host == host && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443) && url.fragment == nil
    }

    static func isReleasePage(_ url: URL, tag: String) -> Bool {
        isHTTPS(url, host: "github.com") && url.path == "\(repositoryPath)/tag/\(tag)" && url.query == nil
    }

    static func isAssetURL(_ url: URL, tag: String, name: String) -> Bool {
        isHTTPS(url, host: "github.com") && url.path == "\(repositoryPath)/download/\(tag)/\(name)" && url.query == nil
    }

    static func releaseTag(from url: URL) throws -> String {
        let tag = url.lastPathComponent
        guard let version = AppVersion(tag), version.prerelease.isEmpty, isReleasePage(url, tag: tag) else {
            throw UpdateError.invalidRelease
        }
        return tag
    }

    static func permitsRedirect(to url: URL) -> Bool {
        ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains {
            isHTTPS(url, host: $0)
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func checksum(in data: Data, filename: String) throws -> String {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { throw UpdateError.invalidChecksum }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename,
                  isSHA256(String(fields[0])) else { return nil }
            return String(fields[0]).lowercased()
        }
        guard matches.count == 1 else { throw UpdateError.invalidChecksum }
        return matches[0]
    }

    static func shouldCheck(automatically: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard automatically else { return false }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= checkInterval || elapsed < 0
    }
}

enum UpdateError: Error, Equatable {
    case http(Int), invalidRelease, missingAsset, invalidChecksum, checksumMismatch, invalidArchive, oversized, sizeMismatch, destination

    var diagnosticCode: Int64 {
        switch self {
        case .http: 1
        case .invalidRelease: 2
        case .missingAsset: 3
        case .invalidChecksum: 4
        case .checksumMismatch: 5
        case .invalidArchive: 6
        case .oversized: 7
        case .sizeMismatch: 8
        case .destination: 9
        }
    }

    var message: String {
        switch self {
        case .http(403), .http(429): String(localized: "GitHub is limiting requests. Try again later.")
        case .http: String(localized: "GitHub did not return a release. Try again later.")
        case .invalidRelease: String(localized: "The release information is invalid.")
        case .missingAsset: String(localized: "This release has no compatible download.")
        case .invalidChecksum: String(localized: "This release has no valid SHA-256 checksum.")
        case .checksumMismatch: String(localized: "Download verification failed. Please download again.")
        case .invalidArchive: String(localized: "The downloaded file is not an app archive.")
        case .oversized, .sizeMismatch: String(localized: "The download size does not match the release.")
        case .destination: String(localized: "The download could not be saved. Choose another location.")
        }
    }
}
