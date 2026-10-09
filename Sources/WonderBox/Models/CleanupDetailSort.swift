import Foundation

enum CleanupDetailSort: String {
    case name, size

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .size: String(localized: "Size")
        }
    }
}

struct CleanupDetailOrdering {
    var field: CleanupDetailSort = .name
    var ascending = true

    mutating func select(_ field: CleanupDetailSort) {
        if self.field == field { ascending.toggle() }
        else { self.field = field; ascending = field == .name }
    }

    func groups(_ groups: [ApplicationCacheGroup]) -> [ApplicationCacheGroup] {
        groups.sorted { lhs, rhs in
            if field == .size {
                let lhsUnknown = !lhs.isSizeEstimated && lhs.size == 0
                let rhsUnknown = !rhs.isSizeEstimated && rhs.size == 0
                if lhsUnknown != rhsUnknown { return !lhsUnknown }
                if lhs.size != rhs.size { return ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
            } else if (lhs.id == "unidentified") != (rhs.id == "unidentified") {
                return lhs.id != "unidentified"
            }
            let comparison = lhs.application.name.localizedStandardCompare(rhs.application.name)
            if comparison != .orderedSame {
                return field == .name && !ascending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func items(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted { lhs, rhs in
            if field == .size {
                let lhsUnknown = !lhs.isSizeEstimated && lhs.size == 0
                let rhsUnknown = !rhs.isSizeEstimated && rhs.size == 0
                if lhsUnknown != rhsUnknown { return !lhsUnknown }
                if lhs.size != rhs.size { return ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
            }
            let comparison = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            if comparison != .orderedSame {
                return field == .name && !ascending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            return lhs.url.path < rhs.url.path
        }
    }
}
