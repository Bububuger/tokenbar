import Foundation

/// Tiny TTL cache for `discoverSessionFiles` / `discoverRolloutFiles`. One
/// CheckpointEngine.run cycle fans out source discovery 2-3 times (status +
/// loadEvents + a second statuses collect). Without this cache, 6 sources ×
/// 600 files × 3 callers = ~3,600 directory stats per refresh. The TTL is
/// short enough that file changes still propagate (FSEvents wakes the next
/// refresh, which busts past the TTL on a fresh tick).
public enum DiscoveryCache {
    private static let ttl: TimeInterval = 2.0
    private static let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var cache: [String: (cachedAt: Date, result: [URL])] = [:]
        var hitCount: Int = 0
        var missCount: Int = 0
    }

    public static func cached(
        key: String,
        compute: () throws -> [URL]
    ) rethrows -> [URL] {
        state.lock.lock()
        if let entry = state.cache[key], Date().timeIntervalSince(entry.cachedAt) < ttl {
            state.hitCount += 1
            let result = entry.result
            state.lock.unlock()
            return result
        }
        state.missCount += 1
        state.lock.unlock()
        let result = try compute()
        state.lock.lock()
        state.cache[key] = (Date(), result)
        state.lock.unlock()
        return result
    }

    /// DEBUG-only visibility: how many calls hit the cache. Verification
    /// criterion (B4 in refactor-2026-05-24): one refresh → `hitCount` > 0
    /// once the second caller of the same source comes through.
    public static var hitCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.hitCount
    }
    public static var missCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.missCount
    }

    /// Test-only escape hatch: blow the cache between scenarios so per-test
    /// assertions on `hitCount` / `missCount` stay deterministic.
    public static func reset() {
        state.lock.lock()
        state.cache.removeAll()
        state.hitCount = 0
        state.missCount = 0
        state.lock.unlock()
    }
}
