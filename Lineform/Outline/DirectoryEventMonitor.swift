import CoreServices
import Foundation

/// Abstraction over recursive directory-change monitoring so the sidebar store can be
/// tested with synthetic events instead of real FSEvents latency.
protocol DirectoryChangeMonitoring: AnyObject {
    func stop()
}

typealias DirectoryChangeMonitorFactory = (_ url: URL, _ onChange: @escaping () -> Void) -> DirectoryChangeMonitoring?

/// Recursive FSEvents watcher for one directory tree. Events are coalesced by FSEvents
/// (`coalescingLatency`) and delivered on the main queue. Own-process events are ignored
/// (`kFSEventStreamCreateFlagIgnoreSelf`): document autosaves must not churn the sidebar
/// scan on every keystroke, and the app's own rename/delete paths broadcast
/// `LineformAppNotification.refreshSidebarFiles` explicitly instead.
final class DirectoryEventMonitor: DirectoryChangeMonitoring {
    static let coalescingLatency: TimeInterval = 0.5

    private var streamRef: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryEventMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.coalescingLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    deinit {
        stop()
    }
}
