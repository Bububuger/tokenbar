import Foundation

/// DeepSeek Harness (DSH) usage source.
///
/// DSH session files are zstd-compressed JSONL with one small frame appended
/// per event batch, so the shared byte-offset incremental reader cannot be
/// used. Instead this source uses the same fingerprint triple
/// (inode, size, mtime) as a change detector:
///
/// - fingerprint unchanged -> carry the watermark, emit nothing
/// - fingerprint changed   -> decompress the whole file and re-parse it
///
/// Re-parsing is idempotent: event ids are
/// "<path>#dsh#<session-id>#<seq>" and the repository INSERT OR IGNOREs on
/// that primary key, so a full re-read after growth never double-counts.
public struct DshUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "DeepSeek Harness"
    public let rootPath: String
    public let agent: AgentKind = .dsh
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
        self.rootPath = rootPath ?? DshDataSource.resolvedRootDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        ).joined(separator: ", ")
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
        let files = try DshDataSource.discoverSessionFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        )

        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for file in files {
            let path = file.path
            let current: FileFingerprint
            do {
                current = try JSONLIncrementalReader.fingerprint(at: path)
            } catch {
                continue
            }

            if let watermark = watermarks[path],
               watermark.lastInode == current.inode,
               watermark.lastByteOffset == current.size,
               watermark.lastMtime == current.mtime {
                // Unchanged since the last pass: carry dedup state forward.
                nextWatermarks.append(
                    SourceWatermark(
                        sourcePath: path,
                        agent: agent,
                        lastMtime: current.mtime,
                        lastByteOffset: current.size,
                        lastEventId: watermark.lastEventId,
                        lastInode: current.inode,
                        updatedAt: referenceDate
                    )
                )
                continue
            }

            do {
                let compressed = try Data(contentsOf: file)
                let (decompressed, truncated) = try ZstdStream.decompressStreaming(compressed)
                let lines = Self.splitLines(decompressed, sourcePath: path)
                if truncated {
                    // Live-session tail frame: a later pass re-reads the file
                    // once it grows (size is part of the fingerprint).
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: sourceName,
                            sourcePath: path,
                            lineNumber: nil,
                            message: "dsh session stream ends mid-frame; partial trailing jsonl line ignored"
                        )
                    )
                }
                let result = DshUsageParser.parse(lines: lines, fileURL: file)
                events.append(contentsOf: result.events)
                prompts.append(contentsOf: result.prompts)
                warnings.append(contentsOf: result.warnings.map { w in
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: w.sourcePath,
                        lineNumber: w.lineNumber,
                        message: w.message
                    )
                })
                nextWatermarks.append(
                    SourceWatermark(
                        sourcePath: path,
                        agent: agent,
                        lastMtime: current.mtime,
                        lastByteOffset: current.size,
                        lastEventId: result.events.last?.id ?? watermarks[path]?.lastEventId,
                        lastInode: current.inode,
                        updatedAt: referenceDate
                    )
                )
            } catch {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: path,
                        lineNumber: nil,
                        message: "dsh session decompression failed: " + String(describing: error)
                    )
                )
                continue
            }

            if let resourceThrottle {
                await resourceThrottle.rest(afterActive: 0.002)
            }
        }

        return UsageSourceLoadResult(
            events: events,
            prompts: prompts,
            nextWatermarks: nextWatermarks,
            warnings: warnings
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let roots = DshDataSource.resolvedRootDirectories(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        let discoveredCount = (try? DshDataSource.discoverSessionFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        ).count) ?? 0
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: roots.contains { fileManager.isReadableFile(atPath: $0) },
            discoveredFileCount: discoveredCount
        )
    }

    /// Splits decompressed JSONL bytes into line records. Offsets refer to
    /// the decompressed stream (used only for diagnostics); the watermark's
    /// byte offset stays on the compressed file, which is what the
    /// fingerprint guards.
    static func splitLines(_ data: Data, sourcePath: String) -> [JSONLLineRecord] {
        var lines: [JSONLLineRecord] = []
        var lineNumber = 0
        var cursor = 0
        let byteCount = data.count

        while cursor < byteCount {
            let lineStart = cursor
            while cursor < byteCount, data[data.startIndex + cursor] != 10 {
                cursor += 1
            }
            let lineEnd = cursor
            if cursor < byteCount {
                cursor += 1 // consume newline
            }
            lineNumber += 1

            let rawLine = data[data.startIndex + lineStart..<data.startIndex + lineEnd]
            guard !rawLine.isEmpty,
                  let text = String(data: rawLine, encoding: .utf8) else {
                if cursor >= byteCount {
                    // Partial trailing line without a newline: skip; the
                    // fingerprint re-reads the file once it grows.
                    break
                }
                continue
            }
            lines.append(
                JSONLLineRecord(
                    text: text,
                    lineNumber: lineNumber,
                    startOffset: Int64(lineStart),
                    endOffset: Int64(cursor)
                )
            )
        }
        return lines
    }
}
