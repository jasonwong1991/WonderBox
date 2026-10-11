import Darwin
import Foundation
import Security

/// Evidence from the selected bundle, not a product/vendor lookup table. Retained in memory
/// so a verification scan still knows its components after the bundle moves to the Trash.
struct ApplicationRelatedIdentity: Equatable, Sendable {
    var componentIdentifiers: [String] = []
    var applicationGroups: [String] = []
    var declaredHelperIdentifiers: [String] = []
    var dataNames: [String] = []
    var legacyDataNames: [String] = []
    var isComplete = true
}

enum ApplicationIdentityScanner {
    private static let componentRoots = ["Contents/Helpers", "Contents/XPCServices", "Contents/PlugIns",
                                         "Contents/Library/LoginItems", "Contents/Frameworks", "Contents/Library/SystemExtensions",
                                         "Contents/Library/QuickLook", "Contents/Library/Spotlight", "Contents/Library/Services"]

    static func inspect(_ url: URL, maximumBundles: Int = 128,
                        entitlements: (URL) -> [String: Any] = signedEntitlements) -> ApplicationRelatedIdentity {
        var result = ApplicationRelatedIdentity()
        var queue = [url.standardizedFileURL]
        var visited = Set<URL>()
        var components = Set<String>(), groups = Set<String>(), helpers = Set<String>()
        while !queue.isEmpty {
            guard !Task.isCancelled, visited.count < maximumBundles else { result.isComplete = false; break }
            let bundleURL = queue.removeFirst()
            guard visited.insert(bundleURL).inserted, isMaterializedDirectory(bundleURL) else { result.isComplete = false; continue }
            let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
            if noSymlinkComponents(infoURL, below: bundleURL), let info = metadata(infoURL) {
                if bundleURL == url.standardizedFileURL {
                    let names = [info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String,
                                 url.deletingPathExtension().lastPathComponent].compactMap { $0 }
                    let electron = ElectronDataIdentityScanner.inspect(bundleURL, productNames: names)
                    result.dataNames = electron.names
                    result.legacyDataNames = electron.legacyNames
                }
                if bundleURL != url.standardizedFileURL, let identifier = info["CFBundleIdentifier"] as? String,
                   validIdentifier(identifier) { components.insert(identifier) }
                if let declarations = info["SMPrivilegedExecutables"] as? [String: Any] {
                    helpers.formUnion(declarations.keys.filter(validIdentifier))
                }
            } else { result.isComplete = false }
            if let values = entitlements(bundleURL)["com.apple.security.application-groups"] as? [String] {
                groups.formUnion(values.filter(validIdentifier))
            }
            for path in componentRoots {
                let root = bundleURL.appendingPathComponent(path)
                guard noSymlinkComponents(root, below: bundleURL) else { continue }
                do {
                    for child in try RelatedFileScanner.children(root) where
                        RelatedFileLocations.embeddedComponentExtensions.contains(child.pathExtension.lowercased()) {
                        if isRealDirectory(child) { queue.append(child.standardizedFileURL) }
                    }
                } catch {
                    if FilePresence.check(root) != .missing { result.isComplete = false }
                }
            }
        }
        result.componentIdentifiers = components.sorted()
        result.applicationGroups = groups.sorted()
        result.declaredHelperIdentifiers = helpers.sorted()
        return result
    }

    /// Never run app code or obtain containers through FileManager (which can create them).
    static func signedEntitlements(_ url: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              // Validate the signature/entitlement envelope without a whole-app resource walk
              // or network access; these identifiers are association evidence, not app trust.
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil) == errSecSuccess
        else { return [:] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return [:] }
        return values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    static func metadata(_ url: URL) -> [String: Any]? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size < 1_048_576,
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return values
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".")
            && !value.contains("..") && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func isMaterializedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_flags & UInt32(SF_DATALESS) == 0
    }

    static func noSymlinkComponents(_ url: URL, below root: URL) -> Bool {
        let root = root.standardizedFileURL
        var current = url.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { return false }
        while current != root {
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return false }
            current.deleteLastPathComponent()
        }
        return true
    }
}
