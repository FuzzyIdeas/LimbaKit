import CoreServices
import Foundation

/// Reports changed file paths under a folder, through FSEvents.
///
/// Nothing here runs on the main thread except the callback. FSEventStreamStart and Stop are
/// synchronous calls to fseventsd that can block for 30 s while the daemon is busy (right after
/// login, or while it restarts), and a stream scheduled on the main queue registers again with
/// fseventsd on that queue after a restart. So the stream lives on a private serial queue and only
/// the list of paths is sent to the main queue.
final class DirectoryWatcher {
    private static let queue = DispatchQueue(label: "LimbaKit.fsevents", qos: .utility)

    /// Owned by the stream through the context's retain and release, so a callback that was already
    /// queued when the watcher went away finds a live object that knows it was stopped.
    private final class Sink {
        let callback: ([String]) -> Void
        private let lock = NSLock()
        private var _stopped = false
        var stopped: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _stopped }
            set { lock.lock(); _stopped = newValue; lock.unlock() }
        }

        init(callback: @escaping ([String]) -> Void) { self.callback = callback }
    }

    private let sink: Sink
    private var stream: FSEventStreamRef?

    init?(url: URL, latency: TimeInterval = 0.15, callback: @escaping ([String]) -> Void) {
        sink = Sink(callback: callback)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let handler: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            guard !sink.stopped else { return }
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            DispatchQueue.main.async {
                // Checked again: the watcher may have stopped while this block waited.
                if !sink.stopped { sink.callback(list) }
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, handler, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        Self.queue.async { FSEventStreamStart(stream) }
    }

    deinit {
        sink.stopped = true
        guard let stream else { return }
        Self.queue.async {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
