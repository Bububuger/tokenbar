import Foundation
import GRDB

public struct WarpUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "Warp"
    public let rootPath: String
    public let agent: AgentKind = .warp
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.rootPath = Self.discoverDatabasePath(fileManager: fileManager)
            ?? "~/Library/Group Containers/*.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = referenceDate
        _ = calendar
        let path = expandedPath
        guard fileManager.isReadableFile(atPath: path) else {
            return UsageSourceLoadResult(events: [], prompts: [], nextWatermarks: [], warnings: [])
        }
        return try WarpUsageParser.parse(
            databaseURL: URL(fileURLWithPath: path),
            watermark: watermarks[path]
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let path = expandedPath
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: path),
            discoveredFileCount: fileManager.fileExists(atPath: path) ? 1 : 0
        )
    }

    private var expandedPath: String {
        if let discovered = Self.discoverDatabasePath(fileManager: fileManager) {
            return discovered
        }
        return CodexDataSource.expandHome(in: rootPath)
    }

    public static func discoverDatabasePath(fileManager: FileManager = .default) -> String? {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let groupContainers = (homeDir as NSString).appendingPathComponent("Library/Group Containers")

        guard let entries = try? fileManager.contentsOfDirectory(atPath: groupContainers) else {
            return nil
        }

        for entry in entries where entry.hasSuffix(".dev.warp") {
            let candidate = (groupContainers as NSString)
                .appendingPathComponent(entry)
                .appending("/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
            if fileManager.isReadableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
