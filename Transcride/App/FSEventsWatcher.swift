import Foundation
import CoreServices

/// Recursive file-system watcher on the vault root. Events are coalesced by
/// FSEvents latency; our own in-process writes are ignored (`IgnoreSelf`)
/// because the app refreshes explicitly after its own operations.
final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.ashandevine.transcride.fsevents")
    private let handler: @Sendable () -> Void

    init?(url: URL, latency: CFTimeInterval = 0.7, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        self.stream = nil

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
