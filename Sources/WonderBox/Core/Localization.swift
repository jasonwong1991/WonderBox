import AppKit
import Foundation

/// Language plumbing that lives outside the string catalog.
///
/// UI text uses the standard `String(localized:)` / `LocalizedStringKey` machinery against `Bundle.main`:
/// keys are the English source strings, `Resources/Localizable.xcstrings` holds the translations, and
/// `scripts/package_app.sh` compiles the catalog into `Contents/Resources/<language>.lproj`.
enum L10n {
    /// Localizes text produced outside this process (the helper daemon and the SMC layer), where the
    /// English message doubles as the catalog key. Messages without a translation pass through unchanged.
    static func message(_ text: String) -> String {
        Bundle.main.localizedString(forKey: text, value: text, table: nil)
    }
}

/// Per-app UI language. Writing `AppleLanguages` into the app's own defaults domain is the same
/// mechanism System Settings › General › Language & Region uses for per-app languages, so it
/// takes effect on the next launch and needs no custom bundle swapping.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: Self { self }

    /// Native names stay untranslated so users can always find their own language.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    private static let defaultsKey = "AppleLanguages"

    /// Reads only the app's persistent domain; `UserDefaults.standard` would fall through to the
    /// global language list and report the system language as an explicit choice.
    static var current: AppLanguage {
        guard let identifier = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: identifier)?[defaultsKey] as? [String],
              let first = languages.first
        else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    /// Persists the choice; the running process keeps its language until `relaunch()`.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// Starts a second instance before quitting so the window comes back without a gap in the menu bar.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
