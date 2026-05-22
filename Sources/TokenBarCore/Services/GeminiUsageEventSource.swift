import Foundation

public struct GeminiUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "Gemini CLI"
    public let rootPath: String
    private let fileManager: FileManager

    public init(rootPath: String = "~/.gemini", fileManager: FileManager = .default) {
        self.rootPath = rootPath
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = calendar
        let files = try GeminiDataSource.discoverChatFiles(
            rootDirectory: rootPath,
            fileManager: fileManager
        )
        let projectIndex = GeminiDataSource.loadProjectIndex(
            rootDirectory: rootPath,
            fileManager: fileManager
        )

        var events: [UsageEvent] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

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
                        agent: .geminiCLI,
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

            let parseResult = GeminiUsageParser.parse(
                data: data,
                fileURL: file
            ) { slug in
                GeminiDataSource.resolveProject(
                    forSlug: slug,
                    rootDirectory: rootPath,
                    projectIndex: projectIndex,
                    fileManager: fileManager
                )
            }
            warnings.append(contentsOf: parseResult.warnings)

            let previousLastEventID = stripCustomPrefix(from: priorWatermark?.lastEventId)
            let newEvents = filterNewEvents(
                parseResult.events,
                previousLastEventID: previousLastEventID
            )
            events.append(contentsOf: newEvents)

            let watermarkLastEventID = newEvents.last
                .flatMap { messageID(fromEventID: $0.id, sourcePath: sourcePath) }
                ?? previousLastEventID

            nextWatermarks.append(
                SourceWatermark(
                    sourcePath: sourcePath,
                    agent: .geminiCLI,
                    lastMtime: fingerprint.mtime,
                    lastByteOffset: 0,
                    lastEventId: watermarkLastEventID,
                    lastInode: fingerprint.inode,
                    updatedAt: referenceDate
                )
            )
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
        let expanded = CodexDataSource.expandHome(in: rootPath)
        let discoveredCount = (try? GeminiDataSource.discoverChatFiles(
            rootDirectory: rootPath,
            fileManager: fileManager
        ).count) ?? 0
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: expanded),
            discoveredFileCount: discoveredCount
        )
    }

    private func shouldSkipFile(fingerprint: FileFingerprint, watermark: SourceWatermark?) -> Bool {
        guard let watermark else { return false }
        guard fingerprint.mtime <= watermark.lastMtime else { return false }
        guard let lastInode = watermark.lastInode else { return true }
        return fingerprint.inode == lastInode
    }

    private func filterNewEvents(
        _ events: [UsageEvent],
        previousLastEventID: String?
    ) -> [UsageEvent] {
        guard let previousLastEventID else { return events }
        guard let lastSeenIndex = events.lastIndex(where: { event in
            messageID(fromEventID: event.id, sourcePath: event.sourcePath) == previousLastEventID
        }) else {
            return events
        }
        let nextIndex = events.index(after: lastSeenIndex)
        guard nextIndex < events.endIndex else {
            return []
        }
        return Array(events[nextIndex...])
    }

    private func messageID(fromEventID eventID: String, sourcePath: String) -> String? {
        let prefix = sourcePath + "#"
        guard eventID.hasPrefix(prefix) else { return nil }
        return String(eventID.dropFirst(prefix.count))
    }

    private func stripCustomPrefix(from value: String?) -> String? {
        guard let value else { return nil }
        guard value.hasPrefix("custom:") else {
            return value
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "custom" else {
            return value
        }
        return parts.dropFirst(2).joined(separator: ":")
    }
}
