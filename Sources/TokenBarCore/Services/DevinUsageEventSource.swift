import Foundation

/// Devin transcript source: static JSON files re-read on change (Gemini
/// pattern), with fingerprint-based skip so unchanged transcripts cost
/// nothing on refresh. Re-emitted events are deduplicated downstream by
/// their stable `<sourcePath>#devin#<step_id>` ids.
public struct DevinUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "Devin"
    public let rootPath: String
    public let agent: AgentKind = .devin
    private let rootDirectory: String?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String

    public init(
        rootPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.rootDirectory = rootPath
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.rootPath = rootPath ?? DevinDataSource.resolvedRootDirectory(
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        try await loadEvents(
            since: watermarks,
            referenceDate: referenceDate,
            calendar: calendar,
            resourceThrottle: nil
        )
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar,
        resourceThrottle: IndexingResourceThrottle?
    ) async throws -> UsageSourceLoadResult {
        _ = calendar
        let files = try DevinDataSource.discoverTranscriptFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        )
        let projectIndex = DevinDataSource.loadProjectIndex(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )

        var events: [UsageEvent] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        if let readError = projectIndex.readError {
            warnings.append(
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: rootPath,
                    lineNumber: nil,
                    message: "devin sessions database unreadable, projects fall back to unknown: \(readError)"
                )
            )
        }

        for file in files {
            let sourcePath = file.path
            let priorWatermark = watermarks[sourcePath]

            let fingerprint: FileFingerprint
            do {
                fingerprint = try JSONLIncrementalReader.fingerprint(at: sourcePath)
            } catch {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "failed to fingerprint source file: \(error.localizedDescription)"
                    )
                )
                continue
            }

            if shouldSkipFile(fingerprint: fingerprint, watermark: priorWatermark) {
                nextWatermarks.append(
                    SourceWatermark(
                        sourcePath: sourcePath,
                        agent: .devin,
                        lastMtime: fingerprint.mtime,
                        lastByteOffset: 0,
                        lastEventId: priorWatermark?.lastEventId,
                        lastInode: fingerprint.inode,
                        updatedAt: referenceDate
                    )
                )
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "failed to read source file: \(error.localizedDescription)"
                    )
                )
                continue
            }

            let parseResult = DevinUsageParser.parse(
                data: data,
                fileURL: file,
                projects: projectIndex.index.sessionToPath
            )
            events.append(contentsOf: parseResult.events)
            warnings.append(contentsOf: parseResult.warnings.map { w in
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: w.sourcePath,
                    lineNumber: w.lineNumber == 0 ? nil : w.lineNumber,
                    message: w.message
                )
            })

            nextWatermarks.append(
                SourceWatermark(
                    sourcePath: sourcePath,
                    agent: .devin,
                    lastMtime: fingerprint.mtime,
                    lastByteOffset: 0,
                    lastEventId: parseResult.events.last?.id ?? priorWatermark?.lastEventId,
                    lastInode: fingerprint.inode,
                    updatedAt: referenceDate
                )
            )

            if let resourceThrottle {
                await resourceThrottle.rest(afterActive: JSONLThrottleTunables.activeSliceSeconds)
            }
        }

        return UsageSourceLoadResult(
            events: events,
            prompts: [],
            nextWatermarks: nextWatermarks,
            warnings: warnings
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let root = DevinDataSource.resolvedRootDirectory(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        let discoveredCount = (try? DevinDataSource.discoverTranscriptFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        ).count) ?? 0
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: root),
            discoveredFileCount: discoveredCount
        )
    }

    private func shouldSkipFile(fingerprint: FileFingerprint, watermark: SourceWatermark?) -> Bool {
        guard let watermark else { return false }
        guard fingerprint.mtime <= watermark.lastMtime else { return false }
        guard let lastInode = watermark.lastInode else { return true }
        return fingerprint.inode == lastInode
    }
}
