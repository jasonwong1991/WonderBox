import Darwin
import Foundation
import WonderSupport

/// Interpret typed helper failures rather than calling every failure a root-password problem.
struct PrivilegedTrashFeedback {
    let message: String?
    let needsPrivacySettings: Bool

    init(_ response: TrashResponse) {
        guard !response.failed.isEmpty else { message = nil; needsPrivacySettings = false; return }
        var messages: [String] = []
        var privacy = false
        for failure in response.failures {
            let text: String
            if failure.stage == .lockedItem {
                text = String(localized: "Some items are locked. Check Locked in Finder's Get Info, then retry.")
            } else if failure.stage == .unsafePath || failure.errorCode == ELOOP {
                text = String(localized: "The background service skipped an unsupported path or symbolic link. Show the item in Finder to review it.")
            } else if failure.errorCode == EPERM {
                privacy = true
                text = failure.stage == .trashDirectory
                    ? String(localized: "macOS denied the background service access to your Trash. This does not establish whether WonderBox has Full Disk Access.")
                    : String(localized: "macOS denied the background service's file operation. Export diagnostic logs from Settings to investigate the cause.")
            } else if failure.errorCode == EACCES {
                text = String(localized: "The background service encountered a folder ownership or access-permission error. Check Sharing & Permissions in Finder's Get Info.")
            } else if failure.errorCode == EXDEV {
                text = String(localized: "The background service did not move items across disks. Use Finder to move them to that disk's Trash.")
            } else if failure.errorCode == EROFS {
                text = String(localized: "The selected item or Trash is on a read-only volume.")
            } else if failure.errorCode == ENOSPC || failure.errorCode == EDQUOT {
                text = String(localized: "There is not enough space to create a Trash destination.")
            } else if failure.errorCode == ENOENT {
                text = failure.stage == .trashDirectory
                    ? String(localized: "The background service did not find your Trash folder. Reopen WonderBox and retry.")
                    : String(localized: "Some items disappeared during removal. Rescan to refresh the list.")
            } else {
                text = String(localized: "The background service reported a file-operation error (\(Int(failure.errorCode))). Export diagnostic logs if it persists.")
            }
            if !messages.contains(text) { messages.append(text) }
        }
        message = messages.isEmpty
            ? String(localized: "The background service left some items in place. Export diagnostic logs if retrying does not help.")
            : messages.prefix(3).joined(separator: " · ")
        needsPrivacySettings = privacy
    }
}
