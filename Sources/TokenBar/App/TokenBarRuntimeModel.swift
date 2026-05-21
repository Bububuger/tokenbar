import AppKit
import Foundation
import TokenBarCore

@MainActor
final class TokenBarRuntimeModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var diagnostics: DiagnosticsSnapshot
    @Published private(set) var prompts: [PromptRecord]
    @Published private(set) var lastCheckpoint: CheckpointSummary?
    @Published private(set) var refreshState: RefreshState
    @Published private(set) var selectedProjectName: String?
    @Published private(set) var projectDetail: ProjectDetailSnapshot?
    @Published private(set) var customSources: [CustomSourceRecord]
    @Published private(set) var events: [UsageEvent]
    @Published var mainRoute: TokenBarMainRoute = .today

    @Published var refreshInterval: RefreshIntervalOption {
        didSet { settingsStore.refreshInterval = refreshInterval }
    }

    @Published var keepDataOnThisMac: Bool {
        didSet { settingsStore.keepDataOnThisMac = keepDataOnThisMac }
    }

    @Published var storePromptTextInClearText: Bool {
        didSet { settingsStore.storePromptTextInClearText = storePromptTextInClearText }
    }

    @Published var usePromptFingerprintsByDefault: Bool {
        didSet { settingsStore.usePromptFingerprintsByDefault = usePromptFingerprintsByDefault }
    }

    @Published var retentionWindow: String {
        didSet {
            settingsStore.retentionWindow = retentionWindow
            Task { await applyRetentionAndReload(referenceDate: Date()) }
        }
    }

    private let settingsStore: SettingsStore
    private let usageStore: UsageStore
    private let builtInSources: [any InspectableUsageEventSource]
    private var fileWatcher: RecursiveFSEventsWatcher?
    private var checkpointEngine: CheckpointEngine?
    private var checkpointSourceSignature = ""
    private var hasBootstrapped = false
    // CL-P0-026: scheduled to fire just after local midnight so the Today KPI
    // resets, the 30d strip shifts, and the Popover briefly shows a "Day
    // changed — refreshing…" hint. `dayChangedAt` is published so views can
    // observe it and animate a transient banner.
    private var midnightTask: Task<Void, Never>?
    @Published private(set) var dayChangedAt: Date?

    init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        sources: [any InspectableUsageEventSource]
    ) {
        self.settingsStore = settingsStore
        self.usageStore = usageStore
        self.builtInSources = sources
        self.snapshot = UsageAggregator.makeSnapshot(from: [])
        self.customSources = []
        self.refreshInterval = settingsStore.refreshInterval
        self.keepDataOnThisMac = settingsStore.keepDataOnThisMac
        self.storePromptTextInClearText = settingsStore.storePromptTextInClearText
        self.usePromptFingerprintsByDefault = settingsStore.usePromptFingerprintsByDefault
        self.retentionWindow = settingsStore.retentionWindow
        self.refreshState = .idle
        self.selectedProjectName = nil
        self.projectDetail = nil
        self.prompts = []
        self.lastCheckpoint = nil
        self.events = []
        self.diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: [],
            lastIndexedAt: nil,
            lastUIRefreshAt: nil,
            parserWarningCount: 0,
            refreshState: .idle,
            rebuildError: nil
        )

        Task { [weak self] in
            await self?.bootstrapIfNeeded()
        }
    }

    func bootstrapIfNeeded() async {
        TokenBarSignpost.event("bootstrap-start")
        defer { TokenBarSignpost.event("bootstrap-end") }
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await loadPersistedSnapshot()
        await refresh()
        await restartFileWatcher()
        scheduleNextMidnightRollover()
        observeSystemPowerEvents()
    }

    /// CL-P1-036: after a sleep/wake cycle, trigger a refresh so the menubar
    /// briefly enters stale → idle instead of showing stale data for an hour.
    private func observeSystemPowerEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// CL-P0-026: schedule a refresh just after the next local midnight tick.
    /// The task is recreated on every midnight so daylight-savings adjustments
    /// don't compound drift.
    private func scheduleNextMidnightRollover() {
        midnightTask?.cancel()
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return }
        // Fire 0.5s after the new day starts so any pending file writes settle.
        let firingDate = tomorrowStart.addingTimeInterval(0.5)
        let delay = firingDate.timeIntervalSince(now)
        guard delay > 0 else { return }
        midnightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.dayChangedAt = Date()
            }
            await self.refresh()
            await MainActor.run {
                self.scheduleNextMidnightRollover()
            }
        }
    }

    private func loadPersistedSnapshot() async {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        customSources = await loadCustomSources()
        await applyRetention(referenceDate: now)
        let state = await usageStore.state(referenceDate: now, calendar: calendar)
        events = state.events
        prompts = state.prompts
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if selectedProjectName == nil {
            selectedProjectName = state.snapshot.topProjects.first?.name
        }

        projectDetail = selectedProjectName.flatMap {
            UsageAggregator.makeProjectDetail(
                projectName: $0,
                from: state.events,
                referenceDate: now,
                calendar: calendar
            )
        }

        let nextRefreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: state.lastIndexedAt,
            lastRebuildError: state.lastRebuildError,
            refreshInterval: refreshInterval
        )

        diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: [],
            lastIndexedAt: state.lastIndexedAt,
            lastUIRefreshAt: now,
            lastCheckpointID: state.lastCheckpoint?.id,
            lastCheckpointEventsAdded: state.lastCheckpoint?.eventsAdded ?? 0,
            lastCheckpointPromptsAdded: state.lastCheckpoint?.promptsAdded ?? 0,
            parserWarningCount: state.warnings.count,
            refreshState: nextRefreshState,
            rebuildError: state.lastRebuildError
        )
        refreshState = nextRefreshState
    }

    func refresh() async {
        TokenBarSignpost.event("refresh-start")
        defer { TokenBarSignpost.event("refresh-end") }
        refreshState = .refreshing
        let now = Date()
        customSources = await loadCustomSources()
        let sources = await activeSources()
        let engine = checkpointEngine(for: sources)
        _ = await engine.run(trigger: "refresh", startedAt: now, referenceDate: now, calendar: Calendar(identifier: .gregorian))
        await applyRetention(referenceDate: now)
        let state = await usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian))
        let statuses = await collectStatuses(sources: sources, referenceDate: now)

        events = state.events
        prompts = state.prompts
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if selectedProjectName == nil {
            selectedProjectName = state.snapshot.topProjects.first?.name
        }
        projectDetail = selectedProjectName.flatMap {
            UsageAggregator.makeProjectDetail(
                projectName: $0,
                from: state.events,
                referenceDate: now,
                calendar: Calendar(identifier: .gregorian)
            )
        }
        refreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: state.lastIndexedAt,
            lastRebuildError: state.lastRebuildError,
            refreshInterval: refreshInterval
        )
        diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: statuses,
            lastIndexedAt: state.lastIndexedAt,
            lastUIRefreshAt: now,
            lastCheckpointID: state.lastCheckpoint?.id,
            lastCheckpointEventsAdded: state.lastCheckpoint?.eventsAdded ?? 0,
            lastCheckpointPromptsAdded: state.lastCheckpoint?.promptsAdded ?? 0,
            parserWarningCount: state.warnings.count,
            refreshState: refreshState,
            rebuildError: state.lastRebuildError
        )
    }

    func openProject(named name: String) {
        selectedProjectName = name
        mainRoute = .project(name)
        Task {
            let now = Date()
            let state = await usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian))
            let detail = UsageAggregator.makeProjectDetail(
                projectName: name,
                from: state.events,
                referenceDate: now,
                calendar: Calendar(identifier: .gregorian)
            )
            await MainActor.run {
                prompts = state.prompts
                events = state.events
                projectDetail = detail
            }
        }
    }

    func projectDetail(for name: String) async -> ProjectDetailSnapshot? {
        let now = Date()
        let state = await usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian))
        return UsageAggregator.makeProjectDetail(
            projectName: name,
            from: state.events,
            referenceDate: now,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    func promptHistory(for projectName: String) -> [PromptRecord] {
        prompts
            .filter { $0.projectName == projectName }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.content.count > rhs.content.count
                }
                return lhs.timestamp > rhs.timestamp
            }
    }

    func projectPath(for projectName: String) -> String? {
        events
            .filter { $0.projectName == projectName && !($0.projectPath ?? "").isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
            .first?
            .projectPath
    }

    func allTimeSummary(for projectName: String) -> UsageSummary {
        let projectEvents = events.filter { $0.projectName == projectName }
        return UsageSummary(
            inputTokens: projectEvents.reduce(0) { $0 + $1.inputTokens },
            outputTokens: projectEvents.reduce(0) { $0 + $1.outputTokens },
            cacheTokens: projectEvents.reduce(0) { $0 + $1.cacheTokens }
        )
    }

    func allTimeCost(for projectName: String) -> UsageCostProjection {
        let projectEvents = events.filter { $0.projectName == projectName }
        var totalsByModel: [String: (tokens: Int, cost: Double)] = [:]
        for event in projectEvents {
            let modelName = event.modelName ?? event.agent.displayName
            let tokenCount = event.inputTokens + event.outputTokens + event.cacheTokens
            let current = totalsByModel[modelName] ?? (tokens: 0, cost: 0)
            totalsByModel[modelName] = (
                tokens: current.tokens + tokenCount,
                cost: current.cost + Double(tokenCount) * event.agent.defaultCostPerMillionTokens / 1_000_000
            )
        }
        let totalTokens = totalsByModel.values.reduce(0) { $0 + $1.tokens }

        let byAgent = totalsByModel
            .map { model, totals in
                UsageCostBreakdown(
                    name: model,
                    totalTokens: totals.tokens,
                    cost: totals.cost,
                    percentage: totalTokens > 0 ? Double(totals.tokens) / Double(totalTokens) : 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens == rhs.totalTokens {
                    return lhs.name < rhs.name
                }
                return lhs.totalTokens > rhs.totalTokens
            }

        let totalCost = byAgent.reduce(0.0) { $0 + $1.cost }
        let blendedRate = totalTokens > 0 ? totalCost / Double(totalTokens) * 1_000_000 : 0

        return UsageCostProjection(
            totalCost: totalCost,
            blendedRatePerMillion: blendedRate,
            byAgent: byAgent
        )
    }

    func updateRefreshState() {
        let now = Date()
        refreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: diagnostics.lastIndexedAt,
            lastRebuildError: diagnostics.rebuildError,
            refreshInterval: refreshInterval
        )
        diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: diagnostics.dataSourceStatuses,
            lastIndexedAt: diagnostics.lastIndexedAt,
            lastUIRefreshAt: diagnostics.lastUIRefreshAt,
            lastCheckpointID: diagnostics.lastCheckpointID,
            lastCheckpointEventsAdded: diagnostics.lastCheckpointEventsAdded,
            lastCheckpointPromptsAdded: diagnostics.lastCheckpointPromptsAdded,
            parserWarningCount: diagnostics.parserWarningCount,
            refreshState: refreshState,
            rebuildError: diagnostics.rebuildError
        )
    }

    func addCustomSource(
        name: String,
        directory: String,
        globPattern: String,
        format: CustomSourceFormat,
        displayAgent: String
    ) async {
        let source = CustomSourceRecord(
            name: name.isEmpty ? "Custom Source" : name,
            directory: directory,
            globPattern: globPattern.isEmpty ? "**/*.jsonl" : globPattern,
            format: format,
            displayAgent: displayAgent.isEmpty ? "Custom" : displayAgent
        )
        try? await usageStore.upsertCustomSource(source)
        customSources = await loadCustomSources()
        await restartFileWatcher()
        await refresh()
    }

    func reparseAllSources() async {
        try? await usageStore.reparseAll()
        await refresh()
    }

    /// CL-P1-021: wipe stored prompts. After this returns the prompts list is
    /// empty and the SQLite file shrinks via VACUUM.
    func wipePrompts() async throws {
        try await usageStore.wipePrompts()
        await refresh()
    }

    func reparseSource(_ sourcePath: String) async {
        try? await usageStore.reparseSource(sourcePath)
        await refresh()
    }

    private func applyRetentionAndReload(referenceDate: Date) async {
        await applyRetention(referenceDate: referenceDate)
        let state = await usageStore.state(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian))
        events = state.events
        prompts = state.prompts
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if let selectedProjectName {
            projectDetail = UsageAggregator.makeProjectDetail(
                projectName: selectedProjectName,
                from: state.events,
                referenceDate: referenceDate,
                calendar: Calendar(identifier: .gregorian)
            )
        }
    }

    private func applyRetention(referenceDate: Date) async {
        guard let days = retentionDays else {
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: todayStart) else {
            return
        }
        try? await usageStore.pruneRecords(before: cutoff)
    }

    private var retentionDays: Int? {
        switch retentionWindow {
        case "30d":
            30
        case "90d":
            90
        case "365d":
            365
        default:
            nil
        }
    }

    func toggleCustomSource(_ source: CustomSourceRecord) async {
        var updated = source
        updated.enabled.toggle()
        try? await usageStore.upsertCustomSource(updated)
        customSources = await loadCustomSources()
        await restartFileWatcher()
        await refresh()
    }

    func removeCustomSource(id: String) async {
        try? await usageStore.deleteCustomSource(id: id)
        customSources = await loadCustomSources()
        await restartFileWatcher()
        await refresh()
    }

    private func collectStatuses(sources: [any InspectableUsageEventSource], referenceDate: Date) async -> [UsageDataSourceStatus] {
        var statuses: [UsageDataSourceStatus] = []
        let calendar = Calendar(identifier: .gregorian)

        for source in sources {
            let status = await source.status(referenceDate: referenceDate, calendar: calendar)
            statuses.append(status)
        }

        return statuses.sorted { $0.sourceName < $1.sourceName }
    }

    private func loadCustomSources() async -> [CustomSourceRecord] {
        (try? await usageStore.customSources()) ?? []
    }

    private func activeSources() async -> [any InspectableUsageEventSource] {
        let custom = customSources
            .filter(\.enabled)
            .map { CustomUsageEventSource(record: $0) as any InspectableUsageEventSource }
        return builtInSources + custom
    }

    private func checkpointEngine(for sources: [any InspectableUsageEventSource]) -> CheckpointEngine {
        let signature = sources.map { "\($0.sourceName):\($0.rootPath)" }.joined(separator: "|")
        if checkpointSourceSignature != signature {
            checkpointSourceSignature = signature
            checkpointEngine = CheckpointEngine(sources: sources, store: usageStore)
        }
        if let checkpointEngine {
            return checkpointEngine
        }
        let engine = CheckpointEngine(sources: sources, store: usageStore)
        checkpointEngine = engine
        return engine
    }

    private func restartFileWatcher() async {
        await fileWatcher?.stop()
        let customPaths = customSources
            .filter(\.enabled)
            .map(\.directory)
        let watcher = RecursiveFSEventsWatcher(
            paths: ["~/.codex/sessions", "~/.claude/projects", "~/.hermes"] + customPaths
        ) { [weak self] in
            await self?.refresh()
        }
        fileWatcher = watcher
        try? await watcher.start()
    }

    static func live() -> TokenBarRuntimeModel {
        let settingsStore = SettingsStore()
        let usageStore = (try? UsageStore(databaseURL: UsageDatabase.defaultDatabaseURL())) ?? UsageStore()
        let useSampleData = ProcessInfo.processInfo.environment["TOKENBAR_USE_SAMPLE_DATA"] == "1"
        let sources: [any InspectableUsageEventSource] = useSampleData
            ? [
                SampleUsageEventSource(),
            ]
            : [
                CodexUsageEventSource(),
                ClaudeUsageEventSource(),
                HermesUsageEventSource(),
            ]
        return TokenBarRuntimeModel(
            settingsStore: settingsStore,
            usageStore: usageStore,
            sources: sources
        )
    }
}
