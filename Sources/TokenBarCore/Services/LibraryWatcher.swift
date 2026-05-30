import CoreServices
import Foundation

public final class LibraryWatcher: @unchecked Sendable {
    private let debouncer = ThrottledDelayer(milliseconds: 3000)
    private let onChange: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "com.javis.TokenBar.library-watcher", qos: .utility)
    private let lock = NSLock()
    private var streams: [FSEventStreamRef] = []
    private var watchedPaths: Set<String> = []
    private var fallbackTask: Task<Void, Never>?

    public init(onChange: @escaping @Sendable () async -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start(roots: [URL], symlinkTargets: [URL] = []) {
        stop()

        var allPaths = Set<String>()
        for root in roots {
            let path = root.path
            if FileManager.default.fileExists(atPath: path) {
                allPaths.insert(path)
            }
        }
        for target in symlinkTargets {
            let path = target.path
            if FileManager.default.fileExists(atPath: path) {
                allPaths.insert(path)
            }
        }

        lock.lock()
        watchedPaths = allPaths
        lock.unlock()

        guard !allPaths.isEmpty else { return }

        let pathArray = Array(allPaths) as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            LibraryWatcher.fsCallback,
            &context,
            pathArray as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        lock.lock()
        streams.append(stream)
        lock.unlock()

        startFallbackRescan()
    }

    public func stop() {
        lock.lock()
        let currentStreams = streams
        streams.removeAll()
        watchedPaths.removeAll()
        lock.unlock()

        for stream in currentStreams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        debouncer.cancel()
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    public func updateSymlinkTargets(_ targets: [URL]) {
        lock.lock()
        let currentRoots = watchedPaths
        lock.unlock()

        var newTargetPaths = Set<String>()
        for target in targets {
            let path = target.path
            if FileManager.default.fileExists(atPath: path) && !currentRoots.contains(path) {
                newTargetPaths.insert(path)
            }
        }

        guard !newTargetPaths.isEmpty else { return }

        let pathArray = Array(newTargetPaths) as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            LibraryWatcher.fsCallback,
            &context,
            pathArray as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        lock.lock()
        streams.append(stream)
        watchedPaths.formUnion(newTargetPaths)
        lock.unlock()
    }

    private func handleFSEvent() {
        let callback = onChange
        debouncer.schedule {
            await callback()
        }
    }

    private func startFallbackRescan() {
        fallbackTask?.cancel()
        let callback = onChange
        fallbackTask = Task {
            while !Task.isCancelled {
                // Catches project-root changes (which we don't FSEvent-watch
                // to avoid handle limits) and any FSEvents the kernel
                // doesn't fan out (e.g. SMB mounts, sandboxed writers).
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await callback()
            }
        }
    }

    private static let fsCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleFSEvent()
    }
}
