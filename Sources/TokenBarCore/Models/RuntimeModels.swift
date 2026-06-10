import Foundation

public enum RefreshIntervalOption: String, CaseIterable, Sendable, Hashable {
    case auto
    case oneMinute
    case fiveMinutes
    case thirtyMinutes
    case manualOnly

    public var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .oneMinute:
            "1 minute"
        case .fiveMinutes:
            "5 minutes"
        case .thirtyMinutes:
            "30 minutes"
        case .manualOnly:
            "Manual only"
        }
    }

    public var staleThreshold: TimeInterval? {
        switch self {
        case .auto:
            120
        case .oneMinute:
            120
        case .fiveMinutes:
            600
        case .thirtyMinutes:
            3600
        case .manualOnly:
            nil
        }
    }

    public var refreshCadence: TimeInterval? {
        switch self {
        case .auto:
            15
        case .oneMinute:
            60
        case .fiveMinutes:
            300
        case .thirtyMinutes:
            1_800
        case .manualOnly:
            nil
        }
    }
}

public enum RefreshState: String, Sendable, Hashable {
    case idle
    case refreshing
    case stale
    case failed
}

public enum RefreshStateEvaluator {
    public static func evaluate(
        now: Date,
        lastIndexedAt: Date?,
        lastRebuildError: String?,
        refreshInterval: RefreshIntervalOption
    ) -> RefreshState {
        if lastRebuildError != nil {
            return .failed
        }

        guard let lastIndexedAt else {
            return .stale
        }

        guard let threshold = refreshInterval.staleThreshold else {
            return .idle
        }

        return now.timeIntervalSince(lastIndexedAt) > threshold ? .stale : .idle
    }
}

public struct UsageDataSourceStatus: Identifiable, Sendable, Hashable {
    public let sourceName: String
    public let rootPath: String
    public let isReadable: Bool
    public let discoveredFileCount: Int

    public var id: String { sourceName }

    public init(sourceName: String, rootPath: String, isReadable: Bool, discoveredFileCount: Int) {
        self.sourceName = sourceName
        self.rootPath = rootPath
        self.isReadable = isReadable
        self.discoveredFileCount = discoveredFileCount
    }
}

public struct DiagnosticsSnapshot: Sendable, Hashable {
    public let dataSourceStatuses: [UsageDataSourceStatus]
    public let lastIndexedAt: Date?
    public let lastUIRefreshAt: Date?
    public let lastCheckpointID: Int64?
    public let lastCheckpointEventsAdded: Int
    public let lastCheckpointPromptsAdded: Int
    public let parserWarningCount: Int
    public let refreshState: RefreshState
    public let rebuildError: String?

    public init(
        dataSourceStatuses: [UsageDataSourceStatus],
        lastIndexedAt: Date?,
        lastUIRefreshAt: Date?,
        lastCheckpointID: Int64? = nil,
        lastCheckpointEventsAdded: Int = 0,
        lastCheckpointPromptsAdded: Int = 0,
        parserWarningCount: Int,
        refreshState: RefreshState,
        rebuildError: String?
    ) {
        self.dataSourceStatuses = dataSourceStatuses
        self.lastIndexedAt = lastIndexedAt
        self.lastUIRefreshAt = lastUIRefreshAt
        self.lastCheckpointID = lastCheckpointID
        self.lastCheckpointEventsAdded = lastCheckpointEventsAdded
        self.lastCheckpointPromptsAdded = lastCheckpointPromptsAdded
        self.parserWarningCount = parserWarningCount
        self.refreshState = refreshState
        self.rebuildError = rebuildError
    }
}
