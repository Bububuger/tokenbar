import Foundation

public final class ThrottledDelayer: @unchecked Sendable {
    private let nanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?
    private let lock = NSLock()

    public init(milliseconds: Int) {
        self.nanoseconds = UInt64(milliseconds) * 1_000_000
    }

    public func schedule(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await action()
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        pendingTask?.cancel()
        pendingTask = nil
        lock.unlock()
    }
}
