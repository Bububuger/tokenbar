import Foundation

public enum UsageAggregator {
    public static func makeSnapshot(
        from events: [UsageEvent],
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        days: Int = 30,
        topCount: Int = 3
    ) -> UsageSnapshot {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let allBuckets = bucketedByDay(events, calendar: calendar)

        let lastNDays: [UsageDay] = stride(from: days - 1, through: 0, by: -1).map { offset in
            let bucketDate = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            let bucketSummary = summarize(allBuckets[bucketDate] ?? [])
            return UsageDay(
                date: bucketDate,
                summary: bucketSummary,
                intensity: 0
            )
        }

        let maxTotal = Double(lastNDays.map(\.summary.totalTokens).max() ?? 0)
        let normalizedDays = lastNDays.map { day in
            UsageDay(
                date: day.date,
                summary: day.summary,
                intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0
            )
        }

        let todaySummary = summarize(allBuckets[todayStart] ?? [])
        let todayEvents = allBuckets[todayStart] ?? []
        let last30Events = normalizedDays.flatMap { bucket in
            allBuckets[bucket.date] ?? []
        }
        let focusToday = todaySummary.focus
        let focusLast30 = last30Summary(from: normalizedDays).focus
        let activeDays = normalizedDays.filter { $0.summary.totalTokens > 0 }.count
        let peakDay = normalizedDays
            .filter { $0.summary.totalTokens > 0 }
            .max { lhs, rhs in lhs.summary.totalTokens < rhs.summary.totalTokens }
            .map(\.date)
        let todayCost = costProjection(for: todayEvents)
        let last30Cost = costProjection(for: last30Events)

        let topAgentsToday = rankedBreakdowns(
            totals: Dictionary(grouping: todayEvents, by: { $0.agent.displayName }),
            topCount: topCount
        )
        let topProjectsToday = rankedBreakdowns(
            totals: Dictionary(grouping: todayEvents, by: \.projectName),
            topCount: topCount
        )
        let topAgents = rankedBreakdowns(
            totals: Dictionary(grouping: last30Events, by: { $0.agent.displayName }),
            topCount: topCount
        )
        let topProjects = rankedBreakdowns(
            totals: Dictionary(grouping: last30Events, by: \.projectName),
            topCount: topCount
        )

        return UsageSnapshot(
            generatedAt: referenceDate,
            today: todaySummary,
            last30Days: normalizedDays,
            topAgentsToday: topAgentsToday,
            topProjectsToday: topProjectsToday,
            topAgents: topAgents,
            topProjects: topProjects,
            focusToday: focusToday,
            focusLast30: focusLast30,
            activeDays: activeDays,
            peakDay: peakDay,
            estimatedCostToday: todayCost,
            estimatedCostLast30: last30Cost
        )
    }

    public static func makeProjectDetail(
        projectName: String,
        from events: [UsageEvent],
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        days: Int = 30,
        topAgentCount: Int = 5,
        sessionCount: Int = 5
    ) -> ProjectDetailSnapshot? {
        let projectEvents = events.filter { $0.projectName == projectName }
        guard !projectEvents.isEmpty else {
            return nil
        }

        let todayStart = calendar.startOfDay(for: referenceDate)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        let last30ProjectEvents = projectEvents.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
        let summary = summarize(last30ProjectEvents)
        guard summary.totalTokens > 0 else {
            return nil
        }
        let buckets = bucketedByDay(last30ProjectEvents, calendar: calendar)

        let lastNDays: [UsageDay] = stride(from: days - 1, through: 0, by: -1).map { offset in
            let bucketDate = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            let bucketSummary = summarize(buckets[bucketDate] ?? [])
            return UsageDay(date: bucketDate, summary: bucketSummary, intensity: 0)
        }

        let maxTotal = Double(lastNDays.map(\.summary.totalTokens).max() ?? 0)
        let normalizedDays = lastNDays.map { day in
            UsageDay(
                date: day.date,
                summary: day.summary,
                intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0
            )
        }

        let agentShare = Dictionary(grouping: last30ProjectEvents, by: { $0.agent.displayName })
            .map { name, events in
                let summary = summarize(events)
                return AgentShareSlice(
                    name: name,
                    totalTokens: summary.totalTokens,
                    percentage: Double(summary.totalTokens) / Double(max(summary.totalTokens, 1))
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens == rhs.totalTokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.totalTokens > rhs.totalTokens
            }
            .prefix(topAgentCount)
            .map { slice in
                AgentShareSlice(
                    name: slice.name,
                    totalTokens: slice.totalTokens,
                    percentage: summary.totalTokens > 0 ? Double(slice.totalTokens) / Double(summary.totalTokens) : 0
                )
            }

        let recentSessions = Dictionary(grouping: last30ProjectEvents, by: \.sessionId)
            .compactMap { sessionId, events -> ProjectSessionSummary? in
                guard let latestEvent = events.max(by: { $0.timestamp < $1.timestamp }) else {
                    return nil
                }
                return ProjectSessionSummary(
                    sessionId: sessionId,
                    agentName: latestEvent.agent.displayName,
                    timestamp: latestEvent.timestamp,
                    summary: summarize(events)
                )
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.summary.totalTokens > rhs.summary.totalTokens
                }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(sessionCount)
            .map { $0 }
        let activeDays = normalizedDays.filter { $0.summary.totalTokens > 0 }.count
        let peakDay = normalizedDays
            .filter { $0.summary.totalTokens > 0 }
            .max { lhs, rhs in lhs.summary.totalTokens < rhs.summary.totalTokens }
            .map(\.date)
        let estimatedCost = costProjection(for: last30ProjectEvents)
        let focus = summary.focus

        return ProjectDetailSnapshot(
            projectName: projectName,
            summary: summary,
            last30Days: normalizedDays,
            agentShare: agentShare,
            recentSessions: recentSessions,
            focus: focus,
            activeDays: activeDays,
            peakDay: peakDay,
            estimatedCost: estimatedCost
        )
    }

    public static func makeHourlySnapshot(
        from events: [UsageEvent],
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        days: Int = 30,
        projectName: String? = nil,
        agent: AgentKind? = nil
    ) -> HourlyUsageSnapshot {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let windowStart = days == 0
            ? nil
            : calendar.date(byAdding: .day, value: -(days - 1), to: todayStart)
        let windowEnd = days == 0
            ? nil
            : calendar.date(byAdding: .day, value: 1, to: todayStart)
        let filteredEvents = events.filter { event in
            if let windowStart, event.timestamp < windowStart {
                return false
            }
            if let windowEnd, event.timestamp >= windowEnd {
                return false
            }
            if let projectName, event.projectName != projectName {
                return false
            }
            if let agent, event.agent != agent {
                return false
            }
            return true
        }
        let groupedByHour = Dictionary(grouping: filteredEvents) { event in
            startOfHour(for: event.timestamp, calendar: calendar)
        }

        let rawHours: [UsageHour]
        if let windowStart, let windowEnd {
            rawHours = hourlyRange(from: windowStart, to: windowEnd, calendar: calendar).map { start in
                let hourEvents = groupedByHour[start] ?? []
                return UsageHour(
                    start: start,
                    hourOfDay: calendar.component(.hour, from: start),
                    eventCount: hourEvents.count,
                    summary: summarize(hourEvents),
                    intensity: 0
                )
            }
        } else {
            rawHours = groupedByHour
                .map { start, hourEvents in
                    UsageHour(
                        start: start,
                        hourOfDay: calendar.component(.hour, from: start),
                        eventCount: hourEvents.count,
                        summary: summarize(hourEvents),
                        intensity: 0
                    )
                }
                .sorted { $0.start < $1.start }
        }

        let hourMax = Double(rawHours.map(\.summary.totalTokens).max() ?? 0)
        let normalizedHours = rawHours.map { hour in
            UsageHour(
                start: hour.start,
                hourOfDay: hour.hourOfDay,
                eventCount: hour.eventCount,
                summary: hour.summary,
                intensity: hourMax > 0 ? Double(hour.summary.totalTokens) / hourMax : 0
            )
        }
        let rawHoursOfDay = Dictionary(grouping: normalizedHours, by: \.hourOfDay)
            .map { hourOfDay, hours in
                UsageHourOfDay(
                    hourOfDay: hourOfDay,
                    eventCount: hours.reduce(0) { $0 + $1.eventCount },
                    activeHourCount: hours.filter { $0.summary.totalTokens > 0 }.count,
                    summary: UsageSummary(
                        inputTokens: hours.reduce(0) { $0 + $1.summary.inputTokens },
                        outputTokens: hours.reduce(0) { $0 + $1.summary.outputTokens },
                        cacheTokens: hours.reduce(0) { $0 + $1.summary.cacheTokens }
                    ),
                    intensity: 0
                )
            }
            .sorted { $0.hourOfDay < $1.hourOfDay }
        let hourOfDayMax = Double(rawHoursOfDay.map(\.summary.totalTokens).max() ?? 0)
        let normalizedHoursOfDay = rawHoursOfDay.map { hour in
            UsageHourOfDay(
                hourOfDay: hour.hourOfDay,
                eventCount: hour.eventCount,
                activeHourCount: hour.activeHourCount,
                summary: hour.summary,
                intensity: hourOfDayMax > 0 ? Double(hour.summary.totalTokens) / hourOfDayMax : 0
            )
        }
        let nonEmptyHours = normalizedHours.filter { $0.summary.totalTokens > 0 }
        let peakHour = nonEmptyHours.max { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.start < rhs.start
            }
            return lhs.summary.totalTokens < rhs.summary.totalTokens
        }
        let peakHourOfDay = normalizedHoursOfDay
            .filter { $0.summary.totalTokens > 0 }
            .max { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.hourOfDay > rhs.hourOfDay
                }
                return lhs.summary.totalTokens < rhs.summary.totalTokens
            }

        return HourlyUsageSnapshot(
            generatedAt: referenceDate,
            summary: summarize(filteredEvents),
            eventCount: filteredEvents.count,
            hours: normalizedHours,
            hoursOfDay: normalizedHoursOfDay,
            peakHour: peakHour,
            peakHourOfDay: peakHourOfDay
        )
    }

    private static func bucketedByDay(
        _ events: [UsageEvent],
        calendar: Calendar
    ) -> [Date: [UsageEvent]] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.timestamp) }
    }

    private static func rankedBreakdowns(
        totals: [String: [UsageEvent]],
        topCount: Int
    ) -> [UsageBreakdown] {
        totals
            .map { name, events in
                UsageBreakdown(name: name, summary: summarize(events))
            }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
            .prefix(topCount)
            .map { $0 }
    }

    private static func summarize(_ events: [UsageEvent]) -> UsageSummary {
        UsageSummary(
            inputTokens: events.reduce(0) { $0 + $1.inputTokens },
            outputTokens: events.reduce(0) { $0 + $1.outputTokens },
            cacheTokens: events.reduce(0) { $0 + $1.cacheTokens }
        )
    }

    private static func startOfHour(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func hourlyRange(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var output: [Date] = []
        var cursor = startOfHour(for: start, calendar: calendar)
        while cursor < end {
            output.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return output
    }

    private static func last30Summary(from days: [UsageDay]) -> UsageSummary {
        UsageSummary(
            inputTokens: days.reduce(0) { $0 + $1.summary.inputTokens },
            outputTokens: days.reduce(0) { $0 + $1.summary.outputTokens },
            cacheTokens: days.reduce(0) { $0 + $1.summary.cacheTokens }
        )
    }

    private static func costProjection(for events: [UsageEvent]) -> UsageCostProjection {
        let totalsByModel = events.reduce(into: [String: (tokens: Int, cost: Double)]()) { totals, event in
            let modelName = event.modelName ?? event.agent.displayName
            let tokenCount = event.inputTokens + event.outputTokens + event.cacheTokens
            let current = totals[modelName] ?? (tokens: 0, cost: 0)
            totals[modelName] = (
                tokens: current.tokens + tokenCount,
                cost: current.cost + Double(tokenCount) * event.agent.defaultCostPerMillionTokens / 1_000_000
            )
        }
        let totalTokens = totalsByModel.values.reduce(0) { $0 + $1.tokens }
        let byAgent = totalsByModel
            .map { model, totals in
                let percentage = totalTokens > 0 ? Double(totals.tokens) / Double(totalTokens) : 0
                return UsageCostBreakdown(
                    name: model,
                    totalTokens: totals.tokens,
                    cost: totals.cost,
                    percentage: percentage
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens == rhs.totalTokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.totalTokens > rhs.totalTokens
            }
        let totalCost = byAgent.reduce(0) { $0 + $1.cost }
        let blendedRatePerMillion = totalTokens > 0
            ? totalCost / Double(totalTokens) * 1_000_000
            : 0

        return UsageCostProjection(
            totalCost: totalCost,
            blendedRatePerMillion: blendedRatePerMillion,
            byAgent: byAgent
        )
    }
}
