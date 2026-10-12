import Foundation
import Testing
@testable import TokenBarCore

/// End-to-end DSH source tests: discovery over a staged sessions tree,
/// zstd decompression, parsing, fingerprint skipping, and watermark carry.
struct DshUsageEventSourceTests {
    private static let sessionID = "session-abc12345-0000-0000-0000-000000000000"

    /// Stages the multi-frame compressed fixture as
    /// <root>/sessions/<slug>/<session-id>/session.v4.jsonl.zstd
    /// (the exact layout DSH writes) and returns the root.
    private func stagedSessionsRoot() throws -> URL {
        guard let url = fixtureBundle.url(
            forResource: "dsh-v4",
            withExtension: "jsonl.zstd",
            subdirectory: "dsh"
        ) ?? fixtureBundle.url(forResource: "dsh-v4", withExtension: "jsonl.zstd") else {
            throw DshSourceFixtureError.missing
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-src-" + UUID().uuidString, isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("--Users-travis-proj-observ--", isDirectory: true)
            .appendingPathComponent(Self.sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: sessionDir.appendingPathComponent("session.v4.jsonl.zstd"))
        return root
    }

    @Test
    func discoversDecompressesAndParses() async throws {
        let root = try stagedSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = DshUsageEventSource(rootPath: root.path)
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let result = try await source.loadEvents(referenceDate: reference, calendar: Calendar(identifier: .gregorian))

        #expect(result.events.count == 2)
        #expect(result.prompts.count == 1)
        #expect(result.events[0].inputTokens == 12588)
        #expect(result.events[1].cacheReadTokens == 22016)
        #expect(result.events[0].projectPath == "/Users/travis/proj/observ")
        #expect(result.nextWatermarks.count == 1)
        // No reparse happened, so the mid-frame warning stays silent.
        #expect(result.warnings.isEmpty)
    }

    @Test
    func fingerprintUnchangedSkipsWork() async throws {
        let root = try stagedSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = DshUsageEventSource(rootPath: root.path)
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try await source.loadEvents(referenceDate: reference, calendar: Calendar(identifier: .gregorian))
        #expect(first.events.count == 2)

        let watermarks = Dictionary(uniqueKeysWithValues: first.nextWatermarks.map { ($0.sourcePath, $0) })
        let second = try await source.loadEvents(since: watermarks, referenceDate: reference, calendar: Calendar(identifier: .gregorian))
        // Unchanged fingerprint: nothing re-parsed, watermark carried.
        #expect(second.events.isEmpty)
        #expect(second.nextWatermarks.count == 1)
        #expect(second.nextWatermarks[0].lastEventId == first.nextWatermarks[0].lastEventId)
    }

    @Test
    func grownFileReparsesIdempotently() async throws {
        let root = try stagedSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = DshUsageEventSource(rootPath: root.path)
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try await source.loadEvents(referenceDate: reference, calendar: Calendar(identifier: .gregorian))

        // Simulate DSH appending another frame: touch mtime + size.
        guard let url = fixtureBundle.url(forResource: "dsh-legacy", withExtension: "jsonl.zstd", subdirectory: "dsh")
            ?? fixtureBundle.url(forResource: "dsh-legacy", withExtension: "jsonl.zstd") else {
            throw DshSourceFixtureError.missing
        }
        let target = root.appendingPathComponent("sessions")
            .appendingPathComponent("--Users-travis-proj-observ--")
            .appendingPathComponent(Self.sessionID)
            .appendingPathComponent("session.v4.jsonl.zstd")
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(try Data(contentsOf: url)))

        let watermarks = Dictionary(uniqueKeysWithValues: first.nextWatermarks.map { ($0.sourcePath, $0) })
        let second = try await source.loadEvents(since: watermarks, referenceDate: reference, calendar: Calendar(identifier: .gregorian))
        // Full re-read emits both files' worth of events; downstream dedup
        // is by primary key (INSERT OR IGNORE), asserted via ids: the set of
        // ids from the first pass is a subset of the second pass.
        let firstIDs = Set(first.events.map { $0.id })
        let secondIDs = Set(second.events.map { $0.id })
        #expect(firstIDs.isSubset(of: secondIDs))
        #expect(secondIDs.count == 3)
    }

    @Test
    func statusReportsRootAndFiles() async throws {
        let root = try stagedSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = DshUsageEventSource(rootPath: root.path)
        let status = await source.status(referenceDate: Date(), calendar: Calendar(identifier: .gregorian))
        #expect(status.sourceName == "DeepSeek Harness")
        #expect(status.discoveredFileCount == 1)
        #expect(status.isReadable)
    }
}

enum DshSourceFixtureError: Error {
    case missing
}
