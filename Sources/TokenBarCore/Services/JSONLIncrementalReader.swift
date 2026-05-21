import Darwin
import Foundation

public struct FileFingerprint: Sendable, Hashable {
    public let inode: UInt64
    public let size: Int64
    public let mtime: Date

    public init(inode: UInt64, size: Int64, mtime: Date) {
        self.inode = inode
        self.size = size
        self.mtime = mtime
    }
}

public enum ReadStrategy: Sendable, Hashable {
    case incremental(fromByteOffset: Int64)
    case fullReparse(reason: String)
}

public struct JSONLLineRecord: Sendable, Hashable {
    public let text: String
    public let lineNumber: Int
    public let startOffset: Int64
    public let endOffset: Int64
}

public struct JSONLIncrementalReadResult: Sendable, Hashable {
    public let lines: [JSONLLineRecord]
    public let nextWatermark: SourceWatermark
    public let forcedFullReparseReason: String?
    public let warnings: [UsageSourceWarning]
}

public enum JSONLIncrementalReader {
    public static func fingerprint(at path: String) throws -> FileFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date) ?? .distantPast
        return FileFingerprint(
            inode: inode,
            size: size,
            mtime: mtime
        )
    }

    public static func decide(current: FileFingerprint, watermark: SourceWatermark?) -> ReadStrategy {
        guard let watermark else {
            return .fullReparse(reason: "no watermark")
        }
        guard let lastInode = watermark.lastInode else {
            return .fullReparse(reason: "unknown previous inode")
        }
        if current.inode != lastInode {
            return .fullReparse(reason: "inode changed \(lastInode) -> \(current.inode)")
        }
        if current.size < watermark.lastByteOffset {
            return .fullReparse(reason: "size shrink \(watermark.lastByteOffset) -> \(current.size)")
        }
        if current.mtime < watermark.lastMtime {
            return .fullReparse(reason: "mtime regress")
        }
        return .incremental(fromByteOffset: watermark.lastByteOffset)
    }

    public static func read(
        fileURL: URL,
        sourceName: String,
        agent: AgentKind,
        watermark: SourceWatermark?,
        now: Date = Date()
    ) throws -> JSONLIncrementalReadResult {
        let path = fileURL.path
        let current = try fingerprint(at: path)
        let strategy = decide(current: current, watermark: watermark)
        let startOffset: Int64
        let reason: String?
        switch strategy {
        case .incremental(let offset):
            startOffset = offset
            reason = nil
        case .fullReparse(let message):
            startOffset = 0
            reason = message
        }

        let data = try Data(contentsOf: fileURL)
        let safeStart = max(0, min(Int(startOffset), data.count))
        let prefixLineCount = safeStart == 0 ? 0 : data[..<safeStart].reduce(0) { count, byte in
            byte == 10 ? count + 1 : count
        }

        var lines: [JSONLLineRecord] = []
        var warnings: [UsageSourceWarning] = []
        var cursor = safeStart
        var currentLineNumber = prefixLineCount + 1
        var cleanOffset = Int64(safeStart)

        while cursor < data.count {
            let lineStart = cursor
            while cursor < data.count, data[cursor] != 10 {
                cursor += 1
            }

            guard cursor < data.count else {
                cleanOffset = Int64(lineStart)
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: path,
                        lineNumber: currentLineNumber,
                        message: "partial trailing JSONL line; watermark rewound to byte \(lineStart)"
                    )
                )
                break
            }

            let lineEnd = cursor
            cursor += 1
            cleanOffset = Int64(cursor)

            let rawLine = data[lineStart..<lineEnd]
            guard !rawLine.isEmpty else {
                currentLineNumber += 1
                continue
            }
            guard let text = String(data: rawLine, encoding: .utf8) else {
                cleanOffset = Int64(lineStart)
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: path,
                        lineNumber: currentLineNumber,
                        message: "invalid UTF-8 JSONL line; watermark rewound to byte \(lineStart)"
                    )
                )
                break
            }

            lines.append(
                JSONLLineRecord(
                    text: text,
                    lineNumber: currentLineNumber,
                    startOffset: Int64(lineStart),
                    endOffset: Int64(cursor)
                )
            )
            currentLineNumber += 1
        }

        if let reason {
            warnings.append(
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: path,
                    lineNumber: nil,
                    message: "forced full reparse: \(reason)"
                )
            )
        }

        let nextWatermark = SourceWatermark(
            sourcePath: path,
            agent: agent,
            lastMtime: current.mtime,
            lastByteOffset: cleanOffset,
            lastEventId: nil,
            lastInode: current.inode,
            updatedAt: now
        )

        return JSONLIncrementalReadResult(
            lines: lines,
            nextWatermark: nextWatermark,
            forcedFullReparseReason: reason,
            warnings: warnings
        )
    }
}
