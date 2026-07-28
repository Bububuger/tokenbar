import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CursorDashboardUsageError: Error, Sendable, Equatable {
    case invalidCookie
    case httpStatus(Int)
    case invalidResponse
    case invalidSchema
    case inconsistentTotalCount
    case incompletePagination
    case ambiguousBoundaryOverlap
    case unstableSnapshot
    case pageLimitExceeded

    public var safeCode: String {
        switch self {
        case .invalidCookie: "invalid_cookie"
        case .httpStatus(let status): "http_\(status)"
        case .invalidResponse: "invalid_response"
        case .invalidSchema: "invalid_schema"
        case .inconsistentTotalCount: "inconsistent_total_count"
        case .incompletePagination: "incomplete_pagination"
        case .ambiguousBoundaryOverlap: "ambiguous_boundary_overlap"
        case .unstableSnapshot: "unstable_snapshot"
        case .pageLimitExceeded: "page_limit_exceeded"
        }
    }
}

public final class CursorDashboardUsageClient: @unchecked Sendable {
    private struct RequestBody: Encodable {
        let page: Int
        let pageSize: Int
        let startDate: String?
        let endDate: String?
    }

    private struct ResponseBody: Decodable {
        let totalUsageEventsCount: Int?
        let usageEventsDisplay: [CursorDashboardUsageEvent]?
    }

    private let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func fetchAll(
        cookie: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        pageSize: Int = 100,
        maxPages: Int = 1_000
    ) async throws -> CursorDashboardUsagePage {
        let first = try await fetchAllOnce(
            cookie: cookie,
            startDate: startDate,
            endDate: endDate,
            pageSize: pageSize,
            maxPages: maxPages
        )
        let second = try await fetchAllOnce(
            cookie: cookie,
            startDate: startDate,
            endDate: endDate,
            pageSize: pageSize,
            maxPages: maxPages
        )
        guard first == second else {
            throw CursorDashboardUsageError.unstableSnapshot
        }
        return second
    }

    private func fetchAllOnce(
        cookie: String,
        startDate: Date?,
        endDate: Date?,
        pageSize: Int,
        maxPages: Int
    ) async throws -> CursorDashboardUsagePage {
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty,
              !trimmedCookie.contains("\n"),
              !trimmedCookie.contains("\r") else {
            throw CursorDashboardUsageError.invalidCookie
        }
        guard pageSize > 0, maxPages > 0 else {
            throw CursorDashboardUsageError.invalidSchema
        }

        var pages: [[CursorDashboardUsageEvent]] = []
        var authoritativeCount: Int?

        for pageNumber in 1...maxPages {
            let page = try await fetchPage(
                cookie: trimmedCookie,
                startDate: startDate,
                endDate: endDate,
                page: pageNumber,
                pageSize: pageSize
            )
            if let prior = authoritativeCount, prior != page.totalCount {
                throw CursorDashboardUsageError.inconsistentTotalCount
            }
            authoritativeCount = page.totalCount
            pages.append(page.events)

            // A short (including empty) page is the only authoritative end
            // marker. Reaching `totalCount` on a full page still requires one
            // final request, otherwise a truncated response could be accepted.
            if page.events.count < pageSize {
                return try Self.validateAndFlatten(pages: pages, totalCount: page.totalCount)
            }
            if pageNumber == maxPages {
                throw CursorDashboardUsageError.pageLimitExceeded
            }
        }
        throw CursorDashboardUsageError.pageLimitExceeded
    }

    private func fetchPage(
        cookie: String,
        startDate: Date?,
        endDate: Date?,
        page: Int,
        pageSize: Int
    ) async throws -> CursorDashboardUsagePage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        let cookieHeader = cookie.contains("=")
            ? cookie
            : "WorkosCursorSessionToken=\(cookie)"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                page: page,
                pageSize: pageSize,
                startDate: startDate.map { String($0.tokenBarMillisecondsSince1970) },
                endDate: endDate.map { String($0.tokenBarMillisecondsSince1970) }
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorDashboardUsageError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw CursorDashboardUsageError.httpStatus(http.statusCode)
        }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw CursorDashboardUsageError.invalidSchema
        }
        guard let totalCount = decoded.totalUsageEventsCount,
              totalCount >= 0,
              let events = decoded.usageEventsDisplay else {
            throw CursorDashboardUsageError.invalidSchema
        }
        return CursorDashboardUsagePage(totalCount: totalCount, events: events)
    }

    private static func validateAndFlatten(
        pages: [[CursorDashboardUsageEvent]],
        totalCount: Int
    ) throws -> CursorDashboardUsagePage {
        let rawCount = pages.reduce(0) { $0 + $1.count }
        guard rawCount >= totalCount else {
            throw CursorDashboardUsageError.incompletePagination
        }
        if rawCount == totalCount {
            return CursorDashboardUsagePage(totalCount: totalCount, events: pages.flatMap { $0 })
        }

        var remainingOverlap = rawCount - totalCount
        var output = pages.first ?? []
        for index in pages.indices.dropFirst() {
            let current = pages[index]
            let maximum = min(output.count, current.count)
            var overlap = 0
            if maximum > 0 {
                for candidate in stride(from: maximum, through: 1, by: -1)
                where Array(output.suffix(candidate)) == Array(current.prefix(candidate)) {
                    overlap = candidate
                    break
                }
            }
            let removal = min(overlap, remainingOverlap)
            remainingOverlap -= removal
            output.append(contentsOf: current.dropFirst(removal))
        }
        guard remainingOverlap == 0, output.count == totalCount else {
            throw CursorDashboardUsageError.ambiguousBoundaryOverlap
        }
        return CursorDashboardUsagePage(totalCount: totalCount, events: output)
    }
}

public struct CursorDashboardUsageSyncService: Sendable {
    private let repository: UsageRepository
    private let client: CursorDashboardUsageClient
    private let localDatabaseURL: URL

    public init(
        repository: UsageRepository,
        client: CursorDashboardUsageClient = CursorDashboardUsageClient(),
        localDatabaseURL: URL = CursorDataSource.globalStateURL()
    ) {
        self.repository = repository
        self.client = client
        self.localDatabaseURL = localDatabaseURL
    }

    public func sync(
        cookie: String,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> CursorDashboardSyncResult {
        do {
            let page = try await client.fetchAll(
                cookie: cookie,
                startDate: startDate,
                endDate: endDate
            )
            guard page.events.allSatisfy({ event in
                (startDate.map { event.timestamp >= $0 } ?? true)
                    && (endDate.map { event.timestamp < $0 } ?? true)
            }) else {
                throw CursorDashboardUsageError.invalidSchema
            }
            // Remote account usage remains useful when Cursor is not installed
            // on this Mac, or when its private local schema changes. In that
            // case attribution is unavailable, but exact remote token and cost
            // rows must still be published under the explicit unassigned
            // bucket.
            let local = try? CursorUsageParser.parseLocalSnapshot(databaseURL: localDatabaseURL)
            let contexts = Dictionary(
                uniqueKeysWithValues: (local?.conversationContexts ?? []).map { ($0.conversationID, $0) }
            )
            let runID = UUID().uuidString
            var tokenEvents = 0
            var attributedEvents = 0
            var costEvents = 0
            var events: [UsageEvent] = []
            events.reserveCapacity(page.events.count)

            for (ordinal, remote) in page.events.enumerated() {
                guard let usage = remote.tokenUsage else { continue }
                tokenEvents += 1
                let context = remote.conversationID.flatMap { contexts[$0] }
                if context != nil { attributedEvents += 1 }
                if usage.totalCents != nil { costEvents += 1 }
                events.append(
                    UsageEvent(
                        id: "\(UsageRepository.cursorRemoteSourcePath)#\(runID)#\(ordinal)",
                        agent: .cursor,
                        projectPath: context?.projectPath,
                        projectName: context?.projectName ?? "Cursor · 未归属",
                        sessionId: remote.conversationID ?? "cursor-remote-\(ordinal)",
                        timestamp: remote.timestamp,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheReadTokens: usage.cacheReadTokens,
                        cacheCreationTokens: usage.cacheWriteTokens,
                        reasoningTokens: nil,
                        modelName: remote.model,
                        actualCostUSD: usage.totalCents.map { $0 / 100 },
                        sourcePath: UsageRepository.cursorRemoteSourcePath,
                        parser: .cursor,
                        confidence: context == nil ? 0.8 : 1
                    )
                )
            }

            let effectiveCoverageStart = startDate ?? page.events.map(\.timestamp).min()
            let effectiveCoverageEnd = endDate ?? page.events.map(\.timestamp).max().map {
                $0.addingTimeInterval(0.001)
            }
            try Task.checkCancellation()
            let inserted = try repository.replaceCursorRemoteSnapshot(
                events: events,
                replacementStart: startDate,
                replacementEnd: endDate,
                coverageStart: effectiveCoverageStart,
                coverageEnd: effectiveCoverageEnd,
                totalEvents: page.totalCount,
                tokenEvents: tokenEvents,
                attributedEvents: attributedEvents,
                costEvents: costEvents
            )
            return CursorDashboardSyncResult(
                totalEvents: page.totalCount,
                tokenEvents: tokenEvents,
                attributedEvents: attributedEvents,
                costEvents: costEvents,
                insertedEvents: inserted
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw error
            }
            let safeCode = (error as? CursorDashboardUsageError)?.safeCode ?? "cursor_sync_failed"
            try? repository.recordCursorRemoteSnapshotFailure(errorCode: safeCode)
            throw error
        }
    }
}
