import CoreServices
import Foundation

/// Abstraction over recursive directory-change monitoring so the sidebar store can be
/// tested with synthetic events instead of real FSEvents latency.
protocol DirectoryChangeMonitoring: AnyObject {
    func stop()
}

typealias DirectoryChangeMonitorFactory = (_ url: URL, _ onChange: @escaping () -> Void) -> DirectoryChangeMonitoring?

/// Recursive FSEvents watcher for one directory tree. Events are coalesced by FSEvents
/// (`coalescingLatency`) and delivered on the main queue. Own-process events are
/// deliberately NOT filtered out (no `kFSEventStreamCreateFlagIgnoreSelf`): the app's own
/// writes — autosave, Save As, first save of an untitled document — must refresh the
/// sidebar too, or a "Date Modified" sort goes stale for exactly the files the user is
/// editing. Coalescing plus the store's publish-only-on-change guard keep autosave churn
/// cheap. The `refreshSidebarFiles` broadcast still exists for instant (un-coalesced)
/// refresh after in-app rename/delete.
final class DirectoryEventMonitor: DirectoryChangeMonitoring {
    static let coalescingLatency: TimeInterval = 0.5

    private var streamRef: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        // The stream retains the monitor (retain/release callbacks) so an already-enqueued
        // coalesced callback can never dereference a freed monitor if the owning store is
        // released with an event in flight. stop() breaks the cycle.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DirectoryEventMonitor>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DirectoryEventMonitor>.fromOpaque(info).release()
            },
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
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
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
