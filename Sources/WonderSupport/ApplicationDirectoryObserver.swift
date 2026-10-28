import CoreServices
import Foundation

/// Recursive filesystem notifications, delivered on the caller's serial queue.
/// Watching has no write access and does not enumerate application contents.
public final class ApplicationDirectoryObserver {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    public init(roots: [URL], queue: DispatchQueue, onChange: @escaping () -> Void) {
        handler = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ApplicationDirectoryObserver>.fromOpaque(info).takeUnretainedValue().handler()
        }, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { stop() }
        }
    }
    public var isActive: Bool { stream != nil }
    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    deinit { stop() }
}
