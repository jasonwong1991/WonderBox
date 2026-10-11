import Foundation

/// Storage conventions, not application-specific aliases. See docs/RELATED_FILES.md.
enum RelatedFileLocations {
    static let recentDocuments = "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    static let recentDocumentExtensions = ["sfl", "sfl2", "sfl3"]
    static let xdgRoots = [".config", ".cache", ".local/share", ".local/state"]
    // Probe only an exact app-owned leaf; never offer the shared SDK directory itself.
    static let sharedCacheRoots = ["org.sparkle-project.Sparkle", "SentryCrash", "KSCrash"]
    static let pluginRoots: [(path: String, extensions: Set<String>)] = [
        ("QuickLook", ["qlgenerator"]), ("Spotlight", ["mdimporter"]),
        ("Services", ["service"]), ("PreferencePanes", ["prefpane"]),
        ("Internet Plug-Ins", ["plugin", "bundle"]), ("Screen Savers", ["saver"]),
        ("Audio/Plug-Ins/Components", ["component"]), ("Audio/Plug-Ins/VST", ["vst"]),
        ("Audio/Plug-Ins/VST3", ["vst3"]), ("Audio/Plug-Ins/CLAP", ["clap"])
    ]
    static let embeddedComponentExtensions: Set<String> = [
        "app", "xpc", "appex", "systemextension", "qlgenerator", "mdimporter", "service",
        "prefpane", "plugin", "bundle", "saver", "component", "vst", "vst3", "clap"
    ]
}
