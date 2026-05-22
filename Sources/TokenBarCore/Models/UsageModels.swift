import Foundation

public enum AgentKind: String, CaseIterable, Sendable, Hashable {
    case codex
    case claudeCode
    case geminiCLI
    case hermes
    case custom

    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claudeCode:
            "Claude Code"
        case .geminiCLI:
            "Gemini CLI"
        case .hermes:
            "Hermes"
        case .custom:
            "Custom"
        }
    }

    public var defaultCostPerMillionTokens: Double {
        switch self {
        case .codex:
            4.46
        case .claudeCode:
            2.15
        case .geminiCLI:
            0.50
        case .hermes:
            0.15
        case .custom:
            0.15
        }
    }
}

public enum ParserKind: String, Sendable, Hashable {
    case codex
    case claudeCode
    case hermes
    case sample
    case custom
}

public enum CustomSourceFormat: String, CaseIterable, Sendable, Hashable {
    case claudeCodeJSONL = "claude_code_jsonl"
    case codexJSONL = "codex_jsonl"
    case auto
    case unknown

    public var displayName: String {
        switch self {
        case .claudeCodeJSONL:
            "Claude Code JSONL"
        case .codexJSONL:
            "Codex JSONL"
        case .auto:
            "Auto"
        case .unknown:
            "Unknown"
        }
    }
}

public enum CustomSourceEngine: String, CaseIterable, Sendable, Hashable, Codable {
    case claudeCode
    case codex
    case hermes

    public var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        case .hermes:
            "Hermes"
        }
    }

    public var defaultGlobPattern: String {
        switch self {
        case .claudeCode:
            "**/*.jsonl"
        case .codex:
            "**/rollout-*.jsonl"
        case .hermes:
            "state.db"
        }
    }

    public var agentKind: AgentKind {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .hermes:
            .hermes
        }
    }

    public var parserKind: ParserKind {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .hermes:
            .hermes
        }
    }
}

public struct UsageSummary: Sendable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }

    public var focus: UsageFocus {
        UsageFocus(summary: self)
    }

    public init(inputTokens: Int, outputTokens: Int, cacheTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
    }
}

public struct UsageFocus: Sendable, Hashable {
    public let inputShare: Double
    public let outputShare: Double
    public let cacheShare: Double

    public var dominantDimension: String {
        if inputShare == 0 && outputShare == 0 && cacheShare == 0 {
            return "Unknown"
        }
        if inputShare >= outputShare && inputShare >= cacheShare {
            return "Input"
        }
        if outputShare >= inputShare && outputShare >= cacheShare {
            return "Output"
        }
        return "Cache"
    }

    public init(summary: UsageSummary) {
        let total = Double(summary.totalTokens)
        guard total > 0 else {
            self = .zero
            return
        }
        self = Self(
            inputShare: Double(summary.inputTokens) / total,
            outputShare: Double(summary.outputTokens) / total,
            cacheShare: Double(summary.cacheTokens) / total
        )
    }

    public init(inputShare: Double, outputShare: Double, cacheShare: Double) {
        self.inputShare = inputShare
        self.outputShare = outputShare
        self.cacheShare = cacheShare
    }

    public static let zero = UsageFocus(inputShare: 0, outputShare: 0, cacheShare: 0)
}

public struct UsageCostBreakdown: Identifiable, Sendable, Hashable {
    public let name: String
    public let totalTokens: Int
    public let cost: Double
    public let percentage: Double

    public var id: String { name }

    public init(name: String, totalTokens: Int, cost: Double, percentage: Double) {
        self.name = name
        self.totalTokens = totalTokens
        self.cost = cost
        self.percentage = percentage
    }
}

public struct UsageCostProjection: Sendable, Hashable {
    public let totalCost: Double
    public let blendedRatePerMillion: Double
    public let byAgent: [UsageCostBreakdown]

    public var totalTokens: Int {
        byAgent.reduce(0) { $0 + $1.totalTokens }
    }

    public init(totalCost: Double, blendedRatePerMillion: Double, byAgent: [UsageCostBreakdown]) {
        self.totalCost = totalCost
        self.blendedRatePerMillion = blendedRatePerMillion
        self.byAgent = byAgent
    }

    public static let zero = UsageCostProjection(
        totalCost: 0,
        blendedRatePerMillion: 0,
        byAgent: []
    )
}

public struct UsageBreakdown: Identifiable, Sendable, Hashable {
    public let name: String
    public let summary: UsageSummary

    public var id: String { name }

    public init(name: String, summary: UsageSummary) {
        self.name = name
        self.summary = summary
    }
}

public struct UsageEventTimeBounds: Sendable, Hashable {
    public let earliest: Date?
    public let latest: Date?
    public let eventCount: Int

    public init(earliest: Date?, latest: Date?, eventCount: Int) {
        self.earliest = earliest
        self.latest = latest
        self.eventCount = eventCount
    }
}

public struct UsageRangeAggregateRow: Sendable, Hashable {
    public let projectName: String
    public let agent: AgentKind
    public let modelName: String?
    public let summary: UsageSummary

    public init(projectName: String, agent: AgentKind, modelName: String?, summary: UsageSummary) {
        self.projectName = projectName
        self.agent = agent
        self.modelName = modelName
        self.summary = summary
    }
}

public struct UsageRangeAggregate: Sendable, Hashable {
    public let start: Date
    public let end: Date
    public let days: [UsageDay]
    public let rows: [UsageRangeAggregateRow]

    public var summary: UsageSummary {
        rows.reduce(UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0)) { total, row in
            UsageSummary(
                inputTokens: total.inputTokens + row.summary.inputTokens,
                outputTokens: total.outputTokens + row.summary.outputTokens,
                cacheTokens: total.cacheTokens + row.summary.cacheTokens
            )
        }
    }

    public init(start: Date, end: Date, days: [UsageDay], rows: [UsageRangeAggregateRow]) {
        self.start = start
        self.end = end
        self.days = days
        self.rows = rows
    }
}

public struct UsageHour: Identifiable, Sendable, Hashable {
    public let start: Date
    public let hourOfDay: Int
    public let eventCount: Int
    public let summary: UsageSummary
    public let intensity: Double

    public var id: Date { start }

    public init(
        start: Date,
        hourOfDay: Int,
        eventCount: Int,
        summary: UsageSummary,
        intensity: Double
    ) {
        self.start = start
        self.hourOfDay = hourOfDay
        self.eventCount = eventCount
        self.summary = summary
        self.intensity = intensity
    }
}

public struct UsageHourOfDay: Identifiable, Sendable, Hashable {
    public let hourOfDay: Int
    public let eventCount: Int
    public let activeHourCount: Int
    public let summary: UsageSummary
    public let intensity: Double

    public var id: Int { hourOfDay }

    public init(
        hourOfDay: Int,
        eventCount: Int,
        activeHourCount: Int,
        summary: UsageSummary,
        intensity: Double
    ) {
        self.hourOfDay = hourOfDay
        self.eventCount = eventCount
        self.activeHourCount = activeHourCount
        self.summary = summary
        self.intensity = intensity
    }
}

public struct HourlyUsageSnapshot: Sendable, Hashable {
    public let generatedAt: Date
    public let summary: UsageSummary
    public let eventCount: Int
    public let hours: [UsageHour]
    public let hoursOfDay: [UsageHourOfDay]
    public let peakHour: UsageHour?
    public let peakHourOfDay: UsageHourOfDay?

    public init(
        generatedAt: Date,
        summary: UsageSummary,
        eventCount: Int,
        hours: [UsageHour],
        hoursOfDay: [UsageHourOfDay],
        peakHour: UsageHour?,
        peakHourOfDay: UsageHourOfDay?
    ) {
        self.generatedAt = generatedAt
        self.summary = summary
        self.eventCount = eventCount
        self.hours = hours
        self.hoursOfDay = hoursOfDay
        self.peakHour = peakHour
        self.peakHourOfDay = peakHourOfDay
    }
}

public struct AgentShareSlice: Identifiable, Sendable, Hashable {
    public let name: String
    public let totalTokens: Int
    public let percentage: Double

    public var id: String { name }

    public init(name: String, totalTokens: Int, percentage: Double) {
        self.name = name
        self.totalTokens = totalTokens
        self.percentage = percentage
    }
}

public struct UsageEvent: Identifiable, Sendable, Hashable {
    public let id: String
    public let agent: AgentKind
    public let projectPath: String?
    public let projectName: String
    public let sessionId: String
    public let timestamp: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let reasoningTokens: Int?
    public let modelName: String?
    public let sourcePath: String
    public let parser: ParserKind
    public let confidence: Double

    public init(
        id: String,
        agent: AgentKind,
        projectPath: String?,
        projectName: String,
        sessionId: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        reasoningTokens: Int?,
        modelName: String? = nil,
        sourcePath: String,
        parser: ParserKind,
        confidence: Double
    ) {
        self.id = id
        self.agent = agent
        self.projectPath = projectPath
        self.projectName = projectName
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.reasoningTokens = reasoningTokens
        self.modelName = modelName
        self.sourcePath = sourcePath
        self.parser = parser
        self.confidence = confidence
    }
}

public struct PromptRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let eventId: String?
    public let agent: AgentKind
    public let projectName: String
    public let sessionId: String
    public let timestamp: Date
    public let content: String
    public let contentHash: String
    public let sourcePath: String

    public init(
        id: String,
        eventId: String?,
        agent: AgentKind,
        projectName: String,
        sessionId: String,
        timestamp: Date,
        content: String,
        contentHash: String,
        sourcePath: String
    ) {
        self.id = id
        self.eventId = eventId
        self.agent = agent
        self.projectName = projectName
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.content = content
        self.contentHash = contentHash
        self.sourcePath = sourcePath
    }
}

public enum PromptHistoryKindFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case human
    case subagent
    case command
}

public struct PromptHistoryKindCounts: Sendable, Hashable {
    public let humanCount: Int
    public let subagentCount: Int
    public let commandCount: Int

    public var totalCount: Int {
        humanCount + subagentCount + commandCount
    }

    public init(humanCount: Int, subagentCount: Int, commandCount: Int) {
        self.humanCount = humanCount
        self.subagentCount = subagentCount
        self.commandCount = commandCount
    }

    public static let zero = PromptHistoryKindCounts(humanCount: 0, subagentCount: 0, commandCount: 0)
}

public struct PromptHistoryPage: Sendable, Hashable {
    public let prompts: [PromptRecord]
    public let totalCount: Int
    public let kindCounts: PromptHistoryKindCounts
    public let limit: Int
    public let offset: Int

    public init(
        prompts: [PromptRecord],
        totalCount: Int,
        kindCounts: PromptHistoryKindCounts,
        limit: Int,
        offset: Int
    ) {
        self.prompts = prompts
        self.totalCount = totalCount
        self.kindCounts = kindCounts
        self.limit = limit
        self.offset = offset
    }

    public static func empty(limit: Int, offset: Int) -> PromptHistoryPage {
        PromptHistoryPage(prompts: [], totalCount: 0, kindCounts: .zero, limit: limit, offset: offset)
    }
}

public struct CheckpointSummary: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let startedAt: Date
    public let endedAt: Date?
    public let trigger: String
    public let eventsAdded: Int
    public let promptsAdded: Int
    public let warnings: Int
    public let error: String?

    public init(
        id: Int64,
        startedAt: Date,
        endedAt: Date?,
        trigger: String,
        eventsAdded: Int,
        promptsAdded: Int,
        warnings: Int,
        error: String?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trigger = trigger
        self.eventsAdded = eventsAdded
        self.promptsAdded = promptsAdded
        self.warnings = warnings
        self.error = error
    }
}

public struct CustomSourceRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var engine: CustomSourceEngine
    public var directory: String
    public var globPattern: String
    public var format: CustomSourceFormat
    public var displayAgent: String
    public var enabled: Bool
    public var fieldMapping: CustomSourceFieldMapping
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        engine: CustomSourceEngine = .claudeCode,
        directory: String,
        globPattern: String = "**/*.jsonl",
        format: CustomSourceFormat = .auto,
        displayAgent: String = "Custom",
        enabled: Bool = true,
        fieldMapping: CustomSourceFieldMapping = .default,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.directory = directory
        self.globPattern = globPattern
        self.format = format
        self.displayAgent = displayAgent
        self.enabled = enabled
        self.fieldMapping = fieldMapping
        self.createdAt = createdAt
    }
}

public extension CustomSourceRecord {
    var sourcePathKey: String {
        Self.sourcePathKey(directory: directory, globPattern: globPattern)
    }

    static func sourcePathKey(directory: String, globPattern: String) -> String {
        "\(normalizedSourceDirectory(directory))|\(normalizedSourceGlob(globPattern))"
    }

    static func normalizedSourceDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "." }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized: String
        if expanded.hasPrefix("/") {
            standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        } else {
            standardized = (expanded as NSString).standardizingPath
        }
        guard standardized.count > 1 else { return standardized }
        return String(standardized.dropLast(standardized.hasSuffix("/") ? 1 : 0))
    }

    static func normalizedSourceGlob(_ globPattern: String) -> String {
        var normalized = globPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }
}

public struct CustomSourceFieldMapping: Sendable, Hashable, Codable {
    public var inputTokens: String
    public var outputTokens: String
    public var cacheTokens: String
    public var model: String

    public init(
        inputTokens: String,
        outputTokens: String,
        cacheTokens: String,
        model: String
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.model = model
    }

    public static let `default` = CustomSourceFieldMapping(
        inputTokens: "usage.input_tokens",
        outputTokens: "usage.output_tokens",
        cacheTokens: "usage.cache_read_tokens",
        model: "model"
    )
}

public struct SourceWatermark: Sendable, Hashable {
    public let sourcePath: String
    public let agent: AgentKind
    public let lastMtime: Date
    public let lastByteOffset: Int64
    public let lastEventId: String?
    public let lastInode: UInt64?
    public let updatedAt: Date

    public init(
        sourcePath: String,
        agent: AgentKind,
        lastMtime: Date,
        lastByteOffset: Int64,
        lastEventId: String?,
        lastInode: UInt64?,
        updatedAt: Date
    ) {
        self.sourcePath = sourcePath
        self.agent = agent
        self.lastMtime = lastMtime
        self.lastByteOffset = lastByteOffset
        self.lastEventId = lastEventId
        self.lastInode = lastInode
        self.updatedAt = updatedAt
    }
}

public struct UsageDay: Identifiable, Sendable, Hashable {
    public let date: Date
    public let summary: UsageSummary
    public let intensity: Double

    public var id: Date { date }

    public init(date: Date, summary: UsageSummary, intensity: Double) {
        self.date = date
        self.summary = summary
        self.intensity = intensity
    }
}

public struct UsageSnapshot: Sendable, Hashable {
    public let generatedAt: Date
    public let today: UsageSummary
    public let last30Days: [UsageDay]
    public let topAgentsToday: [UsageBreakdown]
    public let topProjectsToday: [UsageBreakdown]
    public let topAgents: [UsageBreakdown]
    public let topProjects: [UsageBreakdown]
    public let focusToday: UsageFocus
    public let focusLast30: UsageFocus
    public let activeDays: Int
    public let peakDay: Date?
    public let estimatedCostToday: UsageCostProjection
    public let estimatedCostLast30: UsageCostProjection
    public let warningCount: Int

    public var last30Summary: UsageSummary {
        UsageSummary(
            inputTokens: last30Days.reduce(0) { $0 + $1.summary.inputTokens },
            outputTokens: last30Days.reduce(0) { $0 + $1.summary.outputTokens },
            cacheTokens: last30Days.reduce(0) { $0 + $1.summary.cacheTokens }
        )
    }

    public init(
        generatedAt: Date,
        today: UsageSummary,
        last30Days: [UsageDay],
        topAgentsToday: [UsageBreakdown],
        topProjectsToday: [UsageBreakdown],
        topAgents: [UsageBreakdown],
        topProjects: [UsageBreakdown],
        focusToday: UsageFocus = .zero,
        focusLast30: UsageFocus = .zero,
        activeDays: Int = 0,
        peakDay: Date? = nil,
        estimatedCostToday: UsageCostProjection = .zero,
        estimatedCostLast30: UsageCostProjection = .zero,
        warningCount: Int = 0
    ) {
        self.generatedAt = generatedAt
        self.today = today
        self.last30Days = last30Days
        self.topAgentsToday = topAgentsToday
        self.topProjectsToday = topProjectsToday
        self.topAgents = topAgents
        self.topProjects = topProjects
        self.focusToday = focusToday
        self.focusLast30 = focusLast30
        self.activeDays = activeDays
        self.peakDay = peakDay
        self.estimatedCostToday = estimatedCostToday
        self.estimatedCostLast30 = estimatedCostLast30
        self.warningCount = warningCount
    }

    /// Return a copy with `warningCount` replaced. Used by UsageStore so that
    /// snapshot is the single source of truth for warning counters (CL-P0-022).
    public func with(warningCount: Int) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: generatedAt,
            today: today,
            last30Days: last30Days,
            topAgentsToday: topAgentsToday,
            topProjectsToday: topProjectsToday,
            topAgents: topAgents,
            topProjects: topProjects,
            focusToday: focusToday,
            focusLast30: focusLast30,
            activeDays: activeDays,
            peakDay: peakDay,
            estimatedCostToday: estimatedCostToday,
            estimatedCostLast30: estimatedCostLast30,
            warningCount: warningCount
        )
    }
}

public struct ProjectSessionSummary: Identifiable, Sendable, Hashable {
    public let sessionId: String
    public let agentName: String
    public let timestamp: Date
    public let summary: UsageSummary

    public var id: String { sessionId }

    public init(sessionId: String, agentName: String, timestamp: Date, summary: UsageSummary) {
        self.sessionId = sessionId
        self.agentName = agentName
        self.timestamp = timestamp
        self.summary = summary
    }
}

public struct ProjectDetailSnapshot: Sendable, Hashable {
    public let projectName: String
    public let summary: UsageSummary
    public let last30Days: [UsageDay]
    public let agentShare: [AgentShareSlice]
    public let recentSessions: [ProjectSessionSummary]
    public let focus: UsageFocus
    public let activeDays: Int
    public let peakDay: Date?
    public let estimatedCost: UsageCostProjection
    public let warningCount: Int

    public init(
        projectName: String,
        summary: UsageSummary,
        last30Days: [UsageDay],
        agentShare: [AgentShareSlice],
        recentSessions: [ProjectSessionSummary],
        focus: UsageFocus = .zero,
        activeDays: Int = 0,
        peakDay: Date? = nil,
        estimatedCost: UsageCostProjection = .zero,
        warningCount: Int = 0
    ) {
        self.projectName = projectName
        self.summary = summary
        self.last30Days = last30Days
        self.agentShare = agentShare
        self.recentSessions = recentSessions
        self.focus = focus
        self.activeDays = activeDays
        self.peakDay = peakDay
        self.estimatedCost = estimatedCost
        self.warningCount = warningCount
    }
}
