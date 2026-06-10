import CoreServices
import Foundation

public protocol FileWatcher: Sendable {
    func start() async throws
    func stop() async
}

public struct NoOpFileWatcher: FileWatcher {
    public init() {}

    public func start() async throws {}

    public func stop() async {}
}

public final class RecursiveFSEventsWatcher: FileWatcher, @unchecked Sendable {
    private let paths: [String]
    private let debounceNanoseconds: UInt64
    private let streamLatency: CFTimeInterval
    private let missingRootPollNanoseconds: UInt64
    private let changePollNanoseconds: UInt64
    private let onChange: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "com.javis.TokenBar.fsevents", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pendingTask: Task<Void, Never>?
    private var missingRootTask: Task<Void, Never>?
    private var watchedRoots: Set<String> = []
    private var rootModificationDates: [String: Date] = [:]

    public init(
        paths: [String],
        debounceNanoseconds: UInt64 = 2_000_000_000,
        streamLatency: CFTimeInterval = 0.25,
        missingRootPollNanoseconds: UInt64 = 30_000_000_000,
        changePollNanoseconds: UInt64 = 60_000_000_000,
        onChange: @escaping @Sendable () async -> Void
    ) {
        self.paths = paths
        self.debounceNanoseconds = debounceNanoseconds
        self.streamLatency = streamLatency
        self.missingRootPollNanoseconds = missingRootPollNanoseconds
        self.changePollNanoseconds = changePollNanoseconds
        self.onChange = onChange
    }

    deinit {
        stopStream()
        pendingTask?.cancel()
        missingRootTask?.cancel()
    }

    public func start() async throws {
        rebuildStream()
        startMissingRootPolling()
    }

    public func refresh() async throws {
        rebuildStream()
        startMissingRootPolling()
    }

    public func stop() async {
        pendingTask?.cancel()
        pendingTask = nil
        missingRootTask?.cancel()
        missingRootTask = nil
        stopStream()
    }

    private func rebuildStream() {
        let roots = existingRoots()
        lock.lock()
        let oldRoots = watchedRoots
        lock.unlock()
        guard roots != oldRoots else {
            return
        }

        stopStream()
        lock.lock()
        watchedRoots = roots
        rootModificationDates = modificationDates(for: roots)
        lock.unlock()

        guard !roots.isEmpty else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RecursiveFSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let eventArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let paths = eventArray.compactMap { $0 as? String }
            let count = min(paths.count, Int(eventCount))
            watcher.handleFSEvents(Array(paths[0..<count]))
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let newStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(roots) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            streamLatency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)

        lock.lock()
        stream = newStream
        lock.unlock()
    }

    private func stopStream() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()

        guard let current else {
            return
        }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private func existingRoots() -> Set<String> {
        Set(paths.map(CodexDataSource.expandHome(in:)).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
    }

    private func startMissingRootPolling() {
        lock.lock()
        missingRootTask?.cancel()
        missingRootTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: min(self.missingRootPollNanoseconds, self.changePollNanoseconds))
                guard !Task.isCancelled else { return }
                if self.hasNewExistingRoot() {
                    self.rebuildStream()
                    self.scheduleDebouncedChange()
                } else if self.hasRootDirectoryChange() {
                    self.scheduleDebouncedChange()
                }
            }
        }
        lock.unlock()
    }

    private func hasNewExistingRoot() -> Bool {
        let roots = existingRoots()
        lock.lock()
        let oldRoots = watchedRoots
        lock.unlock()
        return !roots.subtracting(oldRoots).isEmpty
    }

    private func hasRootDirectoryChange() -> Bool {
        let roots = existingRoots()
        let currentDates = modificationDates(for: roots)
        lock.lock()
        let previousDates = rootModificationDates
        if currentDates != previousDates {
            rootModificationDates = currentDates
            lock.unlock()
            return true
        }
        lock.unlock()
        return false
    }

    private func modificationDates(for roots: Set<String>) -> [String: Date] {
        var dates: [String: Date] = [:]
        for root in roots {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root)
            dates[root] = attributes?[.modificationDate] as? Date
        }
        return dates
    }

    private func handleFSEvents(_ paths: [String]) {
        _ = paths
        scheduleDebouncedChange()
    }

    private func scheduleDebouncedChange() {
        lock.lock()
        pendingTask?.cancel()
        pendingTask = Task { [debounceNanoseconds, onChange] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await onChange()
        }
        lock.unlock()
    }
}

public typealias DirectoryFileWatcher = RecursiveFSEventsWatcher
