import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import TokenBarCore

@Suite(.serialized)
struct CursorDashboardUsageTests {
    @Test
    func decodesFourExclusiveBucketsAndModelListCost() throws {
        let event = try JSONDecoder().decode(
            CursorDashboardUsageEvent.self,
            from: Data("""
            {
              "timestamp": "1775418973898",
              "model": "model-a",
              "conversationId": "conversation-a",
              "tokenUsage": {
                "inputTokens": 3,
                "outputTokens": 20,
                "cacheReadTokens": 100,
                "totalCents": 121.41
              }
            }
            """.utf8)
        )
        #expect(event.conversationID == "conversation-a")
        #expect(event.tokenUsage?.inputTokens == 3)
        #expect(event.tokenUsage?.outputTokens == 20)
        #expect(event.tokenUsage?.cacheReadTokens == 100)
        #expect(event.tokenUsage?.cacheWriteTokens == 0)
        #expect(event.tokenUsage?.totalCents == 121.41)
    }

    @Test
    func rejectsTokenUsageObjectWithoutAnyTokenFields() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                CursorDashboardUsageEvent.self,
                from: Data("""
                {
                  "timestamp": "1775418973898",
                  "tokenUsage": {"totalCents": 1.0}
                }
                """.utf8)
            )
        }
    }

    @Test
    func fetchesThroughFinalEmptyPageAndKeepsRealDuplicates() async throws {
        let pass = [
            response(total: 2, events: [eventJSON(timestamp: "1000", conversation: "same")]),
            response(total: 2, events: [eventJSON(timestamp: "1000", conversation: "same")]),
            response(total: 2, events: []),
        ]
        let recorder = RequestRecorder(responses: pass + pass)
        let client = makeClient(recorder: recorder)
        let result = try await client.fetchAll(cookie: "session=redacted", pageSize: 1)

        #expect(result.events.count == 2)
        #expect(recorder.requestCount == 6)
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Origin") == "https://cursor.com"
        })
    }

    @Test
    func removesOnlyCountProvenAdjacentPageOverlap() async throws {
        let a = eventJSON(timestamp: "1000", conversation: "a")
        let b = eventJSON(timestamp: "2000", conversation: "b")
        let c = eventJSON(timestamp: "3000", conversation: "c")
        let pass = [
            response(total: 3, events: [a, b]),
            response(total: 3, events: [b, c]),
            response(total: 3, events: []),
        ]
        let recorder = RequestRecorder(responses: pass + pass)
        let result = try await makeClient(recorder: recorder)
            .fetchAll(cookie: "session=redacted", pageSize: 2)

        #expect(result.events.map(\.conversationID) == ["a", "b", "c"])
    }

    @Test
    func rejectsSnapshotThatChangesBetweenPaginationPasses() async {
        let a = eventJSON(timestamp: "1000", conversation: "a")
        let b = eventJSON(timestamp: "2000", conversation: "b")
        let c = eventJSON(timestamp: "3000", conversation: "c")
        let recorder = RequestRecorder(responses: [
            response(total: 3, events: [a, b]),
            response(total: 3, events: [b]),
            response(total: 3, events: [a, b]),
            response(total: 3, events: [c]),
        ])

        do {
            _ = try await makeClient(recorder: recorder)
                .fetchAll(cookie: "session=redacted", pageSize: 2)
            Issue.record("Expected unstable pagination to fail")
        } catch let error as CursorDashboardUsageError {
            #expect(error == .unstableSnapshot)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsShortIncompletePage() async {
        let recorder = RequestRecorder(responses: [
            response(total: 3, events: [eventJSON(timestamp: "1000", conversation: "a")]),
        ])
        do {
            _ = try await makeClient(recorder: recorder)
                .fetchAll(cookie: "session=redacted", pageSize: 2)
            Issue.record("Expected incomplete pagination to fail")
        } catch let error as CursorDashboardUsageError {
            #expect(error == .incompletePagination)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func localStateProducesOnlyDirectHumanPromptAndInheritedContext() throws {
        let databaseURL = temporaryDirectory().appendingPathComponent("state.vscdb")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE cursorDiskKV (key TEXT UNIQUE, value BLOB)")
            try insertJSON(
                db,
                key: "composerData:parent",
                json: """
                {"workspaceIdentifier":{"configPath":{"fsPath":"/tmp/team.code-workspace"}},
                 "subagentComposerIds":["child"]}
                """
            )
            try insertJSON(
                db,
                key: "composerData:child",
                json: """
                {"workspaceIdentifier":{"uri":{"fsPath":"/tmp/generated-worktree"}},
                 "subagentInfo":{"parentComposerId":"parent"}}
                """
            )
            try insertJSON(db, key: "bubbleId:parent:human", json: """
                {"type":1,"text":"keep this prompt","createdAt":1000,
                 "tokenCount":{"inputTokens":999,"outputTokens":999}}
                """)
            try insertJSON(db, key: "bubbleId:parent:simulated", json: """
                {"type":1,"text":"drop simulated","createdAt":1001,"isSimulatedMsg":true}
                """)
            try insertJSON(db, key: "bubbleId:child:generated", json: """
                {"type":1,"text":"drop subagent","createdAt":1002}
                """)
            try insertJSON(db, key: "bubbleId:parent:assistant", json: """
                {"type":2,"text":"drop assistant","createdAt":1003,
                 "tokenUsage":{"inputTokens":123,"outputTokens":456}}
                """)
        }

        let snapshot = try CursorUsageParser.parseLocalSnapshot(databaseURL: databaseURL)
        #expect(snapshot.loadResult.events.isEmpty)
        #expect(snapshot.loadResult.prompts.map(\.content) == ["keep this prompt"])
        let parent = snapshot.conversationContexts.first { $0.conversationID == "parent" }
        let child = snapshot.conversationContexts.first { $0.conversationID == "child" }
        #expect(parent?.projectPath == "/tmp/team.code-workspace")
        #expect(child?.projectPath == parent?.projectPath)
        #expect(parent?.projectName == "team")
    }

    @Test
    func disambiguatesSameBasenameUsingShortestStableParentSuffix() throws {
        let databaseURL = temporaryDirectory().appendingPathComponent("same-name-state.vscdb")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE cursorDiskKV (key TEXT UNIQUE, value BLOB)")
            try insertJSON(db, key: "composerData:left", json: """
                {"workspaceIdentifier":{"uri":{"fsPath":"/tmp/organization-a/shared"}}}
                """)
            try insertJSON(db, key: "composerData:right", json: """
                {"workspaceIdentifier":{"uri":{"fsPath":"/tmp/organization-b/shared"}}}
                """)
        }

        let contexts = try CursorUsageParser.parseLocalSnapshot(databaseURL: databaseURL)
            .conversationContexts
        let left = contexts.first { $0.conversationID == "left" }
        let right = contexts.first { $0.conversationID == "right" }
        #expect(left?.projectPath != right?.projectPath)
        #expect(left?.projectName == "organization-a/shared")
        #expect(right?.projectName == "organization-b/shared")
    }

    @Test
    func remoteSyncStillPublishesUnattributedUsageWithoutLocalCursorState() async throws {
        let directory = temporaryDirectory()
        let repository = try UsageRepository(
            databaseURL: directory.appendingPathComponent("tokenbar.sqlite")
        )
        let page = response(
            total: 1,
            events: [eventJSON(timestamp: "1000", conversation: "remote-only")]
        )
        let recorder = RequestRecorder(responses: [page, page])
        let service = CursorDashboardUsageSyncService(
            repository: repository,
            client: makeClient(recorder: recorder),
            localDatabaseURL: directory.appendingPathComponent("missing-state.vscdb")
        )

        let result = try await service.sync(cookie: "session=redacted")
        let events = try repository.allEvents()

        #expect(result.tokenEvents == 1)
        #expect(result.attributedEvents == 0)
        #expect(events.count == 1)
        #expect(events[0].projectPath == nil)
        #expect(events[0].projectName == "Cursor · 未归属")
        #expect(events[0].actualCostUSD == 0.05)
    }

    @Test
    func inMemoryAggregationUsesOnlyKnownCursorActualCost() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let events = [
            usageEvent(id: "known-cost", timestamp: timestamp, actualCostUSD: 0.05),
            usageEvent(id: "missing-cost", timestamp: timestamp, actualCostUSD: nil),
        ]

        let snapshot = UsageAggregator.makeSnapshot(
            from: events,
            referenceDate: Date(timeIntervalSince1970: 2_000),
            calendar: calendar
        )

        #expect(snapshot.estimatedCostToday.totalCost == 0.05)
        #expect(snapshot.estimatedCostLast30.totalCost == 0.05)
    }

    @Test
    func rangeAggregationKeepsKnownCursorCostWhenCoverageIsPartial() throws {
        let repository = try UsageRepository(
            databaseURL: temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
        )
        let timestamp = Date(timeIntervalSince1970: 1_000)
        _ = try repository.replaceCursorRemoteSnapshot(
            events: [
                usageEvent(id: "known-cost", timestamp: timestamp, actualCostUSD: 0.05),
                usageEvent(id: "missing-cost", timestamp: timestamp, actualCostUSD: nil),
            ],
            coverageStart: timestamp,
            coverageEnd: timestamp.addingTimeInterval(1),
            totalEvents: 2,
            tokenEvents: 2,
            attributedEvents: 2,
            costEvents: 1
        )

        let aggregate = try repository.rangeAggregate(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 2_000),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(aggregate.rows.count == 1)
        #expect(aggregate.rows[0].actualCostUSD == 0.05)
    }

    @Test
    func failedAtomicReplacementPreservesPreviousSnapshot() throws {
        let databaseURL = temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
        let repository = try UsageRepository(databaseURL: databaseURL)
        let old = usageEvent(id: "old", timestamp: Date(timeIntervalSince1970: 1))
        _ = try repository.replaceCursorRemoteSnapshot(
            events: [old],
            coverageStart: nil,
            coverageEnd: Date(timeIntervalSince1970: 10),
            totalEvents: 1,
            tokenEvents: 1,
            attributedEvents: 1,
            costEvents: 1
        )

        let duplicateA = usageEvent(id: "duplicate", timestamp: Date(timeIntervalSince1970: 2))
        let duplicateB = usageEvent(id: "duplicate", timestamp: Date(timeIntervalSince1970: 3))
        #expect(throws: CursorSnapshotError.duplicateEventIdentifier) {
            _ = try repository.replaceCursorRemoteSnapshot(
                events: [duplicateA, duplicateB],
                coverageStart: nil,
                coverageEnd: Date(timeIntervalSince1970: 10),
                totalEvents: 2,
                tokenEvents: 2,
                attributedEvents: 2,
                costEvents: 2
            )
        }
        #expect(try repository.allEvents().map(\.id) == ["old"])
    }

    @Test
    func cancellationAtCommitBoundaryRollsBackReplacement() throws {
        let databaseURL = temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
        let repository = try UsageRepository(databaseURL: databaseURL)
        let old = usageEvent(id: "old", timestamp: Date(timeIntervalSince1970: 1))
        _ = try repository.replaceCursorRemoteSnapshot(
            events: [old],
            coverageStart: nil,
            coverageEnd: Date(timeIntervalSince1970: 10),
            totalEvents: 1,
            tokenEvents: 1,
            attributedEvents: 1,
            costEvents: 1
        )

        let readyToCommit = DispatchSemaphore(value: 0)
        let allowCommitCheck = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = CursorCommitAttemptResult()
        let gate = CursorSnapshotCommitGate {
            readyToCommit.signal()
            _ = allowCommitCheck.wait(timeout: .now() + 5)
        }
        let replacement = usageEvent(id: "replacement", timestamp: Date(timeIntervalSince1970: 2))

        DispatchQueue.global().async {
            do {
                _ = try repository.replaceCursorRemoteSnapshot(
                    events: [replacement],
                    coverageStart: nil,
                    coverageEnd: Date(timeIntervalSince1970: 20),
                    totalEvents: 1,
                    tokenEvents: 1,
                    attributedEvents: 1,
                    costEvents: 1,
                    commitGate: gate
                )
                result.recordSuccess()
            } catch {
                result.record(error: error)
            }
            finished.signal()
        }

        #expect(readyToCommit.wait(timeout: .now() + 5) == .success)
        gate.cancel()
        allowCommitCheck.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(result.wasCancelled)
        #expect(try repository.allEvents().map(\.id) == ["old"])
        let metadata = try repository.cursorRemoteSnapshotMetadata()
        #expect(metadata?.coverageEnd == Date(timeIntervalSince1970: 10))
        #expect(metadata?.lastWindowTotalEvents == 1)
    }

    @Test
    func localReparsePreservesRemoteSnapshotWhileFullResetRemovesIt() throws {
        let databaseURL = temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
        let repository = try UsageRepository(databaseURL: databaseURL)
        let remote = usageEvent(id: "remote", timestamp: Date(timeIntervalSince1970: 1))
        _ = try repository.replaceCursorRemoteSnapshot(
            events: [remote],
            coverageStart: nil,
            coverageEnd: Date(timeIntervalSince1970: 10),
            totalEvents: 1,
            tokenEvents: 1,
            attributedEvents: 1,
            costEvents: 1
        )

        try repository.resetIndexForFullReparse()
        #expect(try repository.allEvents().map(\.id) == ["remote"])
        #expect(try repository.cursorRemoteSnapshotMetadata() != nil)

        try repository.resetAllData()
        #expect(try repository.allEvents().isEmpty)
        #expect(try repository.cursorRemoteSnapshotMetadata() == nil)
    }

    @Test
    func cancelledGateDoesNotWriteFailureMetadata() throws {
        let repository = try UsageRepository(
            databaseURL: temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
        )
        let gate = CursorSnapshotCommitGate()
        gate.cancel()

        #expect(throws: CancellationError.self) {
            try repository.recordCursorRemoteSnapshotFailure(
                errorCode: "cursor_sync_failed",
                commitGate: gate
            )
        }
        #expect(try repository.cursorRemoteSnapshotMetadata() == nil)
    }

    private func makeClient(recorder: RequestRecorder) -> CursorDashboardUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorDashboardURLProtocol.self]
        CursorDashboardURLProtocol.handler = recorder.handle
        return CursorDashboardUsageClient(
            endpoint: URL(string: "https://cursor.test/api")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func response(total: Int, events: [String]) -> Data {
        Data("""
        {"totalUsageEventsCount":\(total),"usageEventsDisplay":[\(events.joined(separator: ","))]}
        """.utf8)
    }

    private func eventJSON(timestamp: String, conversation: String) -> String {
        """
        {"timestamp":"\(timestamp)","model":"model-a","conversationId":"\(conversation)",
         "tokenUsage":{"inputTokens":1,"outputTokens":2,"cacheReadTokens":3,
                       "cacheWriteTokens":4,"totalCents":5}}
        """
    }

    private func usageEvent(
        id: String,
        timestamp: Date,
        actualCostUSD: Double? = 0.05
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            agent: .cursor,
            projectPath: "/tmp/project",
            projectName: "project",
            sessionId: "conversation",
            timestamp: timestamp,
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheCreationTokens: 4,
            reasoningTokens: nil,
            actualCostUSD: actualCostUSD,
            sourcePath: UsageRepository.cursorRemoteSourcePath,
            parser: .cursor,
            confidence: 1
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-cursor-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func insertJSON(_ db: Database, key: String, json: String) throws {
        try db.execute(
            sql: "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)",
            arguments: [key, Data(json.utf8)]
        )
    }
}

private final class CursorCommitAttemptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled && !succeeded }
    }

    func recordSuccess() {
        lock.withLock {
            succeeded = true
        }
    }

    func record(error: Error) {
        lock.withLock {
            cancelled = error is CancellationError
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else {
                throw CursorDashboardUsageError.incompletePagination
            }
            let data = responses.removeFirst()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
    }
}

private final class CursorDashboardURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw CursorDashboardUsageError.invalidResponse
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
