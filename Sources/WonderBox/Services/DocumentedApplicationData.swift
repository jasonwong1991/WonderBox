import Foundation

/// Documented layouts that cannot be inferred from an exact app name/bundle ID at
/// the usual Library depth. Keep these narrow: no vendor-wide or product-prefix deletion.
/// Sources and limits are recorded in docs/RELATED_FILES.md.
enum DocumentedApplicationData {
    struct Rule {
        let libraryPath: String
        let exactNames: [String]
        let matches: (String) -> Bool
    }

    static func rules(for identifier: String?) -> [Rule] {
        guard let identifier = identifier?.lowercased() else { return [] }
        if isNavicatPremium(identifier) {
            // This leaf is shared across Premium versions, not across Navicat products.
            // Never offer PremiumSoft CyberTech, Navicat CC or its Common sibling.
            return [Rule(libraryPath: "Application Support/PremiumSoft CyberTech/Navicat CC",
                         exactNames: ["Navicat Premium"], matches: { $0.lowercased() == "navicat premium" })]
        }
        if identifier == "com.jetbrains.datagrip" {
            return ["Application Support", "Caches", "Logs"].map { root in
                Rule(libraryPath: root + "/JetBrains", exactNames: ["DataGrip"], matches: isDataGripDirectory)
            }
        }
        return []
    }

    private static func isNavicatPremium(_ identifier: String) -> Bool {
        if identifier == "com.navicat.navicatpremium" { return true }
        let legacyStem = "com.prect.navicatpremium"
        guard identifier.hasPrefix(legacyStem) else { return false }
        // Older releases append a major version directly to the bundle ID.
        // A helper, Lite edition or lookalike must not inherit Premium's data.
        let suffix = identifier.dropFirst(legacyStem.count)
        return !suffix.isEmpty && suffix.count <= 3 && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isDataGripDirectory(_ name: String) -> Bool {
        let name = name.lowercased(), product = "datagrip"
        guard name.hasPrefix(product) else { return false }
        let suffix = name.dropFirst(product.count)
        if suffix.isEmpty { return true }
        let version = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(version.count), version[0].count == 4, version[0].hasPrefix("20"),
              (1...2).contains(version[1].count), version.count < 3 || (1...3).contains(version[2].count)
        else { return false }
        return version.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }
}
