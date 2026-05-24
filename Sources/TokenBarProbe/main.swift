import Foundation
import TokenBarCore

@main
struct TokenBarProbe {
    static func main() async {
        if ProcessInfo.processInfo.environment["TOKENBAR_PROBE_ROUTE_BENCH"] == "1" {
            await runRouteBench()
            return
        }

        let settingsStore = SettingsStore()
        let useDefaultDatabase = ProcessInfo.processInfo.environment["TOKENBAR_PROBE_USE_DEFAULT_DATABASE"] == "1"
        let store: UsageStore
        if useDefaultDatabase {
            do {
                store = try UsageStore(databaseURL: UsageDatabase.defaultDatabaseURL())
            } catch {
                FileHandle.standardError.write(Data("Failed to open default TokenBar database: \(error)\n".utf8))
                Foundation.exit(1)
            }
        } else {
            store = UsageStore()
        }
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()

        let sources = BuiltInSources.all()

        let rebuilder = IndexRebuilder(sources: sources, store: store)
        let result = await rebuilder.rebuild(indexedAt: now, referenceDate: now, calendar: calendar)
        let noOpResult = await rebuilder.rebuild(indexedAt: Date(), referenceDate: now, calendar: calendar)
        let finalState = noOpResult.state

        let statuses = await collectStatuses(from: sources, referenceDate: now, calendar: calendar)
        let refreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: finalState.lastIndexedAt,
            lastRebuildError: finalState.lastRebuildError,
            refreshInterval: settingsStore.refreshInterval
        )

        let payload: [String: Any] = [
            "acceptance_status": acceptanceStatus(for: noOpResult),
            "generated_at": iso8601(now),
            "refresh_interval": settingsStore.refreshInterval.rawValue,
            "refresh_state": refreshState.rawValue,
            "database_scope": useDefaultDatabase ? "default_app_database" : "temporary_probe_database",
            "last_indexed_at": finalState.lastIndexedAt.map(iso8601) as Any,
            "parser_warning_count": finalState.warnings.count,
            "rebuild_error": finalState.lastRebuildError as Any,
            "event_count": finalState.events.count,
            "prompt_count": finalState.prompts.count,
            "last_checkpoint_id": finalState.lastCheckpoint?.id as Any,
            "last_checkpoint_events_added": finalState.lastCheckpoint?.eventsAdded as Any,
            "last_checkpoint_prompts_added": finalState.lastCheckpoint?.promptsAdded as Any,
            "first_checkpoint_events_added": result.state.lastCheckpoint?.eventsAdded as Any,
            "first_checkpoint_prompts_added": result.state.lastCheckpoint?.promptsAdded as Any,
            "no_op_checkpoint_events_added": noOpResult.state.lastCheckpoint?.eventsAdded as Any,
            "no_op_checkpoint_prompts_added": noOpResult.state.lastCheckpoint?.promptsAdded as Any,
            "today_total_tokens": finalState.snapshot.today.totalTokens,
            "top_projects": finalState.snapshot.topProjects.map {
                [
                    "name": $0.name,
                    "total_tokens": $0.summary.totalTokens,
                ]
            },
            "top_agents": finalState.snapshot.topAgents.map {
                [
                    "name": $0.name,
                    "total_tokens": $0.summary.totalTokens,
                ]
            },
            "data_sources": statuses.map {
                [
                    "name": $0.sourceName,
                    "root_path": $0.rootPath,
                    "is_readable": $0.isReadable,
                    "discovered_file_count": $0.discoveredFileCount,
                ]
            },
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Failed to encode probe payload: \(error)\n".utf8))
            Foundation.exit(1)
        }

        if noOpResult.failure != nil && finalState.events.isEmpty {
            Foundation.exit(2)
        }
    }

    private static func collectStatuses(
        from sources: [any InspectableUsageEventSource],
        referenceDate: Date,
        calendar: Calendar
    ) async -> [UsageDataSourceStatus] {
        var statuses: [UsageDataSourceStatus] = []
        for source in sources {
            statuses.append(await source.status(referenceDate: referenceDate, calendar: calendar))
        }
        return statuses.sorted { $0.sourceName < $1.sourceName }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func acceptanceStatus(for result: IndexRebuildResult) -> String {
        if result.failure == nil {
            return "pass"
        }
        return result.state.events.isEmpty ? "fail" : "pass_with_warnings"
    }

    private static func runRouteBench() async {
        do {
            let store = try UsageStore(databaseURL: UsageDatabase.defaultDatabaseURL())
            let calendar = Calendar(identifier: .gregorian)
            let started = Date()
            let state = await store.state(referenceDate: started, calendar: calendar, includePrompts: false, includeEvents: true)
            let events = state.events
            let customSources = (try? await store.customSources()) ?? []
            let enabledCustomSources = customSources.filter(\.enabled)
            let expandedCustomSources = enabledCustomSources
                .map { source in
                    (
                        name: source.name,
                        directory: CodexDataSource.expandHome(in: source.directory)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    )
                }
                .sorted { $0.directory.count > $1.directory.count }
            let statusRows = [
                UsageDataSourceStatus(sourceName: "Claude Code", rootPath: "~/.claude/projects/", isReadable: true, discoveredFileCount: 0),
                UsageDataSourceStatus(sourceName: "Codex", rootPath: "~/.codex/sessions/", isReadable: true, discoveredFileCount: 0),
                UsageDataSourceStatus(sourceName: "Hermes", rootPath: "~/.hermes/state.db", isReadable: true, discoveredFileCount: 0),
            ] + customSources.map { source in
                UsageDataSourceStatus(
                    sourceName: source.name,
                    rootPath: source.directory,
                    isReadable: source.enabled,
                    discoveredFileCount: 0
                )
            }
            let cachedHeader = (
                todayCost: routeBenchEstimatedCost(events: events, days: 1, referenceDate: started, calendar: calendar),
                last30Cost: routeBenchEstimatedCost(events: events, days: 30, referenceDate: started, calendar: calendar),
                todaySessions: routeBenchSessionCount(events, days: 1, referenceDate: started, calendar: calendar)
            )
            let cachedHourly = UsageAggregator.makeHourlySnapshot(
                from: events,
                referenceDate: started,
                calendar: calendar,
                days: 1
            )
            let todayStart = calendar.startOfDay(for: started)
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? started
            let last30Start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

            var benches: [BenchResult] = [
                bench(name: "status_item_mirror_legacy_event_scan", iterations: 100) {
                    _ = routeBenchEstimatedCost(events: events, days: 1, referenceDate: started, calendar: calendar)
                    _ = routeBenchSessionCount(events, days: 1, referenceDate: started, calendar: calendar)
                },
                bench(name: "status_item_mirror_cached_snapshot_reads", iterations: 1_000) {
                    _ = cachedHeader.todayCost
                    _ = cachedHeader.todaySessions
                },
                bench(name: "overview_header_legacy_event_scan", iterations: 100) {
                    _ = routeBenchEstimatedCost(events: events, days: 1, referenceDate: started, calendar: calendar)
                    _ = routeBenchSessionCount(events, days: 1, referenceDate: started, calendar: calendar)
                },
                bench(name: "overview_range_legacy_event_scan", iterations: 20) {
                    _ = routeBenchOverviewRange(events: events, referenceDate: started, calendar: calendar)
                },
                bench(name: "overview_hourly_legacy_event_scan", iterations: 100) {
                    let hourly = UsageAggregator.makeHourlySnapshot(
                        from: events,
                        referenceDate: started,
                        calendar: calendar,
                        days: 1
                    )
                    _ = hourly.peakHourOfDay?.summary.totalTokens ?? 0
                    _ = routeBenchIdleHourRanges(hourly.hoursOfDay)
                    _ = hourly.hoursOfDay.count
                },
                bench(name: "settings_header_legacy_event_scan", iterations: 100) {
                    _ = routeBenchEstimatedCost(events: events, days: 1, referenceDate: started, calendar: calendar)
                    _ = routeBenchEstimatedCost(events: events, days: 30, referenceDate: started, calendar: calendar)
                    _ = routeBenchSessionCount(events, days: 1, referenceDate: started, calendar: calendar)
                },
                bench(name: "overview_header_cached_snapshot_reads", iterations: 1_000) {
                    _ = cachedHeader.todayCost
                    _ = cachedHeader.todaySessions
                },
                bench(name: "settings_header_cached_snapshot_reads", iterations: 1_000) {
                    _ = cachedHeader.todayCost
                    _ = cachedHeader.last30Cost
                    _ = cachedHeader.todaySessions
                },
                bench(name: "overview_hourly_cached_snapshot_reads", iterations: 1_000) {
                    _ = cachedHourly.peakHourOfDay?.summary.totalTokens ?? 0
                    _ = routeBenchIdleHourRanges(cachedHourly.hoursOfDay)
                    _ = cachedHourly.hoursOfDay.count
                },
                bench(name: "settings_oldest_record_legacy_min_scan", iterations: 100) {
                    _ = events.map(\.timestamp).min()
                },
                bench(name: "settings_oldest_record_sorted_first_read", iterations: 1_000) {
                    _ = events.first?.timestamp
                },
                bench(name: "diagnostics_source_counts_legacy_path_scan", iterations: 3) {
                    let sourcePaths = [
                        "~/.claude/projects/",
                        "~/.codex/sessions/",
                        "~/.hermes/state.db",
                    ] + customSources.map(\.directory)
                    for path in sourcePaths {
                        _ = routeBenchEventCount(events: events, sourcePath: path)
                    }
                },
                bench(name: "diagnostics_source_drawer_legacy_filter_sort", iterations: 10) {
                    _ = routeBenchSourceDrawerLegacy(events: events, sourcePath: "~/.codex/sessions/")
                },
                bench(name: "diagnostics_source_drawer_reversed_prefix", iterations: 100) {
                    _ = routeBenchSourceDrawerOptimized(events: events, sourcePath: "~/.codex/sessions/")
                },
                bench(name: "diagnostics_data_audit_legacy_path_scan", iterations: 3) {
                    _ = routeBenchDataAudit(events: events, customSources: expandedCustomSources)
                },
                bench(name: "diagnostics_derived_rows_optimized_one_pass", iterations: 100) {
                    _ = routeBenchOptimizedDiagnostics(
                        events: events,
                        customSources: customSources,
                        statuses: statusRows
                    )
                },
            ]
            benches.append(await benchAsync(name: "overview_range_db_aggregate", iterations: 100) {
                _ = try? await store.rangeAggregate(start: last30Start, end: tomorrowStart, calendar: calendar)
            })
            benches.append(await benchAsync(name: "sidebar_projects_db_breakdowns", iterations: 100) {
                _ = try? await store.projectBreakdowns(start: last30Start, end: tomorrowStart, topCount: nil)
            })

            let payload: [String: Any] = [
                "generated_at": iso8601(started),
                "event_count": events.count,
                "prompt_count": state.promptCount,
                "custom_source_count": customSources.count,
                "benchmarks": benches.map { $0.dictionary },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Route bench failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private struct BenchResult {
        let name: String
        let iterations: Int
        let minMS: Double
        let p50MS: Double
        let p95MS: Double
        let maxMS: Double

        var dictionary: [String: Any] {
            [
                "name": name,
                "iterations": iterations,
                "min_ms": rounded(minMS),
                "p50_ms": rounded(p50MS),
                "p95_ms": rounded(p95MS),
                "max_ms": rounded(maxMS),
            ]
        }
    }

    private static func bench(name: String, iterations: Int, _ block: () -> Void) -> BenchResult {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let started = Date()
            block()
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        let sorted = samples.sorted()
        return BenchResult(
            name: name,
            iterations: iterations,
            minMS: sorted.first ?? 0,
            p50MS: percentile(sorted, 0.50),
            p95MS: percentile(sorted, 0.95),
            maxMS: sorted.last ?? 0
        )
    }

    private static func benchAsync(name: String, iterations: Int, _ block: () async -> Void) async -> BenchResult {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let started = Date()
            await block()
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        let sorted = samples.sorted()
        return BenchResult(
            name: name,
            iterations: iterations,
            minMS: sorted.first ?? 0,
            p50MS: percentile(sorted, 0.50),
            p95MS: percentile(sorted, 0.95),
            maxMS: sorted.last ?? 0
        )
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func routeBenchEstimatedCost(
        events: [UsageEvent],
        days: Int,
        referenceDate: Date,
        calendar: Calendar
    ) -> Double {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        return events.reduce(0.0) { total, event in
            guard event.timestamp >= windowStart, event.timestamp < windowEnd else {
                return total
            }
            let tokens = event.inputTokens + event.outputTokens + event.cacheTokens
            return total + Double(tokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
        }
    }

    private static func routeBenchSessionCount(
        _ events: [UsageEvent],
        days: Int,
        referenceDate: Date,
        calendar: Calendar
    ) -> Int {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        var sessions = Set<String>()
        for event in events where event.timestamp >= windowStart && event.timestamp < windowEnd {
            sessions.insert(event.sessionId)
        }
        return sessions.count
    }

    private static func routeBenchOverviewRange(
        events: [UsageEvent],
        referenceDate: Date,
        calendar: Calendar
    ) -> Int {
        let rangeEvents = routeBenchEventsInLastDays(events: events, days: 30, referenceDate: referenceDate, calendar: calendar)
        var projectTotals: [String: Int] = [:]
        var agentTotals: [String: Int] = [:]
        var modelTotals: [String: Int] = [:]
        for event in rangeEvents {
            let tokens = event.inputTokens + event.outputTokens + event.cacheTokens
            projectTotals[event.projectName, default: 0] += tokens
            agentTotals[event.agent.displayName, default: 0] += tokens
            modelTotals[event.modelName ?? event.agent.displayName, default: 0] += tokens
        }
        let projectTop = projectTotals.sorted { $0.value > $1.value }.prefix(5).count
        let agentTop = agentTotals.sorted { $0.value > $1.value }.prefix(5).count
        let modelTop = modelTotals.sorted { $0.value > $1.value }.prefix(8).count
        return rangeEvents.count + projectTop + agentTop + modelTop
    }

    private static func routeBenchEventsInLastDays(
        events: [UsageEvent],
        days: Int,
        referenceDate: Date,
        calendar: Calendar
    ) -> [UsageEvent] {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        return events.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    private static func routeBenchEventCount(events: [UsageEvent], sourcePath: String) -> Int {
        events.reduce(0) { count, event in
            routeBenchEventPath(event.sourcePath, belongsTo: sourcePath) ? count + 1 : count
        }
    }

    private static func routeBenchDataAudit(
        events: [UsageEvent],
        customSources: [(name: String, directory: String)]
    ) -> [String: UsageSummary] {
        var totals: [String: UsageSummary] = [:]
        for event in events {
            let sourceName = routeBenchSourceName(for: event, customSources: customSources)
            let current = totals[sourceName] ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)
            totals[sourceName] = UsageSummary(
                inputTokens: current.inputTokens + event.inputTokens,
                outputTokens: current.outputTokens + event.outputTokens,
                cacheTokens: current.cacheTokens + event.cacheTokens
            )
        }
        return totals
    }

    private static func routeBenchSourceName(
        for event: UsageEvent,
        customSources: [(name: String, directory: String)]
    ) -> String {
        let normalizedEventPath = event.sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let source = customSources.first(where: { normalizedEventPath.hasPrefix($0.directory + "/") || normalizedEventPath == $0.directory }) {
            return source.name
        }
        return event.agent.displayName
    }

    private static func routeBenchEventPath(_ eventPath: String, belongsTo sourcePath: String) -> Bool {
        let expanded = CodexDataSource.expandHome(in: sourcePath)
        if eventPath == expanded {
            return true
        }
        let directoryPrefix = expanded.hasSuffix("/") ? expanded : "\(expanded)/"
        return eventPath.hasPrefix(directoryPrefix)
    }

    private static func routeBenchSourceDrawerLegacy(events: [UsageEvent], sourcePath: String) -> [UsageEvent] {
        let prefix = CodexDataSource.expandHome(in: sourcePath)
        return Array(events
            .filter { $0.sourcePath.hasPrefix(prefix) || $0.sourcePath.contains(sourcePath) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(50))
    }

    private static func routeBenchSourceDrawerOptimized(events: [UsageEvent], sourcePath: String) -> [UsageEvent] {
        let prefix = CodexDataSource.expandHome(in: sourcePath)
        return Array(events.reversed().lazy
            .filter { $0.sourcePath.hasPrefix(prefix) || $0.sourcePath.contains(sourcePath) }
            .prefix(50))
    }

    private static func routeBenchIdleHourRanges(_ hours: [UsageHourOfDay]) -> String {
        let totalsByHour = hours.reduce(into: [Int: Int]()) { totals, hour in
            totals[hour.hourOfDay, default: 0] += hour.summary.totalTokens
        }
        let idleHours = (0..<24).filter { (totalsByHour[$0] ?? 0) == 0 }
        guard !idleHours.isEmpty else { return "no idle hours" }
        if idleHours.count == 24 { return "idle all day" }

        var ranges: [String] = []
        var start = idleHours[0]
        var previous = idleHours[0]
        for hour in idleHours.dropFirst() {
            if hour == previous + 1 {
                previous = hour
            } else {
                ranges.append(routeBenchFormatIdleRange(start: start, end: previous))
                start = hour
                previous = hour
            }
        }
        ranges.append(routeBenchFormatIdleRange(start: start, end: previous))
        return "idle " + ranges.prefix(3).joined(separator: " · ")
    }

    private static func routeBenchFormatIdleRange(start: Int, end: Int) -> String {
        if start == end {
            return String(format: "%02d:00", start)
        }
        return String(format: "%02d-%02d", start, end)
    }

    private struct RouteBenchDerivedRows {
        let sourceRows: Int
        let auditRows: Int
        let countedEvents: Int
    }

    private static func routeBenchOptimizedDiagnostics(
        events: [UsageEvent],
        customSources: [CustomSourceRecord],
        statuses: [UsageDataSourceStatus]
    ) -> RouteBenchDerivedRows {
        var builtInCounts: [AgentKind: Int] = [:]
        var customCounts: [String: Int] = [:]
        var auditTotals: [String: UsageSummary] = [:]
        var total = UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)
        let allCustomNamesByID = Dictionary(uniqueKeysWithValues: customSources.map { ($0.id, $0.name) })
        let enabledCustomNamesByID = Dictionary(uniqueKeysWithValues: customSources.filter(\.enabled).map { ($0.id, $0.name) })

        for event in events {
            let customID = routeBenchCustomSourceID(from: event.id)
            if let customID, allCustomNamesByID[customID] != nil {
                customCounts[customID, default: 0] += 1
            } else {
                builtInCounts[event.agent, default: 0] += 1
            }

            let auditName = customID.flatMap { enabledCustomNamesByID[$0] } ?? event.agent.displayName
            auditTotals[auditName] = routeBenchAdd(event, to: auditTotals[auditName])
            total = routeBenchAdd(event, to: total)
        }

        let sourceRows: Int
        if statuses.isEmpty {
            sourceRows = 3 + customSources.count
        } else {
            for status in statuses {
                _ = routeBenchCountForStatus(
                    status,
                    builtInCounts: builtInCounts,
                    customSources: customSources,
                    customCounts: customCounts
                )
            }
            let existingPaths = Set(statuses.map { routeBenchNormalizedPath($0.rootPath) })
            let missingCustomRows = customSources.filter { !existingPaths.contains(routeBenchNormalizedPath($0.directory)) }.count
            sourceRows = statuses.count + missingCustomRows
        }

        return RouteBenchDerivedRows(
            sourceRows: sourceRows,
            auditRows: 1 + auditTotals.count,
            countedEvents: total.totalTokens
        )
    }

    private static func routeBenchAdd(_ event: UsageEvent, to summary: UsageSummary?) -> UsageSummary {
        let summary = summary ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)
        return UsageSummary(
            inputTokens: summary.inputTokens + event.inputTokens,
            outputTokens: summary.outputTokens + event.outputTokens,
            cacheTokens: summary.cacheTokens + event.cacheTokens
        )
    }

    private static func routeBenchCustomSourceID(from eventID: String) -> String? {
        guard eventID.hasPrefix("custom:") else { return nil }
        let remainder = eventID.dropFirst("custom:".count)
        guard let end = remainder.firstIndex(of: ":") else { return nil }
        return String(remainder[..<end])
    }

    private static func routeBenchCountForStatus(
        _ status: UsageDataSourceStatus,
        builtInCounts: [AgentKind: Int],
        customSources: [CustomSourceRecord],
        customCounts: [String: Int]
    ) -> Int {
        if let custom = customSources.first(where: {
            $0.name == status.sourceName || routeBenchNormalizedPath($0.directory) == routeBenchNormalizedPath(status.rootPath)
        }) {
            return customCounts[custom.id, default: 0]
        }

        let sourceName = status.sourceName.lowercased()
        let rootPath = status.rootPath.lowercased()
        if sourceName.contains("codex") || rootPath.contains(".codex") {
            return builtInCounts[.codex, default: 0]
        }
        if sourceName.contains("claude") || rootPath.contains(".claude") {
            return builtInCounts[.claudeCode, default: 0]
        }
        if sourceName.contains("hermes") || rootPath.contains(".hermes") {
            return builtInCounts[.hermes, default: 0]
        }
        return 0
    }

    private static func routeBenchNormalizedPath(_ path: String) -> String {
        CodexDataSource.expandHome(in: path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
