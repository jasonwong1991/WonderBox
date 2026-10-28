import Foundation

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case color
    case monochrome

    static let storageKey = "menuBarIconStyle"
    // Keep the original appearance unless the user explicitly chooses a template icon.
    static let defaultStyle: Self = .color

    var id: Self { self }

    var title: String {
        switch self {
        case .color: String(localized: "Color")
        case .monochrome: String(localized: "Monochrome")
        }
    }
}
