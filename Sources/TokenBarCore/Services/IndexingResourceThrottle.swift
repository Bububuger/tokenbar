import Foundation

public struct IndexingResourceBudget: Sendable, Hashable {
    public let cpuPercent: Double

    public init(cpuPercent: Double = 5) {
        self.cpuPercent = min(100, max(1, cpuPercent))
    }

    public static let backgroundCPUPercent: Double = 3
    public static let initialIndexCPUPercent: Double = 20
    public static let background = IndexingResourceBudget(cpuPercent: backgroundCPUPercent)
    public static let initialIndex = IndexingResourceBudget(cpuPercent: initialIndexCPUPercent)

    var activeRatio: Double {
        cpuPercent / 100
    }
}

public struct IndexingResourceSnapshot: Codable, Sendable, Hashable {
    public let cpuPercent: Double
    public let activeSeconds: TimeInterval
    public let sleepSeconds: TimeInterval

    public var estimatedCPUPercent: Double {
        let elapsed = activeSeconds + sleepSeconds
        guard elapsed > 0 else { return 0 }
        return min(100, max(0, activeSeconds / elapsed * 100))
    }
}

public actor IndexingResourceThrottle {
    private let budget: IndexingResourceBudget
    private var activeSeconds: TimeInterval = 0
    private var sleepSeconds: TimeInterval = 0

    public init(budget: IndexingResourceBudget = .background) {
        self.budget = budget
    }

    public func rest(afterActive active: TimeInterval) async {
        guard active > 0, !Task.isCancelled else {
            return
        }

        activeSeconds += active
        let targetElapsed = activeSeconds / budget.activeRatio
        let actualElapsed = activeSeconds + sleepSeconds
        let sleepDuration = max(0, targetElapsed - actualElapsed)
        guard sleepDuration > 0.001 else {
            return
        }

        sleepSeconds += sleepDuration
        try? await Task.sleep(for: .seconds(sleepDuration))
    }

    public func snapshot() -> IndexingResourceSnapshot {
        IndexingResourceSnapshot(
            cpuPercent: budget.cpuPercent,
            activeSeconds: activeSeconds,
            sleepSeconds: sleepSeconds
        )
    }
}

public protocol ResourceBudgetedUsageEventSource: UsageEventSource {
    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar,
        resourceThrottle: IndexingResourceThrottle?
    ) async throws -> UsageSourceLoadResult
}
