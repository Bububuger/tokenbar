import AppKit
import SwiftUI
import TokenBarCore

enum TokenBarStyle {
    static let pagePadding: CGFloat = 24
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 10
    static let sidebarWidth: CGFloat = 248

    private static func adaptiveColor(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Semantic foreground / structure (CL-P0-007 / DESIGN§5.1)
    static let foreground = adaptiveColor(
        "TokenBarForeground",
        dark: NSColor(red: 0.92, green: 0.96, blue: 0.96, alpha: 1),
        light: NSColor(red: 0.15, green: 0.17, blue: 0.18, alpha: 1)
    )
    static let muted = adaptiveColor(
        "TokenBarMuted",
        dark: NSColor(red: 0.56, green: 0.62, blue: 0.66, alpha: 1),
        light: NSColor(red: 0.45, green: 0.48, blue: 0.49, alpha: 1)
    )
    static let faint = adaptiveColor(
        "TokenBarFaint",
        dark: NSColor(red: 0.35, green: 0.42, blue: 0.46, alpha: 1),
        light: NSColor(red: 0.64, green: 0.67, blue: 0.68, alpha: 1)
    )
    static let line = adaptiveColor(
        "TokenBarLine",
        dark: NSColor(red: 0.14, green: 0.21, blue: 0.24, alpha: 1),
        light: NSColor(red: 0.84, green: 0.86, blue: 0.86, alpha: 1)
    )

    // MARK: - Token category colors (CL-P0-010 / DESIGN§3.B.2)
    static let input = adaptiveColor(
        "TokenBarInput",
        dark: NSColor(red: 0.32, green: 0.79, blue: 0.82, alpha: 1),
        light: NSColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255, alpha: 1)
    )
    static let output = adaptiveColor(
        "TokenBarOutput",
        dark: NSColor(red: 0.90, green: 0.52, blue: 0.31, alpha: 1),
        light: NSColor(red: 204 / 255, green: 124 / 255, blue: 94 / 255, alpha: 1)
    )
    static let cache = adaptiveColor(
        "TokenBarCache",
        dark: NSColor(red: 0.50, green: 0.86, blue: 0.56, alpha: 1),
        light: NSColor(red: 0.43, green: 0.66, blue: 0.50, alpha: 1)
    )

    static let selectionBlue = adaptiveColor(
        "TokenBarSelectionBlue",
        dark: NSColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1),
        light: NSColor(red: 0.02, green: 0.49, blue: 0.98, alpha: 1)
    )

    // Cost retains its warm-orange identity from the design, but adapts to
    // light/dark via a NSColor dynamic provider (CL-P0-009 substitute for
    // Asset Catalog `Cost` color set — same effective behavior).
    static let cost = Color(nsColor: NSColor(name: "TokenBarCost") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.94, green: 0.64, blue: 0.24, alpha: 1)
            : NSColor(red: 0.72, green: 0.39, blue: 0.20, alpha: 1)
    })

    // Brand accent (DESIGN§3.B.1). In light mode this is a data/accent color,
    // not a page wash; the popover background stays neutral like a native menu.
    static let accent = Color(nsColor: NSColor(name: "TokenBarAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.06, green: 0.71, blue: 0.65, alpha: 1)
            : NSColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255, alpha: 1)
    })

    // MARK: - Status colors (DESIGN§3.C)
    //
    // Lime is retained for the live-blink mid bar in the menubar glyph because
    // it must read as "healthy" against an arbitrary wallpaper-tinted bar; it
    // is otherwise unused. Warn/Error come from system semantic warnings so
    // they participate in Increase Contrast automatically.
    static let lime = Color(nsColor: NSColor(name: "TokenBarLime") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.72, green: 0.90, blue: 0.29, alpha: 1)
            : NSColor(red: 0.45, green: 0.65, blue: 0.10, alpha: 1)
    })
    static let warn = Color(nsColor: .systemYellow)
    static let error = Color(nsColor: .systemRed)

    static let appBackground = Color(nsColor: NSColor(name: "TokenBarAppBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.035, green: 0.075, blue: 0.095, alpha: 1)
            : NSColor(red: 0.988, green: 0.990, blue: 0.990, alpha: 1)
    })

    static let surface = Color(nsColor: NSColor(name: "TokenBarSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.055, green: 0.115, blue: 0.145, alpha: 1)
            : NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.82)
    })

    static let surfaceRaised = Color(nsColor: NSColor(name: "TokenBarSurfaceRaised") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.075, green: 0.145, blue: 0.18, alpha: 1)
            : NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.94)
    })

    static let controlFill = Color(nsColor: .controlBackgroundColor)

    /// Agent attribution palette (CL-P0-011 / DESIGN§3.B.2).
    /// Codex anchors to brand accent (teal) so it no longer collides with the
    /// Input token color (which is system blue). All others are pulled from
    /// Apple's accessible system palette.
    static func agentColor(_ name: String) -> Color {
        switch name {
        case "Codex":
            return selectionBlue
        case "Claude", "Claude Code":
            return output
        case "Gemini", "Gemini CLI":
            return adaptiveColor(
                "TokenBarGemini",
                dark: NSColor(red: 0.73, green: 0.49, blue: 0.96, alpha: 1),
                light: NSColor(red: 0.41, green: 0.52, blue: 0.47, alpha: 1)
            )
        case "Hermes":
            return adaptiveColor(
                "TokenBarHermes",
                dark: NSColor(red: 0.95, green: 0.45, blue: 0.68, alpha: 1),
                light: NSColor(red: 0.70, green: 0.40, blue: 0.72, alpha: 1)
            )
        default:
            return muted
        }
    }

    static func statusColor(for refreshState: RefreshState) -> Color {
        switch refreshState {
        case .idle:
            cache
        case .refreshing:
            accent
        case .stale:
            warn
        case .failed:
            error
        }
    }
}

/// CL-P1-001 / DESIGN§3.C.1: 4-step usage status scale used by KPI numbers,
/// heatmap accents, and any future "you are X above 30d P50" badge. L0 = below
/// average, L4 = critical (exclamation icon). The mapping is alpha-stable so
/// the scale survives deuteranopia simulation.
enum TokenBarUsageStatus: Int {
    case nominal = 0      // L0
    case elevated         // L1
    case high             // L2
    case warning          // L3
    case critical         // L4

    /// Compute the bucket from today's value vs the 30-day P50 baseline.
    static func compute(today: Int, baseline30d: Int) -> TokenBarUsageStatus {
        guard baseline30d > 0 else { return .nominal }
        let ratio = Double(today) / Double(baseline30d)
        switch ratio {
        case ..<1.0:  return .nominal
        case ..<1.5:  return .elevated
        case ..<2.0:  return .high
        case ..<3.0:  return .warning
        default:      return .critical
        }
    }

    var color: Color {
        switch self {
        case .nominal, .elevated:
            return Color(nsColor: .labelColor) // CL-P1-003: stays neutral when safe
        case .high:
            return Color(nsColor: .systemYellow)
        case .warning:
            return Color(nsColor: .systemOrange)
        case .critical:
            return Color(nsColor: .systemRed)
        }
    }

    var symbol: String? {
        self == .critical ? "exclamationmark.triangle.fill" : nil
    }
}

enum MenuBarMirrorMode: String, CaseIterable, Identifiable {
    case tokens
    case cost
    case sessions
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens:
            "Tokens"
        case .cost:
            "Cost"
        case .sessions:
            "Sessions"
        case .off:
            "Off"
        }
    }
}

struct TokenBarModelBreakdown: Identifiable, Hashable, Sendable {
    let name: String
    let agentName: String
    let summary: UsageSummary
    let cost: Double
    let percentage: Double

    var id: String { name }

    var attribution: String {
        "\(agentName) · \(tokenbarPercent(percentage)) of tokens"
    }

    var cacheRatio: Double {
        guard summary.totalTokens > 0 else { return 0 }
        return Double(summary.cacheTokens) / Double(summary.totalTokens)
    }
}

func tokenbarTokens(_ value: Int) -> String {
    TokenBarNumberFormatting.stagedTokens(value)
}

func tokenbarCompactTokens(_ value: Int) -> String {
    TokenBarNumberFormatting.compactTokens(value, fractionDigits: 2)
}

/// CL-P1-004: split a staged token string ("1.5M") into ("1.5", "M") so the
/// Hero can render the unit suffix in a smaller, faint font. Returns
/// (number, suffix) where suffix may be empty.
func tokenbarSplitStagedTokens(_ value: Int) -> (number: String, suffix: String) {
    let s = TokenBarNumberFormatting.stagedTokens(value)
    if let last = s.last, "KMB".contains(last) {
        return (String(s.dropLast()), String(last))
    }
    if s.hasPrefix(">") { return (s, "") }
    return (s, "")
}

func tokenbarCurrency(_ value: Double, maximumFractionDigits: Int = 2) -> String {
    let absValue = abs(value)
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = min(maximumFractionDigits, absValue >= 10 ? 0 : 2)
    let formatted = formatter.string(from: NSNumber(value: absValue)) ?? String(format: "%.\(maximumFractionDigits)f", absValue)
    return "\(value < 0 ? "-" : "")$\(formatted)"
}

func tokenbarCompactCurrency(_ value: Double) -> String {
    let absValue = abs(value)
    let sign = value < 0 ? "-" : ""
    if absValue >= 1_000_000 {
        return "\(sign)$\(String(format: "%.2f", absValue / 1_000_000))M"
    }
    if absValue >= 1_000 {
        return "\(sign)$\(String(format: "%.2f", absValue / 1_000))K"
    }
    return tokenbarCurrency(value, maximumFractionDigits: absValue < 10 ? 2 : 1)
}

func tokenbarPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func tokenbarRelativeTime(_ date: Date?) -> String {
    guard let date else { return "never" }
    let delta = Date().timeIntervalSince(date)
    // CL-P1-035: when the system clock has been moved backwards the recorded
    // timestamp is now "in the future". Treat that as `just now` rather than
    // surfacing a confusing `in 30m`.
    if delta < 75 { return "now" }
    if delta < 3600 { return "\(Int(delta / 60))m ago" }
    if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

struct TokenBarRangeWindow: Sendable, Hashable {
    let selection: String
    let start: Date
    let end: Date
    let requestedDays: Int?
    let isAllTime: Bool

    var dayCount: Int {
        max(1, Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? 1)
    }
}

func tokenbarDaysForRange(_ selection: String) -> Int? {
    switch selection {
    case "7d":
        7
    case "90d":
        90
    case "1y":
        365
    case "All":
        nil
    case "Custom":
        tokenbarCustomRangeDays()
    default:
        30
    }
}

func tokenbarRangeTitle(_ selection: String) -> String {
    switch selection {
    case "7d":
        "Last 7 days"
    case "90d":
        "Last 90 days"
    case "1y":
        "Last 1 year"
    case "All":
        "All history"
    case "Custom":
        "Custom range"
    default:
        "Last 30 days"
    }
}

func tokenbarRangeShortLabel(_ selection: String) -> String {
    switch selection {
    case "7d", "30d", "90d", "1y":
        selection
    case "All":
        "all"
    case "Custom":
        "custom"
    default:
        "30d"
    }
}

func tokenbarRangeWindow(
    selection: String,
    events: [UsageEvent],
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> TokenBarRangeWindow {
    tokenbarRangeWindow(
        selection: selection,
        earliestEventDate: events.map(\.timestamp).min(),
        referenceDate: referenceDate,
        calendar: calendar
    )
}

func tokenbarRangeWindow(
    selection: String,
    earliestEventDate: Date?,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> TokenBarRangeWindow {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate

    if selection == "All" {
        let earliest = earliestEventDate.map { calendar.startOfDay(for: $0) }
            ?? calendar.date(byAdding: .day, value: -29, to: todayStart)
            ?? todayStart
        return TokenBarRangeWindow(selection: selection, start: earliest, end: tomorrowStart, requestedDays: nil, isAllTime: true)
    }

    if selection == "Custom", let custom = tokenbarCustomRangeWindow(calendar: calendar) {
        return TokenBarRangeWindow(selection: selection, start: custom.start, end: custom.end, requestedDays: custom.days, isAllTime: false)
    }

    let days = tokenbarDaysForRange(selection) ?? 30
    let requestedStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let earliestIndexedDay = earliestEventDate.map { calendar.startOfDay(for: $0) }
    let start = earliestIndexedDay.map { max(requestedStart, $0) } ?? requestedStart
    return TokenBarRangeWindow(selection: selection, start: start, end: tomorrowStart, requestedDays: days, isAllTime: false)
}

func tokenbarRangeEvents(
    events: [UsageEvent],
    selection: String,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    where include: ((UsageEvent) -> Bool)? = nil
) -> [UsageEvent] {
    let window = tokenbarRangeWindow(selection: selection, events: events, referenceDate: referenceDate, calendar: calendar)
    return events.filter { event in
        event.timestamp >= window.start
            && event.timestamp < window.end
            && (include?(event) ?? true)
    }
}

func tokenbarUsageDays(
    events: [UsageEvent],
    selection: String,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    where include: ((UsageEvent) -> Bool)? = nil
) -> [UsageDay] {
    let window = tokenbarRangeWindow(selection: selection, events: events, referenceDate: referenceDate, calendar: calendar)
    let filtered = tokenbarRangeEvents(events: events, selection: selection, referenceDate: referenceDate, calendar: calendar, where: include)
    let buckets = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.timestamp) }

    var days: [UsageDay] = []
    var cursor = window.start
    while cursor < window.end {
        let summary = tokenbarSummary(buckets[cursor] ?? [])
        days.append(UsageDay(date: cursor, summary: summary, intensity: 0))
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
    }

    let maxTotal = Double(days.map(\.summary.totalTokens).max() ?? 0)
    return days.map { day in
        UsageDay(
            date: day.date,
            summary: day.summary,
            intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0
        )
    }
}

func tokenbarSummary(_ events: [UsageEvent]) -> UsageSummary {
    UsageSummary(
        inputTokens: events.reduce(0) { $0 + $1.inputTokens },
        outputTokens: events.reduce(0) { $0 + $1.outputTokens },
        cacheTokens: events.reduce(0) { $0 + $1.cacheTokens }
    )
}

func tokenbarEventsInLastDays(
    events: [UsageEvent],
    days: Int = 1,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> [UsageEvent] {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
    return events.filter { $0.timestamp >= start && $0.timestamp < end }
}

func tokenbarBreakdowns(
    events: [UsageEvent],
    selection: String,
    kind: TokenBarRankingKind,
    topCount: Int? = 5,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> [UsageBreakdown] {
    let filtered = tokenbarRangeEvents(events: events, selection: selection, referenceDate: referenceDate, calendar: calendar)
    return tokenbarBreakdownsFromEvents(events: filtered, kind: kind, topCount: topCount)
}

func tokenbarBreakdownsFromEvents(
    events: [UsageEvent],
    kind: TokenBarRankingKind,
    topCount: Int? = 5
) -> [UsageBreakdown] {
    let grouped: [String: [UsageEvent]]
    switch kind {
    case .project:
        grouped = Dictionary(grouping: events, by: \.projectName)
    case .agent:
        grouped = Dictionary(grouping: events) { $0.agent.displayName }
    }

    let sorted = grouped
        .map { UsageBreakdown(name: $0.key, summary: tokenbarSummary($0.value)) }
        .filter { $0.summary.totalTokens > 0 }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
    guard let topCount else {
        return sorted
    }
    return Array(sorted.prefix(topCount))
}

func tokenbarAgentShare(events: [UsageEvent], topCount: Int = 5) -> [AgentShareSlice] {
    let total = tokenbarSummary(events).totalTokens
    guard total > 0 else { return [] }

    return Dictionary(grouping: events) { $0.agent.displayName }
        .map { name, events in
            let tokens = tokenbarSummary(events).totalTokens
            return AgentShareSlice(
                name: name,
                totalTokens: tokens,
                percentage: Double(tokens) / Double(total)
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens == rhs.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.totalTokens > rhs.totalTokens
        }
        .prefix(topCount)
        .map { $0 }
}

func tokenbarRecentSessions(events: [UsageEvent], limit: Int = 6) -> [ProjectSessionSummary] {
    Dictionary(grouping: events, by: \.sessionId)
        .compactMap { sessionId, events -> ProjectSessionSummary? in
            guard let latestEvent = events.max(by: { $0.timestamp < $1.timestamp }) else {
                return nil
            }
            return ProjectSessionSummary(
                sessionId: sessionId,
                agentName: latestEvent.agent.displayName,
                timestamp: latestEvent.timestamp,
                summary: tokenbarSummary(events)
            )
        }
        .sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
            return lhs.timestamp > rhs.timestamp
        }
        .prefix(limit)
        .map { $0 }
}

func tokenbarRangeAvailabilityNote(
    selection: String,
    days: [UsageDay],
    events: [UsageEvent],
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> String {
    let window = tokenbarRangeWindow(selection: selection, events: events, referenceDate: referenceDate, calendar: calendar)
    return tokenbarRangeAvailabilityNote(selection: selection, days: days, window: window, calendar: calendar)
}

func tokenbarRangeAvailabilityNote(
    selection: String,
    days: [UsageDay],
    window: TokenBarRangeWindow,
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> String {
    let activeDays = days.filter { $0.summary.totalTokens > 0 }.count
    let start = window.start.formatted(.dateTime.month(.abbreviated).day().year())
    let endDate = calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.end
    let end = endDate.formatted(.dateTime.month(.abbreviated).day().year())
    if window.isAllTime || (window.requestedDays.map { days.count < $0 } ?? false) {
        return "\(days.count)d indexed · \(activeDays)d active · \(start) to \(end)"
    }
    return "\(days.count)d window · \(activeDays)d active · \(start) to \(end)"
}

func tokenbarPromptCountsByDay(
    days: [UsageDay],
    prompts: [PromptRecord],
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> [Date: Int] {
    guard !days.isEmpty, !prompts.isEmpty else { return [:] }
    let dayKeys = Set(days.map { calendar.startOfDay(for: $0.date) })
    var counts: [Date: Int] = [:]
    counts.reserveCapacity(dayKeys.count)
    for prompt in prompts {
        let day = calendar.startOfDay(for: prompt.timestamp)
        guard dayKeys.contains(day) else { continue }
        counts[day, default: 0] += 1
    }
    return counts
}

struct TokenBarOverviewRangeMetrics: Sendable, Hashable {
    let selection: String
    let days: [UsageDay]
    let summary: UsageSummary
    let cost: Double
    let projectRows: [TokenBarRankingRow]
    let agentRows: [TokenBarRankingRow]
    let modelRows: [TokenBarModelBreakdown]
    let projectCount: Int
    let agentCount: Int
    let availabilityNote: String

    static let empty = TokenBarOverviewRangeMetrics(
        selection: "",
        days: [],
        summary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0),
        cost: 0,
        projectRows: [],
        agentRows: [],
        modelRows: [],
        projectCount: 0,
        agentCount: 0,
        availabilityNote: "Preparing range"
    )

    static func make(
        events: [UsageEvent],
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TokenBarOverviewRangeMetrics {
        let rangeEvents = tokenbarRangeEvents(
            events: events,
            selection: selection,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let days = tokenbarUsageDays(
            events: events,
            selection: selection,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let projectBreakdowns = tokenbarBreakdownsFromEvents(events: rangeEvents, kind: .project, topCount: 5)
        let agentBreakdowns = tokenbarBreakdownsFromEvents(events: rangeEvents, kind: .agent, topCount: 5)

        return TokenBarOverviewRangeMetrics(
            selection: selection,
            days: days,
            summary: tokenbarSummary(rangeEvents),
            cost: tokenbarEstimatedCost(events: rangeEvents),
            projectRows: tokenbarRankingRowsForFilteredEvents(
                rows: projectBreakdowns,
                events: rangeEvents,
                kind: .project
            ),
            agentRows: tokenbarRankingRowsForFilteredEvents(
                rows: agentBreakdowns,
                events: rangeEvents,
                kind: .agent
            ),
            modelRows: tokenbarModelBreakdowns(events: rangeEvents, days: nil),
            projectCount: Set(rangeEvents.map(\.projectName)).count,
            agentCount: Set(rangeEvents.map { $0.agent.displayName }).count,
            availabilityNote: tokenbarRangeAvailabilityNote(
                selection: selection,
                days: days,
                events: events,
                referenceDate: referenceDate,
                calendar: calendar
            )
        )
    }

    static func make(
        aggregate: UsageRangeAggregate,
        selection: String,
        window: TokenBarRangeWindow,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TokenBarOverviewRangeMetrics {
        struct ModelAccumulator {
            var inputTokens = 0
            var outputTokens = 0
            var cacheTokens = 0
            var cost = 0.0
            var agentTokens: [String: Int] = [:]

            var summary: UsageSummary {
                UsageSummary(inputTokens: inputTokens, outputTokens: outputTokens, cacheTokens: cacheTokens)
            }
        }

        let pricing = TokenBarPricingLookup()
        var projectSummaries: [String: UsageSummary] = [:]
        var projectCosts: [String: Double] = [:]
        var projectAgentTokens: [String: [String: Int]] = [:]
        var agentSummaries: [String: UsageSummary] = [:]
        var agentCosts: [String: Double] = [:]
        var agentProjectTokens: [String: [String: Int]] = [:]
        var modelTotals: [String: ModelAccumulator] = [:]

        for row in aggregate.rows {
            let projectName = row.projectName
            let agentName = row.agent.displayName
            let modelName = row.modelName?.isEmpty == false ? row.modelName! : agentName
            let tokens = row.summary.totalTokens
            let cost = tokenbarEstimatedCost(
                summary: row.summary,
                modelName: row.modelName,
                agent: row.agent,
                pricing: pricing
            )

            projectSummaries[projectName] = tokenbarAdd(projectSummaries[projectName], row.summary)
            projectCosts[projectName, default: 0] += cost
            projectAgentTokens[projectName, default: [:]][agentName, default: 0] += tokens

            agentSummaries[agentName] = tokenbarAdd(agentSummaries[agentName], row.summary)
            agentCosts[agentName, default: 0] += cost
            agentProjectTokens[agentName, default: [:]][projectName, default: 0] += tokens

            var model = modelTotals[modelName] ?? ModelAccumulator()
            model.inputTokens += row.summary.inputTokens
            model.outputTokens += row.summary.outputTokens
            model.cacheTokens += row.summary.cacheTokens
            model.cost += cost
            model.agentTokens[agentName, default: 0] += tokens
            modelTotals[modelName] = model
        }

        let projectBreakdowns = sortedBreakdowns(projectSummaries)
        let agentBreakdowns = sortedBreakdowns(agentSummaries)
        let totalModelTokens = modelTotals.values.reduce(0) { $0 + $1.summary.totalTokens }
        let modelRows = modelTotals.map { name, model in
            let summary = model.summary
            return TokenBarModelBreakdown(
                name: name,
                agentName: topName(model.agentTokens, fallback: "Local"),
                summary: summary,
                cost: model.cost,
                percentage: totalModelTokens > 0 ? Double(summary.totalTokens) / Double(totalModelTokens) : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }

        return TokenBarOverviewRangeMetrics(
            selection: selection,
            days: aggregate.days,
            summary: aggregate.summary,
            cost: modelTotals.values.reduce(0) { $0 + $1.cost },
            projectRows: rankingRows(
                breakdowns: Array(projectBreakdowns.prefix(5)),
                costs: projectCosts,
                subtitles: projectAgentTokens,
                fallback: "local indexed project"
            ),
            agentRows: rankingRows(
                breakdowns: Array(agentBreakdowns.prefix(5)),
                costs: agentCosts,
                subtitles: agentProjectTokens,
                fallback: "agent share"
            ),
            modelRows: modelRows,
            projectCount: projectSummaries.count,
            agentCount: agentSummaries.count,
            availabilityNote: tokenbarRangeAvailabilityNote(
                selection: selection,
                days: aggregate.days,
                window: window,
                calendar: calendar
            )
        )
    }
}

private func tokenbarAdd(_ lhs: UsageSummary?, _ rhs: UsageSummary) -> UsageSummary {
    let lhs = lhs ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)
    return UsageSummary(
        inputTokens: lhs.inputTokens + rhs.inputTokens,
        outputTokens: lhs.outputTokens + rhs.outputTokens,
        cacheTokens: lhs.cacheTokens + rhs.cacheTokens
    )
}

private func sortedBreakdowns(_ summaries: [String: UsageSummary]) -> [UsageBreakdown] {
    summaries.map { UsageBreakdown(name: $0.key, summary: $0.value) }
        .filter { $0.summary.totalTokens > 0 }
        .sorted { lhs, rhs in
            if lhs.summary.totalTokens == rhs.summary.totalTokens {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.summary.totalTokens > rhs.summary.totalTokens
        }
}

private func rankingRows(
    breakdowns: [UsageBreakdown],
    costs: [String: Double],
    subtitles: [String: [String: Int]],
    fallback: String
) -> [TokenBarRankingRow] {
    breakdowns.map { row in
        TokenBarRankingRow(
            name: row.name,
            summary: row.summary,
            totalTokens: row.summary.totalTokens,
            subtitle: rankedNames(subtitles[row.name], fallback: fallback),
            cost: costs[row.name] ?? 0
        )
    }
}

private func rankedNames(_ totals: [String: Int]?, fallback: String, max: Int = 3) -> String {
    let names = (totals ?? [:])
        .sorted {
            if $0.value == $1.value {
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            return $0.value > $1.value
        }
        .prefix(max)
        .map(\.key)
    return names.isEmpty ? fallback : names.joined(separator: " · ")
}

private func topName(_ totals: [String: Int], fallback: String) -> String {
    totals.max {
        if $0.value == $1.value {
            return $0.key > $1.key
        }
        return $0.value < $1.value
    }?.key ?? fallback
}

private func tokenbarCustomRangeDays(defaults: UserDefaults = .standard) -> Int {
    tokenbarCustomRangeWindow(defaults: defaults)?.days ?? 30
}

private func tokenbarCustomRangeWindow(
    defaults: UserDefaults = .standard,
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> (start: Date, end: Date, days: Int)? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    guard let startRaw = defaults.string(forKey: "tokenbar.customRange.from"),
          let endRaw = defaults.string(forKey: "tokenbar.customRange.to"),
          let start = formatter.date(from: startRaw),
          let end = formatter.date(from: endRaw),
          start <= end else {
        return nil
    }
    let startDay = calendar.startOfDay(for: start)
    let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
    let days = max(1, calendar.dateComponents([.day], from: startDay, to: endExclusive).day ?? 1)
    return (startDay, endExclusive, days)
}

func tokenbarSessionCount(_ events: [UsageEvent], days: Int = 1, referenceDate: Date = Date()) -> Int {
    let calendar = Calendar(identifier: .gregorian)
    let todayStart = calendar.startOfDay(for: referenceDate)
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
    return Set(events.filter { $0.timestamp >= start && $0.timestamp < end }.map(\.sessionId)).count
}

func tokenbarIdleHourRanges(_ hours: [UsageHourOfDay]) -> String {
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
            ranges.append(formatIdleRange(start: start, end: previous))
            start = hour
            previous = hour
        }
    }
    ranges.append(formatIdleRange(start: start, end: previous))
    return "idle " + ranges.prefix(3).joined(separator: " · ")
}

private func formatIdleRange(start: Int, end: Int) -> String {
    if start == end {
        return String(format: "%02d", start)
    }
    return String(format: "%02d-%02d", start, end)
}

private let tokenbarPricingOverridesKey = "tokenbar.pricingOverrides"

func tokenbarPricingOverrides(defaults: UserDefaults = .standard) -> [String: PricingValues] {
    guard let json = defaults.string(forKey: tokenbarPricingOverridesKey),
          let data = json.data(using: .utf8),
          let overrides = try? JSONDecoder().decode([String: PricingValues].self, from: data) else {
        return [:]
    }
    return overrides
}

struct TokenBarPricingLookup {
    private let overridesByModel: [String: PricingValues]
    private let defaultsByModel: [String: PricingValues]

    init(defaults: UserDefaults = .standard) {
        overridesByModel = tokenbarPricingOverrides(defaults: defaults).reduce(into: [:]) { result, entry in
            result[Self.key(for: entry.key)] = entry.value.normalized
        }
        defaultsByModel = tokenbarDefaultPricingRows.reduce(into: [:]) { result, row in
            result[Self.key(for: row.model)] = PricingValues(input: row.input, output: row.output, cache: row.cache).normalized
        }
    }

    func values(for modelName: String) -> PricingValues? {
        let key = Self.key(for: modelName)
        guard !key.isEmpty else { return nil }
        return overridesByModel[key] ?? defaultsByModel[key]
    }

    func estimatedCost(for event: UsageEvent) -> Double {
        let modelName = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
        if let pricing = values(for: modelName),
           let inputRate = Double(pricing.input),
           let outputRate = Double(pricing.output),
           let cacheRate = Double(pricing.cache) {
            return (
                Double(event.inputTokens) * inputRate
                + Double(event.outputTokens) * outputRate
                + Double(event.cacheTokens) * cacheRate
            ) / 1_000_000
        }

        let eventTokens = event.inputTokens + event.outputTokens + event.cacheTokens
        return Double(eventTokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
    }

    private static func key(for modelName: String) -> String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private func tokenbarPricingValues(for modelName: String, defaults: UserDefaults = .standard) -> PricingValues? {
    let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else { return nil }
    return TokenBarPricingLookup(defaults: defaults).values(for: trimmedModel)
}

func tokenbarEstimatedCost(for event: UsageEvent, defaults: UserDefaults = .standard) -> Double {
    TokenBarPricingLookup(defaults: defaults).estimatedCost(for: event)
}

func tokenbarEstimatedCost(
    summary: UsageSummary,
    modelName: String?,
    agent: AgentKind,
    pricing: TokenBarPricingLookup = TokenBarPricingLookup()
) -> Double {
    let effectiveModelName = modelName?.isEmpty == false ? modelName! : agent.displayName
    if let values = pricing.values(for: effectiveModelName),
       let inputRate = Double(values.input),
       let outputRate = Double(values.output),
       let cacheRate = Double(values.cache) {
        return (
            Double(summary.inputTokens) * inputRate
                + Double(summary.outputTokens) * outputRate
                + Double(summary.cacheTokens) * cacheRate
        ) / 1_000_000
    }
    return Double(summary.totalTokens) * agent.defaultCostPerMillionTokens / 1_000_000
}

func tokenbarEstimatedCost(
    events: [UsageEvent],
    days: Int? = nil,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    where include: ((UsageEvent) -> Bool)? = nil
) -> Double {
    let boundedEvents: [UsageEvent]
    if let days {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        boundedEvents = events.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
    } else {
        boundedEvents = events
    }

    let pricing = TokenBarPricingLookup()
    return boundedEvents
        .filter { include?($0) ?? true }
        .reduce(0.0) { $0 + pricing.estimatedCost(for: $1) }
}

func tokenbarCostProjection(events: [UsageEvent]) -> UsageCostProjection {
    let pricing = TokenBarPricingLookup()
    var totalsByModel: [String: (tokens: Int, cost: Double)] = [:]
    for event in events {
        let modelName = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
        let eventTokens = event.inputTokens + event.outputTokens + event.cacheTokens
        let current = totalsByModel[modelName] ?? (tokens: 0, cost: 0)
        totalsByModel[modelName] = (
            tokens: current.tokens + eventTokens,
            cost: current.cost + pricing.estimatedCost(for: event)
        )
    }

    let totalTokens = totalsByModel.values.reduce(0) { $0 + $1.tokens }
    let rows = totalsByModel.map { model, totals in
        UsageCostBreakdown(
            name: model,
            totalTokens: totals.tokens,
            cost: totals.cost,
            percentage: totalTokens > 0 ? Double(totals.tokens) / Double(totalTokens) : 0
        )
    }
    .sorted { lhs, rhs in
        if lhs.totalTokens == rhs.totalTokens {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.totalTokens > rhs.totalTokens
    }
    let totalCost = rows.reduce(0.0) { $0 + $1.cost }
    return UsageCostProjection(
        totalCost: totalCost,
        blendedRatePerMillion: totalTokens > 0 ? totalCost / Double(totalTokens) * 1_000_000 : 0,
        byAgent: rows
    )
}

func tokenbarModelBreakdowns(
    events: [UsageEvent],
    projectName: String? = nil,
    days: Int? = 30,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> [TokenBarModelBreakdown] {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let windowStart = days.flatMap { calendar.date(byAdding: .day, value: -($0 - 1), to: todayStart) }
    let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate

    let filtered = events.filter { event in
        if let windowStart, event.timestamp < windowStart {
            return false
        }
        if event.timestamp >= windowEnd {
            return false
        }
        if let projectName, event.projectName != projectName {
            return false
        }
        return true
    }

    struct Accumulator {
        var inputTokens = 0
        var outputTokens = 0
        var cacheTokens = 0
        var cost = 0.0
        var agentTokens: [String: Int] = [:]
    }

    var grouped: [String: Accumulator] = [:]
    let pricing = TokenBarPricingLookup()
    for event in filtered {
        let modelName = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
        var current = grouped[modelName] ?? Accumulator()
        let eventTokens = event.inputTokens + event.outputTokens + event.cacheTokens
        current.inputTokens += event.inputTokens
        current.outputTokens += event.outputTokens
        current.cacheTokens += event.cacheTokens
        current.cost += pricing.estimatedCost(for: event)
        current.agentTokens[event.agent.displayName, default: 0] += eventTokens
        grouped[modelName] = current
    }

    let totalTokens = grouped.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheTokens }

    return grouped.map { name, accumulator in
        let summary = UsageSummary(
            inputTokens: accumulator.inputTokens,
            outputTokens: accumulator.outputTokens,
            cacheTokens: accumulator.cacheTokens
        )
        let agentName = accumulator.agentTokens.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key ?? "Local"
        let percentage = totalTokens > 0 ? Double(summary.totalTokens) / Double(totalTokens) : 0
        return TokenBarModelBreakdown(
            name: name,
            agentName: agentName,
            summary: summary,
            cost: accumulator.cost,
            percentage: percentage
        )
    }
    .sorted { lhs, rhs in
        if lhs.summary.totalTokens == rhs.summary.totalTokens {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.summary.totalTokens > rhs.summary.totalTokens
    }
}

/// CL-P0-014: lightweight hover tooltip used everywhere a mono number is
/// rendered. Uses SwiftUI's `.help(_:)` which sits on top of NSToolTip — same
/// fade-in delay as system tooltips, free `Esc`-to-dismiss, free A11y.
extension View {
    func tbNumberTooltip(precise value: Int, window: String) -> some View {
        let pretty = tokenbarCompactTokens(value)
        return self.help("\(pretty) tokens · \(window)")
    }

    func tbNumberTooltip(precise cost: Double, window: String) -> some View {
        let pretty = tokenbarCompactCurrency(cost)
        return self.help("\(pretty) · \(window)")
    }

    func tbTooltip(_ text: String) -> some View {
        self.help(text)
    }
}

enum TokenBarRankingKind: Sendable {
    case project
    case agent
}

/// Row payload used by RankingCard. CL-P0-015 introduces `subtitle` (per-row
/// agent or project breakdown) and CL-P0-016 introduces `cost`. Both fill
/// gaps that previously rendered as the hard-coded "local indexed usage"
/// string with no cost column.
struct TokenBarRankingRow: Identifiable, Hashable, Sendable {
    let name: String
    let summary: UsageSummary
    let totalTokens: Int
    let subtitle: String
    let cost: Double

    var id: String { name }
}

/// Build display-ready ranking rows for projects or agents.
///
/// For project rows the subtitle lists the top agents *participating* in that
/// project; for agent rows it lists the top projects driven by that agent —
/// matching how the menubar Popover already renders attribution.
func tokenbarRankingRows(
    rows: [UsageBreakdown],
    events: [UsageEvent],
    kind: TokenBarRankingKind,
    days: Int? = 30,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    maxSubtitle: Int = 3
) -> [TokenBarRankingRow] {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let windowStart = days.flatMap { calendar.date(byAdding: .day, value: -($0 - 1), to: todayStart) }
    let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
    let filtered = events.filter { event in
        if let windowStart, event.timestamp < windowStart {
            return false
        }
        return event.timestamp < windowEnd
    }

    return tokenbarRankingRowsForFilteredEvents(rows: rows, events: filtered, kind: kind, maxSubtitle: maxSubtitle)
}

func tokenbarRankingRowsForFilteredEvents(
    rows: [UsageBreakdown],
    events: [UsageEvent],
    kind: TokenBarRankingKind,
    maxSubtitle: Int = 3
) -> [TokenBarRankingRow] {
    let pricing = TokenBarPricingLookup()
    let eventsByName = Dictionary(grouping: events) { event in
        switch kind {
        case .project:
            event.projectName
        case .agent:
            event.agent.displayName
        }
    }

    return rows.map { row in
        let rowEvents = eventsByName[row.name] ?? []
        return TokenBarRankingRow(
            name: row.name,
            summary: row.summary,
            totalTokens: row.summary.totalTokens,
            subtitle: rankingSubtitle(events: rowEvents, kind: kind, max: maxSubtitle),
            cost: rowEvents.reduce(0.0) { partial, event in
                partial + pricing.estimatedCost(for: event)
            }
        )
    }
}

private func rankingSubtitle(events: [UsageEvent], kind: TokenBarRankingKind, max: Int) -> String {
    let totalsByKey: [String: Int]
    switch kind {
    case .project:
        totalsByKey = events.reduce(into: [String: Int]()) { acc, e in
            acc[e.agent.displayName, default: 0] += e.inputTokens + e.outputTokens + e.cacheTokens
        }
    case .agent:
        totalsByKey = events.reduce(into: [String: Int]()) { acc, e in
            acc[e.projectName, default: 0] += e.inputTokens + e.outputTokens + e.cacheTokens
        }
    }
    let top = totalsByKey
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .prefix(max)
        .map(\.key)
    if top.isEmpty {
        return kind == .project ? "no agents yet" : "no projects yet"
    }
    return top.joined(separator: " · ")
}

func tokenbarMirrorValue(
    mode: MenuBarMirrorMode,
    todayTokens: Int,
    todayCost: Double,
    todaySessions: Int
) -> String {
    switch mode {
    case .tokens:
        tokenbarTokens(todayTokens)
    case .cost:
        tokenbarCompactCurrency(todayCost)
    case .sessions:
        "\(todaySessions)"
    case .off:
        ""
    }
}


/// Popover / Settings popover background.
///
/// CL-P0-006: replaces the previous custom dark gradient with `.regularMaterial`
/// so the surface picks up wallpaper tint behind the menubar popover (the
/// SwiftUI analogue of NSWindow.hudWindow material). Reduce Transparency falls
/// back to `controlBackgroundColor` so the surface stays legible without vibrancy.
struct TokenBarGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TokenBarStyle.appBackground
            if !reduceTransparency {
                if colorScheme == .light {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.94),
                            Color(red: 0.965, green: 0.980, blue: 1.0).opacity(0.20),
                            Color(red: 1.0, green: 0.985, blue: 0.992).opacity(0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [
                            Color(red: 0.64, green: 0.82, blue: 1.0).opacity(0.08),
                            Color.clear
                        ],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: 260
                    )
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.80, blue: 0.90).opacity(0.08),
                            Color.clear
                        ],
                        center: .bottom,
                        startRadius: 18,
                        endRadius: 240
                    )
                } else {
                    LinearGradient(
                        colors: [
                            TokenBarStyle.accent.opacity(0.14),
                            TokenBarStyle.appBackground.opacity(0.45),
                            TokenBarStyle.cost.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Menubar popover background. In light mode this is deliberately translucent:
/// system material does the frosted macOS surface, while the neutral white wash
/// keeps TokenBar's data colors from tinting the whole popover green/cyan.
struct TokenBarPopoverBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            ZStack {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Rectangle()
                        .fill(.regularMaterial)
                    Color.white.opacity(0.58)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.46),
                            Color(red: 0.985, green: 0.986, blue: 0.988).opacity(0.16),
                            Color(red: 1.0, green: 0.990, blue: 0.995).opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .ignoresSafeArea()
        } else {
            TokenBarGlassBackground()
        }
    }
}

/// Sidebar background (CL-P0-008). `.bar` material renders a SwiftUI surface
/// equivalent to NSVisualEffectView with `.sidebar` material; falls back to a
/// flat semantic color when transparency is reduced.
struct TokenBarSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Rectangle().fill(.bar)
            }
        }
        .ignoresSafeArea()
    }
}

struct TokenBarCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = TokenBarStyle.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .foregroundStyle(TokenBarStyle.foreground)
            .background(
                TokenBarStyle.surface,
                in: RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
                    .stroke(TokenBarStyle.line, lineWidth: 1)
            )
    }
}

typealias TokenBarGlassCard = TokenBarCard

/// Brand mark used in the sidebar hero, popover hero, settings preview, and
/// anywhere else the product needs to identify itself. The geometry, palette,
/// and corner-cursor are kept in lockstep with the macOS app icon
/// (`Assets.xcassets/AppIcon.appiconset` rendered by `script/render_app_icon.swift`)
/// and with the design canvas (`docs/design-prd/tokenbar/shell.jsx` TBMark).
struct TokenBarBrandGlyph: View {
    var size: CGFloat = 30
    /// Legacy parameter retained for source-compat with existing call-sites.
    /// The mark always draws its own ink panel; toggling this is now a no-op.
    var boxed: Bool = true

    // Brand palette — fixed hex (does NOT adapt to system appearance) so the
    // mark looks identical on light and dark surfaces, per BrandMarkBoard.
    private static let inkTop = Color(red: 24/255, green: 49/255, blue: 61/255)    // #18313D
    private static let inkBot = Color(red: 11/255, green: 26/255, blue: 34/255)    // #0B1A22
    private static let teal   = Color(red: 34/255, green:199/255, blue:198/255)    // #22C7C6
    private static let lime   = Color(red:212/255, green:247/255, blue:106/255)    // #D4F76A
    private static let tealDk = Color(red: 31/255, green:138/255, blue:138/255)    // #1F8A8A

    var body: some View {
        // Ratios pulled from .tb-mark CSS (30px reference): radius 8/30,
        // inner glyph 18/30, cursor 2×5 with 5,5 inset.
        let cornerR     = size * (8.0 / 30.0)
        let glyphSide   = size * (18.0 / 30.0)
        let cursorW     = max(1.5, size * (2.0 / 30.0))
        let cursorH     = max(3.5, size * (5.0 / 30.0))
        let cursorInset = size * (5.0 / 30.0)
        // 1.05s period, 2-step blink — matches @keyframes tbMarkBlink.
        let period: TimeInterval = 1.05

        ZStack {
            // 1. Ink gradient base.
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Self.inkTop, Self.inkBot],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 2. Soft lime radial highlight at lower-right (CSS
            //    `radial-gradient(140% 90% at 70% 110%, rgba(212,247,106,0.18))`).
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Self.lime.opacity(0.18),
                            Color.clear
                        ]),
                        center: UnitPoint(x: 0.70, y: 1.10),
                        startRadius: 0,
                        endRadius: size * 0.95
                    )
                )

            // 3. Inner 1px stroke (glass affordance).
            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)

            // 4. 3-bar histogram glyph — same proportions as the app icon.
            TokenBarBrandBars(size: glyphSide, top: Self.teal, mid: Self.lime, bot: Self.tealDk)

            // 5. Lime "cursor" blink, bottom-right corner.
            TimelineView(.periodic(from: .now, by: period / 2)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let isOn = Int((elapsed / (period / 2)).rounded(.down)) % 2 == 0
                RoundedRectangle(cornerRadius: cursorW * 0.25, style: .continuous)
                    .fill(Self.lime)
                    .frame(width: cursorW, height: cursorH)
                    .shadow(color: Self.lime.opacity(0.55), radius: max(1.5, size * 0.10))
                    .opacity(isOn ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, cursorInset)
                    .padding(.bottom, cursorInset)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.18, x: 0, y: size * 0.12)
        // Keep `boxed` referenced so the parameter is not flagged as unused.
        .opacity(boxed ? 1 : 1)
    }
}

private struct TokenBarBrandBars: View {
    let size: CGFloat
    let top: Color
    let mid: Color
    let bot: Color

    var body: some View {
        // Glyph SVG viewBox = 16; rows at y = 3.5 / 6.95 / 10.4 with h = 2.1.
        // Bar widths 6 / 10 / 7.5 → ratios 0.60 / 1.00 / 0.75.
        let unit = size / 16
        let barH = 2.1 * unit
        let radius = 0.6 * unit
        let gap = 1.35 * unit

        VStack(alignment: .leading, spacing: gap) {
            bar(width: 6.0 * unit, height: barH, radius: radius, color: top)
            bar(width: 10.0 * unit, height: barH, radius: radius, color: mid)
            bar(width: 7.5 * unit, height: barH, radius: radius, color: bot)
        }
        .frame(width: size, height: size)
    }

    private func bar(width: CGFloat, height: CGFloat, radius: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }
}

struct TokenBarStatusGlyph: View {
    let state: RefreshState
    var paused = false

    var body: some View {
        // Bar widths come from docs/design-prd/tokenbar/menubar.jsx
        // (viewBox 16: top 5.5, mid 9, bot 7) so the ordering — top shortest,
        // mid longest, bot medium — matches the app icon and brand mark.
        VStack(spacing: 1.6) {
            bar(width: 5.5, color: TokenBarStyle.muted)
            bar(width: 9, color: middleColor)
            bar(width: 7, color: TokenBarStyle.muted)
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .topTrailing) {
            // CL-P0-005: failed → 4×4 red dot with 1.5px menubar-tinted stroke.
            // Stale → 4×4 amber dot (CL-P1-024 hardens the stroke separately).
            if state == .failed || state == .stale {
                Circle()
                    .fill(state == .failed ? TokenBarStyle.error : TokenBarStyle.warn)
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .offset(x: 2, y: -1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // CL-P0-003: paused indicator moved from a center capsule overlay
            // to two thin vertical lines at bottom-right (the design-canvas
            // "❘❘" mark). Tinted with `warn` so it reads clearly on both light
            // and dark menubars.
            if paused {
                HStack(spacing: 1) {
                    Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                    Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                }
                .offset(x: 2, y: 1)
            }
        }
    }

    private var middleColor: Color {
        switch state {
        case .idle:
            TokenBarStyle.lime
        case .refreshing:
            TokenBarStyle.accent
        case .stale:
            TokenBarStyle.warn
        case .failed:
            TokenBarStyle.error
        }
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.1, style: .continuous)
            .fill(color)
            .frame(width: width, height: 2.1)
    }
}

/// CL-P0-001: programmatic NSStatusBar template image. Pure-black 3-bar glyph
/// flagged `isTemplate = true` so macOS auto-tints it for the active menubar
/// appearance (works under wallpaper-tinted, dark, Reduce Transparency, and
/// Increase Contrast environments without per-state PDFs from design).
enum TokenBarMenuBarGlyphImage {
    static func template(size: CGFloat = 16) -> NSImage {
        let pixelSize = NSSize(width: size, height: size)
        let image = NSImage(size: pixelSize, flipped: false) { rect in
            NSColor.black.setFill()
            // viewBox 16 → top 5.5, mid 9, bot 7 (menubar.jsx). Ordering
            // (top shortest, mid longest, bot medium) matches the app icon.
            // Bars are left-aligned with a 2.5/16 inset, matching the design.
            let widths: [CGFloat] = [5.5, 9, 7]
            let barHeight: CGFloat = 1.9
            let spacing: CGFloat = 1.55
            let unit = rect.width / 16
            let total = barHeight * unit * 3 + spacing * unit * 2
            let startY = (rect.height - total) / 2
            let leftInset = 2.5 * unit
            for (idx, w) in widths.enumerated() {
                let y = startY + CGFloat(2 - idx) * (barHeight + spacing) * unit
                let path = NSBezierPath(
                    roundedRect: NSRect(
                        x: leftInset,
                        y: y,
                        width: w * unit,
                        height: barHeight * unit
                    ),
                    xRadius: 0.5 * unit,
                    yRadius: 0.5 * unit
                )
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct TokenBarStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
    }
}

struct TokenBarKPI: View {
    let title: String
    let value: String
    let meta: String
    let color: Color
    /// CL-P0-012: optional tap handler. When non-nil, the entire card becomes
    /// a button and a chevron hints at the expansion affordance. Acceptance
    /// notes "再次点击 / Esc / 卡外点击关闭" — callers control state externally.
    var onTap: (() -> Void)? = nil
    var isExpanded: Bool = false
    var preciseValue: Int? = nil
    /// CL-P1-003: when caller passes a status, the big number is tinted only
    /// for L3/L4. Below those thresholds the number stays `labelColor` so the
    /// surface doesn't scream when usage is nominal.
    var status: TokenBarUsageStatus? = nil

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { body(showsChevron: true) }
                    .buttonStyle(.plain)
                    .help("Click to toggle 24h detail")
            } else {
                body(showsChevron: false)
            }
        }
    }

    private func body(showsChevron: Bool) -> some View {
        TokenBarCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TokenBarStyle.muted)
                    Spacer()
                    if showsChevron {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.faint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if let preciseValue {
                            Text(value).tbNumberTooltip(precise: preciseValue, window: meta)
                        } else {
                            Text(value)
                        }
                    }
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(status?.color ?? Color(nsColor: .labelColor))
                    if let symbol = status?.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(status?.color ?? TokenBarStyle.warn)
                    }
                }
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
                    .stroke(TokenBarStyle.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

/// CL-P0-012 / CL-P0-013: thin "drawer" that slides under a clicked KPI to
/// show today · yesterday · 7d-avg comparisons. Kept dependency-light so it
/// can render under either the Overview KPI row or the Popover PopKPI row.
struct TokenBarKPIDetailDrawer: View {
    let title: String
    let today: Int
    let yesterday: Int
    let sevenDayAverage: Int
    let cost: Double?
    var onClose: (() -> Void)? = nil

    var body: some View {
        TokenBarCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(title) detail")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(5)
                                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    detailColumn(label: "Today", value: today, accent: TokenBarStyle.accent)
                    detailColumn(label: "Yesterday", value: yesterday, accent: TokenBarStyle.muted)
                    detailColumn(label: "7d avg", value: sevenDayAverage, accent: TokenBarStyle.cache)
                    if let cost {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cost (today)")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(TokenBarStyle.faint)
                            Text(tokenbarCompactCurrency(cost))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(TokenBarStyle.cost)
                        }
                    }
                    Spacer()
                }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func detailColumn(label: String, value: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(TokenBarStyle.faint)
            Text(tokenbarCompactTokens(value))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .tbNumberTooltip(precise: value, window: label.lowercased())
        }
    }
}

private enum TokenBarBarPart: Equatable {
    case input
    case output
    case cache
}

struct InputOutputCacheBar: View {
    let summary: UsageSummary
    var height: CGFloat = 6
    @State private var hoveredPart: TokenBarBarPart?

    var body: some View {
        Group {
            if summary.totalTokens <= 0 {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(TokenBarStyle.line)
            } else {
                GeometryReader { proxy in
                    let total = summary.totalTokens
                    HStack(spacing: 1) {
                        Rectangle()
                            .fill(TokenBarStyle.input)
                            .frame(width: proxy.size.width * CGFloat(summary.inputTokens) / CGFloat(total))
                            .contentShape(Rectangle())
                            .onHover { hoveredPart = $0 ? .input : (hoveredPart == .input ? nil : hoveredPart) }
                        Rectangle()
                            .fill(TokenBarStyle.output)
                            .frame(width: proxy.size.width * CGFloat(summary.outputTokens) / CGFloat(total))
                            .contentShape(Rectangle())
                            .onHover { hoveredPart = $0 ? .output : (hoveredPart == .output ? nil : hoveredPart) }
                        Rectangle()
                            .fill(TokenBarStyle.cache)
                            .contentShape(Rectangle())
                            .onHover { hoveredPart = $0 ? .cache : (hoveredPart == .cache ? nil : hoveredPart) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            }
        }
        .frame(height: height)
        .background(TokenBarStyle.line, in: RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        .overlay(alignment: .top) {
            if let hoveredPart {
                TokenBarHoverBadge(text: segmentTooltip(hoveredPart), width: 92)
                    .offset(y: -22)
                    .allowsHitTesting(false)
            }
        }
    }

    private func segmentTooltip(_ part: TokenBarBarPart) -> String {
        switch part {
        case .input:
            return "In \(tokenbarCompactTokens(summary.inputTokens))"
        case .output:
            return "Out \(tokenbarCompactTokens(summary.outputTokens))"
        case .cache:
            return "Cache \(tokenbarCompactTokens(summary.cacheTokens))"
        }
    }
}

struct UsageStackedBarChart: View {
    let days: [UsageDay]
    var height: CGFloat = 118
    var promptCounts: [Date: Int] = [:]
    /// CL-P1-008: optional click handler. When non-nil, every bar becomes
    /// clickable and a hover tooltip shows MM-DD · tokens · cost.
    var onSelect: ((UsageDay) -> Void)? = nil
    @State private var hoveredDay: UsageDay?

    var body: some View {
        Group {
            if displayDays.count > 75 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .bottom) {
                            HStack(alignment: .bottom, spacing: 4) {
                                ForEach(displayDays) { day in
                                    dayBar(day)
                                        .frame(width: 9)
                                        .id(day.id)
                                }
                            }
                            .frame(minWidth: CGFloat(displayDays.count) * 13, minHeight: height, alignment: .bottom)

                            PromptCountSparklineOverlay(days: displayDays, promptCounts: promptCounts)
                                .frame(minWidth: CGFloat(displayDays.count) * 13, minHeight: height)
                                .allowsHitTesting(false)
                        }
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        if let last = displayDays.last {
                            proxy.scrollTo(last.id, anchor: .trailing)
                        }
                    }
                    .onChange(of: displayDays.last?.id) { _, last in
                        if let last {
                            proxy.scrollTo(last, anchor: .trailing)
                        }
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(displayDays) { day in
                            dayBar(day)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    PromptCountSparklineOverlay(days: displayDays, promptCounts: promptCounts)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height, alignment: .bottom)
        .overlay(alignment: .top) {
            if let hoveredDay {
                TokenBarHoverBadge(text: dayTooltip(hoveredDay), width: 210)
                    .offset(y: -22)
            }
        }
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }

    private func dayBar(_ day: UsageDay) -> some View {
        let total = max(day.summary.totalTokens, 1)
        return VStack(spacing: 0) {
            Rectangle()
                .fill(TokenBarStyle.output.opacity(0.85))
                .frame(height: segmentHeight(day.summary.outputTokens, total: total))
            Rectangle()
                .fill(TokenBarStyle.input.opacity(0.85))
                .frame(height: segmentHeight(day.summary.inputTokens, total: total))
            Rectangle()
                .fill(TokenBarStyle.cache.opacity(0.90))
                .frame(height: segmentHeight(day.summary.cacheTokens, total: total))
        }
        .frame(height: max(6, height * max(0.06, day.intensity)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .opacity(day.summary.totalTokens > 0 ? 1 : 0.30)
        .contentShape(Rectangle())
        .onHover { hoveredDay = $0 ? day : nil }
        .onTapGesture { onSelect?(day) }
    }

    private func segmentHeight(_ tokens: Int, total: Int) -> CGFloat {
        max(1, CGFloat(tokens) / CGFloat(total) * height)
    }

    private func dayTooltip(_ day: UsageDay) -> String {
        let promptCount = promptCounts[day.date, default: 0]
        if promptCount > 0 {
            return "\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(tokenbarCompactTokens(day.summary.totalTokens)) total · \(promptCount) prompts"
        }
        return "\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(tokenbarCompactTokens(day.summary.totalTokens)) total"
    }
}

private struct PromptCountSparklineOverlay: View {
    let days: [UsageDay]
    let promptCounts: [Date: Int]

    var body: some View {
        if maxPromptCount > 0, days.count > 1 {
            Canvas { context, size in
                var path = Path()
                let count = max(days.count - 1, 1)
                for (index, day) in days.enumerated() {
                    let value = promptCounts[day.date, default: 0]
                    let x = size.width * CGFloat(index) / CGFloat(count)
                    let normalized = CGFloat(value) / CGFloat(maxPromptCount)
                    let y = size.height * (0.82 - normalized * 0.64)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [TokenBarStyle.accent.opacity(0.25), TokenBarStyle.lime.opacity(0.95)]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.5),
                        endPoint: CGPoint(x: size.width, y: size.height * 0.5)
                    ),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
            .opacity(0.92)
        }
    }

    private var maxPromptCount: Int {
        days.map { promptCounts[$0.date, default: 0] }.max() ?? 0
    }
}

struct UsageHeatmapStripView: View {
    let days: [UsageDay]
    let leadingLabel: String
    let trailingLabel: String
    @State private var hoveredDay: UsageDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(leadingLabel)
                Spacer()
                Text(hoverLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.caption2)
            .foregroundStyle(TokenBarStyle.muted)

            if displayDays.count > 75 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 4) {
                            ForEach(displayDays) { day in
                                heatCell(day)
                                    .frame(width: 12)
                                    .id(day.id)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        if let last = displayDays.last {
                            proxy.scrollTo(last.id, anchor: .trailing)
                        }
                    }
                    .onChange(of: displayDays.last?.id) { _, last in
                        if let last {
                            proxy.scrollTo(last, anchor: .trailing)
                        }
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(displayDays) { day in
                        heatCell(day)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }

    private var hoverLabel: String {
        guard let hoveredDay else { return "low · high" }
        return "\(hoveredDay.date.formatted(.dateTime.month(.abbreviated).day())) · \(tokenbarTokens(hoveredDay.summary.totalTokens))"
    }

    private func heatCell(_ day: UsageDay) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(heatColor(day.intensity))
            .frame(height: 16)
            .contentShape(Rectangle())
            .onHover { isHovering in
                hoveredDay = isHovering ? day : nil
            }
    }
}

struct HourlyHeatmapView: View {
    let hours: [UsageHourOfDay]
    var showAxis = true
    @State private var hoveredHour: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer()
                TokenBarHoverBadge(
                    text: hoveredHour.map(hourTooltip) ?? "Hover an hour",
                    width: 180,
                    isPlaceholder: hoveredHour == nil
                )
            }
            .frame(height: 20)
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let item = normalizedHour(hour)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatColor(item?.intensity ?? 0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 15)
                        .overlay {
                            if hoveredHour == hour {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(TokenBarStyle.foreground.opacity(0.85), lineWidth: 1)
                            }
                        }
                        .onHover { hoveredHour = $0 ? hour : nil }
                }
            }
            if showAxis {
                HStack {
                    Text("00")
                    Spacer()
                    Text("06")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("18")
                    Spacer()
                    Text("23")
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            }
        }
    }

    private func normalizedHour(_ hour: Int) -> UsageHourOfDay? {
        hours.first { $0.hourOfDay == hour }
    }

    private func hourTooltip(_ hour: Int) -> String {
        let summary = normalizedHour(hour)?.summary ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)
        return "\(String(format: "%02d:00", hour)) · \(tokenbarCompactTokens(summary.totalTokens)) total"
    }
}

struct TokenBarHoverBadge: View {
    let text: String
    var width: CGFloat = 320
    var isPlaceholder = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .foregroundStyle(isPlaceholder ? TokenBarStyle.faint : TokenBarStyle.foreground)
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(TokenBarStyle.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
    }
}

struct DateRangeControl: View {
    let options: [String] = ["7d", "30d", "90d", "1y", "All", "Custom"]
    @Binding var selection: String
    @State private var showCustomMenu = false
    // CL-P1-011: persist the user's last custom window so reopening the menu
    // shows the previously chosen dates.
    @AppStorage("tokenbar.customRange.from") private var customFrom = "2026-04-15"
    @AppStorage("tokenbar.customRange.to") private var customTo = "2026-05-14"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    if option == "Custom" {
                        showCustomMenu = true
                    } else {
                        selection = option
                        showCustomMenu = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selection == option ? TokenBarStyle.foreground : TokenBarStyle.muted)
                .padding(.horizontal, option == "Custom" ? 9 : 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selection == option ? TokenBarStyle.input.opacity(0.20) : Color.clear)
                )
                .overlay {
                    if selection == option {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(TokenBarStyle.input.opacity(0.25), lineWidth: 1)
                    }
                }
            }
        }
        .padding(3)
        .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        .popover(isPresented: $showCustomMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Range")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Enter ISO dates (yyyy-MM-dd). Charts and tables use the exact inclusive window.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    customField("From", text: $customFrom)
                    customField("To", text: $customTo)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showCustomMenu = false }
                        .controlSize(.small)
                    Button("Apply") {
                        selection = "Custom"
                        showCustomMenu = false
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidDateRange)
                }
            }
            .padding(14)
            .frame(width: 240)
            .background(TokenBarGlassBackground())
        }
    }

    private var isValidDateRange: Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let f = formatter.date(from: customFrom),
              let t = formatter.date(from: customTo) else { return false }
        return f <= t
    }

    private func customField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
    }
}

struct RangeBarsCard: View {
    let days: [UsageDay]
    let title: String
    let subtitle: String
    let summary: UsageSummary
    var promptCounts: [Date: Int] = [:]

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    HeatLegend()
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                        .layoutPriority(2)
                    Spacer(minLength: 8)
                    RangeSummaryInline(summary: summary, promptCount: totalPromptCount)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TokenBarStyle.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(TokenBarStyle.line.opacity(0.85), lineWidth: 1))
                        .layoutPriority(1)
                }
                UsageStackedBarChart(days: days, promptCounts: promptCounts)
                HStack {
                    Text(displayDays.first?.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) ?? "")
                    Spacer()
                    Text(displayDays.count > 75 ? "scroll horizontally · newest on right" : "available local buckets")
                    Spacer()
                    Text(displayDays.last?.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) ?? "")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(TokenBarStyle.faint)
            }
        }
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }

    private var totalPromptCount: Int {
        displayDays.reduce(0) { $0 + promptCounts[$1.date, default: 0] }
    }
}

private struct RangeSummaryInline: View {
    let summary: UsageSummary
    let promptCount: Int

    var body: some View {
        HStack(spacing: 8) {
            metric("Total", tokenbarCompactTokens(summary.totalTokens), TokenBarStyle.foreground)
            metric("In", tokenbarCompactTokens(summary.inputTokens), TokenBarStyle.input)
            metric("Out", tokenbarCompactTokens(summary.outputTokens), TokenBarStyle.output)
            metric("Cache", tokenbarCompactTokens(summary.cacheTokens), TokenBarStyle.cache)
            metric("Prompt", tokenbarCompactTokens(promptCount), TokenBarStyle.lime)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(TokenBarStyle.faint)
            Text(value)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TokenBarPageUpdatingOverlay: View {
    let label: String
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(TokenBarStyle.appBackground.opacity(0.06))

                LinearGradient(
                    colors: [
                        TokenBarStyle.accent.opacity(0),
                        TokenBarStyle.accent.opacity(0.85),
                        TokenBarStyle.lime.opacity(0.85),
                        TokenBarStyle.accent.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(180, proxy.size.width * 0.34), height: 2)
                .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.45)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 11, height: 11)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.foreground)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(TokenBarStyle.surfaceRaised.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
                .padding(.top, 6)
                .padding(.trailing, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .transition(.opacity)
        .onAppear {
            sweep = false
            withAnimation(.linear(duration: 0.72).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("less")
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatColor(Double(level) / 4.0))
                        .frame(width: 11, height: 11)
                }
            }
            Text("more")
        }
        .font(.caption2)
        .foregroundStyle(TokenBarStyle.muted)
    }
}

struct ModelBreakdownTable: View {
    let title: String
    let subtitle: String
    let totalCost: String
    let rows: [TokenBarModelBreakdown]

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Estimated cost")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(TokenBarStyle.faint)
                        Text(totalCost)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenBarStyle.cost)
                            .monospacedDigit()
                    }
                }

                tableHeader
                if rows.isEmpty {
                    Text("No model attribution available from the current local index.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rows.prefix(8)) { row in
                        ModelBreakdownRow(row: row)
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 14) {
            Text("Model").frame(width: 230, alignment: .leading)
            Text("Input · Output · Cache").frame(maxWidth: .infinity, alignment: .leading)
            Text("Cache %").frame(width: 72, alignment: .trailing)
            Text("Tokens").frame(width: 92, alignment: .trailing)
            Text("Cost").frame(width: 82, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(TokenBarStyle.faint)
        .padding(.bottom, 6)
        .overlay(Divider().overlay(TokenBarStyle.line), alignment: .bottom)
    }
}

private struct ModelBreakdownRow: View {
    let row: TokenBarModelBreakdown

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Circle()
                    .fill(TokenBarStyle.agentColor(row.agentName))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(row.attribution)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }
            }
            .frame(width: 230, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                InputOutputCacheBar(summary: row.summary, height: 8)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    Text("in \(tokenbarCompactTokens(row.summary.inputTokens))")
                    Text("out \(tokenbarCompactTokens(row.summary.outputTokens))")
                    Text("cache \(tokenbarCompactTokens(row.summary.cacheTokens))")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(tokenbarPercent(row.cacheRatio))
                .font(.caption)
                .foregroundStyle(TokenBarStyle.cache)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(TokenBarStyle.cache.opacity(0.10), in: Capsule())
                .frame(width: 72, alignment: .trailing)
                .help("Cache \(row.summary.cacheTokens.formatted()) of \(row.summary.totalTokens.formatted()) tokens")

            Text(tokenbarCompactTokens(row.summary.totalTokens))
                .font(.system(size: 12.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenBarStyle.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 92, alignment: .trailing)
                .tbNumberTooltip(precise: row.summary.totalTokens, window: row.name)

            VStack(alignment: .trailing, spacing: 2) {
                Text(tokenbarCompactCurrency(row.cost))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenBarStyle.cost)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                    .tbNumberTooltip(precise: row.cost, window: row.name)
                Text(tokenbarPercent(row.percentage))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
    }
}

struct TokenBarDonut: View {
    let slices: [AgentShareSlice]
    // CL-P1-015: when a segment is hovered the other segments fade to 0.6 and
    // a tooltip shows agent + pct. Plain SwiftUI hit-testing on a Circle's
    // stroked arc is coarse, so we attach `.help` to a transparent overlay
    // per slice — a fine compromise without a custom Canvas drawing layer.
    @State private var hoveredAgent: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(TokenBarStyle.line, lineWidth: 14)
            ForEach(Array(slices.prefix(5).enumerated()), id: \.element.id) { index, slice in
                Circle()
                    .trim(from: trimStart(index), to: trimEnd(index))
                    .stroke(TokenBarStyle.agentColor(slice.name),
                            style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(hoveredAgent == nil || hoveredAgent == slice.name ? 1.0 : 0.6)
                    .onHover { isHovering in
                        hoveredAgent = isHovering ? slice.name : (hoveredAgent == slice.name ? nil : hoveredAgent)
                    }
                    .help("\(slice.name) · \(tokenbarPercent(slice.percentage))")
            }
            VStack(spacing: 1) {
                Text(tokenbarTokens(slices.reduce(0) { $0 + $1.totalTokens }))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(hoveredAgent ?? "tokens")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
        }
    }

    private var total: Double {
        max(Double(slices.reduce(0) { $0 + $1.totalTokens }), 1)
    }

    private func trimStart(_ index: Int) -> Double {
        slices.prefix(index).reduce(0) { $0 + Double($1.totalTokens) / total }
    }

    private func trimEnd(_ index: Int) -> Double {
        slices.prefix(index + 1).reduce(0) { $0 + Double($1.totalTokens) / total }
    }
}

// CL-P1-002: replace the bespoke 5-step gradient with alpha-tinted
// systemGreen. Empty cells use `quaternaryLabelColor` so they read as
// "no signal" instead of a faint green.
private func heatColor(_ intensity: Double) -> Color {
    switch intensity {
    case ..<0.08:
        TokenBarStyle.line.opacity(0.58)
    case ..<0.28:
        TokenBarStyle.cache.opacity(0.28)
    case ..<0.55:
        TokenBarStyle.cache.opacity(0.50)
    case ..<0.82:
        TokenBarStyle.cache.opacity(0.72)
    default:
        TokenBarStyle.cache.opacity(0.95)
    }
}

private extension UsageDay {
    static func placeholder(count: Int) -> [UsageDay] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else { return nil }
            return UsageDay(date: date, summary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0), intensity: 0)
        }
    }
}
