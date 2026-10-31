import CoreServices
import Foundation

/// Observa mudanças em árvores de diretórios (FSEvents) com debounce. Leitura apenas: nunca escreve nos diretórios.
public final class TreeWatcher: @unchecked Sendable { // SAFETY: `stream` só é tocado sob `lock`.
    private let paths: [String]
    private let latency: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "racky.insights.fsevents", qos: .utility)
    // LOCK: protege só `stream` (criar/parar o FSEventStream); nenhuma E/S sob o lock.
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 2, handler: @escaping @Sendable () -> Void) {
        self.paths = paths; self.latency = latency; self.handler = handler
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
