import Foundation

/// Presentation only: never changes selection, starts a scan or waits for size measurement.
/// The scanner supplies non-overlapping roots; normalize again to avoid counting aliases twice.
struct RelatedFileSelectionSummary: Equatable {
    let omittedCount: Int
    let omittedSize: UInt64
    let hasMeasuredSize: Bool
    let isSizeComplete: Bool

    init(files: [RelatedFile]) {
        let omitted = ApplicationStorageUsage.uniqueRoots(files).filter { !$0.isSelected }
        omittedCount = omitted.count
        omittedSize = omitted.reduce(0) { ApplicationStorageUsage.add($0, $1.size) }
        hasMeasuredSize = omitted.contains(where: \.hasMeasuredSize)
        isSizeComplete = omitted.allSatisfy { $0.hasMeasuredSize && $0.isSizeComplete }
    }

    var sizeText: String {
        guard hasMeasuredSize else { return String(localized: "Not measured") }
        return (isSizeComplete ? "" : "≥ ") + AppFormatters.bytes(omittedSize)
    }

    var warning: String? {
        guard omittedCount > 0 else { return nil }
        return String(localized: "\(omittedCount) related items are not selected (\(sizeText)) and will be kept.")
    }

    var confirmTitle: String {
        omittedCount > 0 ? String(localized: "Move Selected Items to Trash") : String(localized: "Move to Trash")
    }

    var cancelTitle: String {
        omittedCount > 0 ? String(localized: "Review Selection") : String(localized: "Cancel")
    }

    func confirmationMessage(removesBundle: Bool) -> String {
        let message = removesBundle
            ? String(localized: "The app and the selected related files will be moved to the Trash.")
            : String(localized: "Only the selected related files will be moved to the Trash. The app already in the Trash will be kept.")
        return warning.map { message + "\n\n" + $0 } ?? message
    }
}
