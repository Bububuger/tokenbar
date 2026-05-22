import Foundation
import TokenBarCore

struct TokenBarPopoverSnapshot: Sendable, Hashable {
    let generatedAt: Date
    let eventsCount: Int
    let today: UsageSummary
    let last30Days: [UsageDay]
    let peakDay: Date?
    let warningCount: Int
    let lastIndexedAt: Date?
    let todayCost: Double
    let last30Cost: Double
    let todaySessionCount: Int
    let yesterdayDeltaText: String
    let inputShare: String
    let outputShare: String
    let cacheShare: String
    let hourly: HourlyUsageSnapshot
    let hourlyActivityText: String
    let projectRows: [TokenBarPopoverRankingRow]
    let agentRows: [TokenBarPopoverRankingRow]
    let modelRows: [TokenBarPopoverRankingRow]

    static let empty = TokenBarPopoverSnapshot.make(
        snapshot: UsageAggregator.makeSnapshot(from: []),
        events: [],
        diagnostics: DiagnosticsSnapshot(
            dataSourceStatuses: [],
            lastIndexedAt: nil,
            lastUIRefreshAt: nil,
            parserWarningCount: 0,
            refreshState: .idle,
            rebuildError: nil
        )
    )

    static func make(
        snapshot: UsageSnapshot,
        events: [UsageEvent],
        diagnostics: DiagnosticsSnapshot,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TokenBarPopoverSnapshot {
        let started = Date()
        let todayStart = calendar.startOfDay(for: referenceDate)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let last30Start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        var todayCost = 0.0
        var last30Cost = 0.0
        var todaySessionIDs = Set<String>()
        var yesterdayTotal = 0
        var projectCosts: [String: Double] = [:]
        var agentCosts: [String: Double] = [:]
        var projectAgentTokens: [String: [String: Int]] = [:]
        var agentModelTokens: [String: [String: Int]] = [:]
        var modelTotals: [String: ModelAccumulator] = [:]
        let pricing = TokenBarPricingLookup()

        for event in events {
            let eventTokens = event.inputTokens + event.outputTokens + event.cacheTokens
            let eventCost = pricing.estimatedCost(for: event)
            let modelName = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
            let agentName = event.agent.displayName

            if event.timestamp >= todayStart && event.timestamp < tomorrowStart {
                todayCost += eventCost
                todaySessionIDs.insert(event.sessionId)
            } else if event.timestamp >= yesterdayStart && event.timestamp < todayStart {
                yesterdayTotal += eventTokens
            }

            guard event.timestamp >= last30Start && event.timestamp < tomorrowStart else {
                continue
            }

            last30Cost += eventCost
            projectCosts[event.projectName, default: 0] += eventCost
            agentCosts[agentName, default: 0] += eventCost
            projectAgentTokens[event.projectName, default: [:]][agentName, default: 0] += eventTokens
            agentModelTokens[agentName, default: [:]][modelName, default: 0] += eventTokens

            var model = modelTotals[modelName] ?? ModelAccumulator()
            model.inputTokens += event.inputTokens
            model.outputTokens += event.outputTokens
            model.cacheTokens += event.cacheTokens
            model.cost += eventCost
            model.agentTokens[agentName, default: 0] += eventTokens
            modelTotals[modelName] = model
        }

        let hourly = UsageAggregator.makeHourlySnapshot(
            from: events,
            referenceDate: referenceDate,
            calendar: calendar,
            days: 1
        )
        let hourlyActivityText: String
        if let peak = hourly.peakHourOfDay {
            hourlyActivityText = "peak \(String(format: "%02d:00", peak.hourOfDay)) · \(tokenbarCompactTokens(peak.summary.totalTokens)) · \(tokenbarIdleHourRanges(hourly.hoursOfDay))"
        } else {
            hourlyActivityText = "no peak yet"
        }

        let last30Total = snapshot.last30Summary.totalTokens
        let projectRows = snapshot.topProjects.prefix(5).map { row in
            TokenBarPopoverRankingRow(
                kind: .project,
                name: row.name,
                subtitle: rankedNames(projectAgentTokens[row.name], fallback: "local indexed project"),
                summary: row.summary,
                cost: projectCosts[row.name] ?? 0,
                badge: nil,
                agentName: nil
            )
        }
        let agentRows = snapshot.topAgents.prefix(5).map { row in
            TokenBarPopoverRankingRow(
                kind: .agent,
                name: row.name,
                subtitle: rankedNames(agentModelTokens[row.name], fallback: "agent share"),
                summary: row.summary,
                cost: agentCosts[row.name] ?? 0,
                badge: shareText(row.summary.totalTokens, total: last30Total),
                agentName: row.name
            )
        }
        let modelRows = modelTotals.map { name, model in
            let summary = UsageSummary(
                inputTokens: model.inputTokens,
                outputTokens: model.outputTokens,
                cacheTokens: model.cacheTokens
            )
            let agentName = topName(model.agentTokens, fallback: "Local")
            let totalTokens = modelTotals.values.reduce(0) { $0 + $1.totalTokens }
            let percentage = totalTokens > 0 ? Double(summary.totalTokens) / Double(totalTokens) : 0
            let cacheRatio = summary.totalTokens > 0 ? Double(summary.cacheTokens) / Double(summary.totalTokens) : 0
            return TokenBarPopoverRankingRow(
                kind: .model,
                name: name,
                subtitle: "\(agentName) · \(tokenbarPercent(percentage)) of tokens",
                summary: summary,
                cost: model.cost,
                badge: "\(tokenbarPercent(cacheRatio)) cache",
                agentName: agentName
            )
        }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
        .prefix(5)

        let result = TokenBarPopoverSnapshot(
            generatedAt: referenceDate,
            eventsCount: events.count,
            today: snapshot.today,
            last30Days: snapshot.last30Days,
            peakDay: snapshot.peakDay,
            warningCount: snapshot.warningCount,
            lastIndexedAt: diagnostics.lastIndexedAt,
            todayCost: todayCost,
            last30Cost: last30Cost,
            todaySessionCount: todaySessionIDs.count,
            yesterdayDeltaText: yesterdayDeltaText(todayTokens: snapshot.today.totalTokens, yesterdayTokens: yesterdayTotal),
            inputShare: shareText(snapshot.today.inputTokens, total: snapshot.today.totalTokens),
            outputShare: shareText(snapshot.today.outputTokens, total: snapshot.today.totalTokens),
            cacheShare: shareText(snapshot.today.cacheTokens, total: snapshot.today.totalTokens),
            hourly: hourly,
            hourlyActivityText: hourlyActivityText,
            projectRows: Array(projectRows),
            agentRows: Array(agentRows),
            modelRows: Array(modelRows)
        )
        TokenBarTelemetry.timing(
            "runtime.popover_snapshot.build",
            startedAt: started,
            metadata: "events=\(events.count) projects=\(result.projectRows.count) agents=\(result.agentRows.count) models=\(result.modelRows.count)"
        )
        return result
    }

    private static func rankedNames(_ totals: [String: Int]?, fallback: String) -> String {
        let names = (totals ?? [:])
            .sorted {
                if $0.value == $1.value {
                    return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                }
                return $0.value > $1.value
            }
            .prefix(3)
            .map(\.key)
        return names.isEmpty ? fallback : names.joined(separator: " · ")
    }

    private static func topName(_ totals: [String: Int], fallback: String) -> String {
        totals.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key ?? fallback
    }

    private static func shareText(_ value: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))%"
    }

    private static func yesterdayDeltaText(todayTokens: Int, yesterdayTokens: Int) -> String {
        guard yesterdayTokens > 0 else { return "vs yest. n/a" }
        let delta = Double(todayTokens - yesterdayTokens) / Double(yesterdayTokens)
        let sign = delta >= 0 ? "+" : ""
        let percent = Int((delta * 100).rounded())
        if abs(percent) > 999 {
            return "vs yest. \(sign)>999%"
        }
        return "vs yest. \(sign)\(percent)%"
    }
}

struct TokenBarPopoverRankingRow: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case project
        case agent
        case model
    }

    let kind: Kind
    let name: String
    let subtitle: String
    let summary: UsageSummary
    let cost: Double
    let badge: String?
    let agentName: String?

    var id: String { "\(kind.rawValue)-\(name)" }
}

private struct ModelAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheTokens = 0
    var cost = 0.0
    var agentTokens: [String: Int] = [:]

    var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }
}
