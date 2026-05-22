import AppKit
import Foundation
import TokenBarCore

enum TokenBarIndexingPhase: String, Sendable, Hashable {
    case idle
    case queued
    case discovering
    case indexing
    case paused
    case completed
    case failed
}

enum TokenBarIndexingSourcePhase: String, Sendable, Hashable {
    case pending
    case scanning
    case indexed
    case skipped
    case failed
}

struct TokenBarIndexingSourceState: Identifiable, Sendable, Hashable {
    let sourceName: String
    let rootPath: String
    var phase: TokenBarIndexingSourcePhase
    var discoveredFileCount: Int
    var eventsIndexed: Int
    var promptsIndexed: Int
    var message: String?

    var id: String { sourceName }
}

struct TokenBarIndexingState: Sendable, Hashable {
    var phase: TokenBarIndexingPhase
    var sources: [TokenBarIndexingSourceState]
    var startedAt: Date?
    var endedAt: Date?
    var checkedFiles: Int
    var eventsIndexed: Int
    var promptsIndexed: Int
    var message: String?
    var activeSourceName: String?
    var cpuBudgetPercent: Double?

    static let idle = TokenBarIndexingState(
        phase: .idle,
        sources: [],
        startedAt: nil,
        endedAt: nil,
        checkedFiles: 0,
        eventsIndexed: 0,
        promptsIndexed: 0,
        message: nil,
        activeSourceName: nil,
        cpuBudgetPercent: nil
    )

    var isActive: Bool {
        phase == .discovering || phase == .indexing
    }

    var isVisible: Bool {
        phase != .idle
    }

    var isPartial: Bool {
        isActive || phase == .queued || phase == .paused
    }

    var completedSourceCount: Int {
        sources.filter { $0.phase == .indexed || $0.phase == .skipped }.count
    }

    var progress: Double {
        guard !sources.isEmpty else { return phase == .completed ? 1 : 0 }
        switch phase {
        case .idle, .queued:
            return 0
        case .completed:
            return 1
        default:
            return min(0.98, Double(completedSourceCount) / Double(sources.count))
        }
    }
}

enum CustomSourceSaveResult: Equatable {
    case saved(name: String, deduplicated: Bool)
    case failed(String)
}

private struct CachedProjectDetail {
    let detail: ProjectDetailSnapshot
    let eventsSignature: String
}

struct TokenBarOverviewRangeData: Sendable, Hashable {
    let aggregate: UsageRangeAggregate
    let window: TokenBarRangeWindow
}

@MainActor
final class TokenBarRuntimeModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var diagnostics: DiagnosticsSnapshot
    @Published private(set) var prompts: [PromptRecord]
    @Published private(set) var eventCount: Int
    @Published private(set) var promptCount: Int
    @Published private(set) var eventSignature: String
    @Published private(set) var promptSignature: String
    @Published private(set) var lastCheckpoint: CheckpointSummary?
    @Published private(set) var refreshState: RefreshState
    @Published private(set) var selectedProjectName: String?
    @Published private(set) var projectDetail: ProjectDetailSnapshot?
    @Published private(set) var customSources: [CustomSourceRecord]
    @Published private(set) var savedPrompts: [SavedPrompt] = []
    @Published private(set) var events: [UsageEvent]
    @Published private(set) var sourceWarnings: [UsageSourceWarning]
    @Published private(set) var popoverSnapshot: TokenBarPopoverSnapshot
    @Published private(set) var indexingState: TokenBarIndexingState = .idle
    @Published private(set) var isBootstrapping = true
    @Published private(set) var archivedProjectNames: Set<String>
    @Published var mainRoute: TokenBarMainRoute = .today {
        didSet {
            guard oldValue != mainRoute else { return }
            TokenBarTelemetry.event(
                "main.route.change",
                metadata: "from=\(oldValue.telemetryName) to=\(mainRoute.telemetryName)",
                success: true
            )
        }
    }

    @Published var refreshInterval: RefreshIntervalOption {
        didSet {
            TokenBarTelemetry.event("settings.refresh_interval.change", metadata: "value=\(refreshInterval.rawValue)", success: true)
            settingsStore.refreshInterval = refreshInterval
            intervalRefreshTask?.cancel()
            intervalRefreshTask = nil
        }
    }

    @Published var keepDataOnThisMac: Bool {
        didSet {
            TokenBarTelemetry.event("settings.keep_local.change", metadata: "value=\(keepDataOnThisMac)", success: true)
            settingsStore.keepDataOnThisMac = keepDataOnThisMac
        }
    }

    @Published var storePromptTextInClearText: Bool {
        didSet {
            TokenBarTelemetry.event("settings.prompt_capture.change", metadata: "value=\(storePromptTextInClearText)", success: true)
            settingsStore.storePromptTextInClearText = storePromptTextInClearText
        }
    }

    @Published var usePromptFingerprintsByDefault: Bool {
        didSet {
            TokenBarTelemetry.event("settings.prompt_fingerprint.change", metadata: "value=\(usePromptFingerprintsByDefault)", success: true)
            settingsStore.usePromptFingerprintsByDefault = usePromptFingerprintsByDefault
        }
    }

    @Published var retentionWindow: String {
        didSet {
            TokenBarTelemetry.event("settings.retention.change", metadata: "value=\(retentionWindow)", success: true)
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
    private var lastAutomaticRefreshAt: Date?
    private var activeRefreshTrigger: String?
    private var suppressSourceChangesUntil: Date?
    private var intervalRefreshTask: Task<Void, Never>?
    // CL-P0-026: scheduled to fire just after local midnight so the Today KPI
    // resets, the 30d strip shifts, and the Popover briefly shows a "Day
    // changed — refreshing…" hint. `dayChangedAt` is published so views can
    // observe it and animate a transient banner.
    private var midnightTask: Task<Void, Never>?
    private var projectDetailTask: Task<Void, Never>?
    private var projectDetailCache: [String: CachedProjectDetail] = [:]
    private var initialIndexTask: Task<Void, Never>?
    private let savedPromptCommandSync = SavedPromptCommandSync()
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
        self.archivedProjectNames = settingsStore.archivedProjectNames
        self.refreshState = .idle
        self.selectedProjectName = nil
        self.projectDetail = nil
        self.prompts = []
        self.eventCount = 0
        self.promptCount = 0
        self.eventSignature = "0|"
        self.promptSignature = "0|"
        self.lastCheckpoint = nil
        self.events = []
        self.sourceWarnings = []
        self.popoverSnapshot = .empty
        self.indexingState = .idle
        self.isBootstrapping = true
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
        let started = Date()
        TokenBarSignpost.event("bootstrap-start")
        defer { TokenBarSignpost.event("bootstrap-end") }
        guard !hasBootstrapped else {
            TokenBarTelemetry.event("runtime.bootstrap.skip", success: true, elapsed: Date().timeIntervalSince(started))
            return
        }
        hasBootstrapped = true
        isBootstrapping = true
        defer { isBootstrapping = false }
        var stageStarted = Date()
        await loadPersistedSnapshot()
        TokenBarTelemetry.timing(
            "runtime.bootstrap.stage.load_persisted_snapshot",
            startedAt: stageStarted,
            metadata: "events=\(eventCount) prompts=\(promptCount) warnings=\(sourceWarnings.count)"
        )
        stageStarted = Date()
        await restartFileWatcher()
        TokenBarTelemetry.timing("runtime.bootstrap.stage.restart_file_watcher", startedAt: stageStarted)
        scheduleNextMidnightRollover()
        observeSystemPowerEvents()
        TokenBarTelemetry.event(
            "runtime.bootstrap",
            metadata: "events=\(eventCount) prompts=\(promptCount) warnings=\(sourceWarnings.count)",
            success: diagnostics.rebuildError == nil,
            elapsed: Date().timeIntervalSince(started),
            error: diagnostics.rebuildError
        )
        if shouldRunInitialIndexing {
            startInitialIndexing(reason: "cold-start")
        } else if refreshState != .idle {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                await self?.refresh(trigger: "bootstrap-background")
            }
        } else {
            TokenBarTelemetry.event(
                "runtime.bootstrap.background_refresh.skip_fresh",
                metadata: "refresh_state=\(refreshState.rawValue) last_indexed=\(diagnostics.lastIndexedAt != nil)",
                success: true
            )
        }
    }

    private var shouldRunInitialIndexing: Bool {
        events.isEmpty && lastCheckpoint == nil && diagnostics.lastIndexedAt == nil && !builtInSources.isEmpty
    }

    /// CL-P1-036: after a sleep/wake cycle, trigger a refresh so the menubar
    /// briefly enters stale → idle instead of showing stale data for an hour.
    private func observeSystemPowerEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh(trigger: "wake") }
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
            await self.refresh(trigger: "midnight-rollover")
            await MainActor.run {
                self.scheduleNextMidnightRollover()
            }
        }
    }

    private func loadPersistedSnapshot() async {
        let started = Date()
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        var stageStarted = Date()
        customSources = await loadCustomSources()
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.custom_sources",
            startedAt: stageStarted,
            metadata: "count=\(customSources.count)"
        )
        stageStarted = Date()
        savedPrompts = await loadSavedPrompts()
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.saved_prompts",
            startedAt: stageStarted,
            metadata: "count=\(savedPrompts.count)"
        )
        stageStarted = Date()
        await applyRetention(referenceDate: now)
        TokenBarTelemetry.timing("runtime.load_persisted.stage.apply_retention", startedAt: stageStarted)
        stageStarted = Date()
        let state = await usageStore.state(referenceDate: now, calendar: calendar, includePrompts: false)
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.usage_store_state",
            startedAt: stageStarted,
            metadata: "events=\(state.eventCount) prompts=\(state.promptCount) warnings=\(state.warnings.count)"
        )
        stageStarted = Date()
        events = state.events
        prompts = []
        publishCollectionMetadata(from: state)
        sourceWarnings = state.warnings
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if selectedProjectName == nil {
            selectedProjectName = state.snapshot.topProjects.first?.name
        }
        let detailProjectName = selectedProjectName
        let computedProjectDetail = await Self.computeProjectDetailSnapshot(
            projectName: detailProjectName,
            from: state.events,
            referenceDate: now,
            calendar: calendar
        )
        if selectedProjectName == detailProjectName {
            projectDetail = computedProjectDetail
            if let computedProjectDetail {
                cacheProjectDetail(computedProjectDetail)
            }
        }
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.publish_snapshot",
            startedAt: stageStarted,
            metadata: "project=\(selectedProjectName ?? "none")"
        )
        stageStarted = Date()

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
        stageStarted = Date()
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics,
            referenceDate: now,
            calendar: calendar
        )
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.popover_snapshot",
            startedAt: stageStarted,
            metadata: "events=\(eventCount)"
        )
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.publish_diagnostics",
            startedAt: stageStarted,
            metadata: "refresh_state=\(refreshState)"
        )
        TokenBarTelemetry.timing(
            "runtime.load_persisted.total",
            startedAt: started,
            metadata: "events=\(eventCount) prompts=\(promptCount) warnings=\(sourceWarnings.count)"
        )
    }

    func refresh(trigger: String = "manual") async {
        let started = Date()
        guard !indexingState.isActive else {
            TokenBarTelemetry.event(
                "runtime.refresh.skip_initial_index",
                metadata: "trigger=\(trigger) phase=\(indexingState.phase.rawValue)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }
        if let activeRefreshTrigger {
            TokenBarTelemetry.event(
                "runtime.refresh.skip_active",
                metadata: "trigger=\(trigger) active=\(activeRefreshTrigger)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }
        activeRefreshTrigger = trigger
        defer { activeRefreshTrigger = nil }
        TokenBarSignpost.event("refresh-start")
        defer { TokenBarSignpost.event("refresh-end") }
        refreshState = .refreshing
        let now = Date()
        lastAutomaticRefreshAt = now
        intervalRefreshTask?.cancel()
        intervalRefreshTask = nil
        var stageStarted = Date()
        customSources = await loadCustomSources()
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.custom_sources",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) count=\(customSources.count)"
        )
        stageStarted = Date()
        let sources = await activeSources()
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.active_sources",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) count=\(sources.count)"
        )
        stageStarted = Date()
        let backgroundThrottle = backgroundThrottle(for: trigger)
        let showIndexingProgress = shouldShowRefreshIndexingProgress(for: trigger)
        if showIndexingProgress {
            publishRefreshIndexingDiscovery(
                trigger: trigger,
                sources: sources,
                startedAt: now,
                resourceThrottle: backgroundThrottle
            )
            let discoveryStatuses = await collectStatuses(sources: sources, referenceDate: now)
            publishRefreshIndexingProgress(
                trigger: trigger,
                statuses: discoveryStatuses,
                startedAt: now,
                resourceThrottle: backgroundThrottle
            )
        }
        let engine = checkpointEngine(for: sources, resourceThrottle: backgroundThrottle)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.checkpoint_engine_prepare",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) background=\(backgroundThrottle != nil)"
        )
        stageStarted = Date()
        let runResult = await engine.run(trigger: trigger, startedAt: now, referenceDate: now, calendar: Calendar(identifier: .gregorian))
        let throttleSnapshot = await backgroundThrottle?.snapshot()
        let throttleMetadata: String
        if let throttleSnapshot {
            throttleMetadata = "trigger=\(trigger) cpu_budget=\(throttleSnapshot.cpuPercent) estimated_cpu=\(String(format: "%.1f", throttleSnapshot.estimatedCPUPercent)) active_ms=\(Int(throttleSnapshot.activeSeconds * 1000)) sleep_ms=\(Int(throttleSnapshot.sleepSeconds * 1000))"
        } else {
            throttleMetadata = "trigger=\(trigger)"
        }
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.checkpoint_engine_run",
            startedAt: stageStarted,
            metadata: throttleMetadata
        )
        stageStarted = Date()
        await applyRetention(referenceDate: now)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.apply_retention",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger)"
        )
        stageStarted = Date()
        let state = await usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian), includePrompts: false)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.usage_store_state",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) events=\(state.eventCount) prompts=\(state.promptCount) warnings=\(state.warnings.count)"
        )
        stageStarted = Date()
        let statuses = await collectStatuses(sources: sources, referenceDate: now)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.collect_statuses",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) statuses=\(statuses.count)"
        )
        stageStarted = Date()

        events = state.events
        prompts = []
        publishCollectionMetadata(from: state)
        sourceWarnings = state.warnings
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if selectedProjectName == nil {
            selectedProjectName = state.snapshot.topProjects.first?.name
        }
        let detailProjectName = selectedProjectName
        let computedProjectDetail = await Self.computeProjectDetailSnapshot(
            projectName: detailProjectName,
            from: state.events,
            referenceDate: now,
            calendar: Calendar(identifier: .gregorian)
        )
        if selectedProjectName == detailProjectName {
            projectDetail = computedProjectDetail
            if let computedProjectDetail {
                cacheProjectDetail(computedProjectDetail)
            }
        }
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.publish_snapshot",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) project=\(selectedProjectName ?? "none")"
        )
        stageStarted = Date()
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
        stageStarted = Date()
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics,
            referenceDate: now,
            calendar: Calendar(identifier: .gregorian)
        )
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.popover_snapshot",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) events=\(eventCount)"
        )
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.publish_diagnostics",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) refresh_state=\(refreshState)"
        )
        if showIndexingProgress {
            publishRefreshIndexingCompletion(
                trigger: trigger,
                statuses: statuses,
                result: runResult,
                endedAt: Date()
            )
        }
        TokenBarTelemetry.event(
            "runtime.refresh",
            metadata: "trigger=\(trigger) events=\(state.eventCount) prompts=\(state.promptCount) warnings=\(state.warnings.count)",
            success: state.lastRebuildError == nil,
            elapsed: Date().timeIntervalSince(started),
            error: state.lastRebuildError
        )
    }

    func startInitialIndexing(reason: String = "manual") {
        guard !indexingState.isActive else {
            TokenBarTelemetry.event(
                "initial_index.start.skip",
                metadata: "reason=\(reason) phase=\(indexingState.phase.rawValue)",
                success: true
            )
            return
        }

        initialIndexTask?.cancel()
        let startedAt = Date()
        let sources = builtInSources
        indexingState = TokenBarIndexingState(
            phase: .discovering,
            sources: sources.map {
                TokenBarIndexingSourceState(
                    sourceName: $0.sourceName,
                    rootPath: $0.rootPath,
                    phase: .pending,
                    discoveredFileCount: 0,
                    eventsIndexed: 0,
                    promptsIndexed: 0,
                    message: nil
                )
            },
            startedAt: startedAt,
            endedAt: nil,
            checkedFiles: 0,
            eventsIndexed: 0,
            promptsIndexed: 0,
            message: "Initial indexing with a \(Int(IndexingResourceBudget.initialIndexCPUPercent))% CPU budget",
            activeSourceName: nil,
            cpuBudgetPercent: IndexingResourceBudget.initialIndexCPUPercent
        )
        refreshState = .refreshing
        diagnostics = diagnosticsSnapshot(
            from: diagnostics,
            statuses: diagnostics.dataSourceStatuses,
            refreshState: .refreshing,
            rebuildError: nil
        )
        TokenBarTelemetry.event(
            "initial_index.start",
            metadata: "reason=\(reason) sources=\(sources.count) cpu_budget=\(IndexingResourceBudget.initialIndexCPUPercent)",
            success: true
        )

        initialIndexTask = Task(priority: .background) { [weak self] in
            await self?.runInitialIndexing(sources: sources, startedAt: startedAt, reason: reason)
        }
    }

    func pauseInitialIndexing() {
        guard indexingState.isActive else { return }
        initialIndexTask?.cancel()
        initialIndexTask = nil
        var next = indexingState
        next.phase = .paused
        next.endedAt = Date()
        next.message = "Indexing paused"
        next.activeSourceName = nil
        next.sources = next.sources.map { source in
            var mutable = source
            if mutable.phase == .scanning {
                mutable.phase = .pending
                mutable.message = "paused"
            }
            return mutable
        }
        indexingState = next
        refreshState = RefreshStateEvaluator.evaluate(
            now: Date(),
            lastIndexedAt: diagnostics.lastIndexedAt,
            lastRebuildError: diagnostics.rebuildError,
            refreshInterval: refreshInterval
        )
        TokenBarTelemetry.event(
            "initial_index.pause",
            metadata: "events=\(next.eventsIndexed) files=\(next.checkedFiles)",
            success: true
        )
    }

    func retryInitialIndexing() {
        TokenBarTelemetry.event("initial_index.retry", success: true)
        startInitialIndexing(reason: "retry")
    }

    private func runInitialIndexing(
        sources: [any InspectableUsageEventSource],
        startedAt: Date,
        reason: String
    ) async {
        let calendar = Calendar(identifier: .gregorian)
        let resourceThrottle = IndexingResourceThrottle(budget: .initialIndex)
        var statuses: [UsageDataSourceStatus] = []
        var totalFiles = 0
        var totalEvents = 0
        var totalPrompts = 0
        var lastError: String?
        var wroteCheckpoint = false

        for source in sources {
            guard !Task.isCancelled else { return }
            markIndexingSource(source.sourceName, phase: .scanning, message: "Discovering")
            let sourceStarted = Date()
            let referenceDate = Date()
            let status = await Task.detached(priority: .utility) {
                await source.status(referenceDate: referenceDate, calendar: calendar)
            }.value
            statuses.removeAll { $0.sourceName == status.sourceName }
            statuses.append(status)
            statuses.sort { $0.sourceName < $1.sourceName }
            totalFiles += status.discoveredFileCount
            updateIndexingSource(
                status.sourceName,
                phase: .scanning,
                discoveredFileCount: status.discoveredFileCount,
                message: sourceMessage(for: status)
            )
            publishIndexingTotals(
                phase: .indexing,
                checkedFiles: totalFiles,
                eventsIndexed: totalEvents,
                promptsIndexed: totalPrompts,
                activeSourceName: status.sourceName,
                message: "Indexing \(status.sourceName)"
            )
            publishDiagnosticsDuringInitialIndex(statuses: statuses, rebuildError: nil)

            guard status.isReadable || status.discoveredFileCount > 0 else {
                updateIndexingSource(
                    status.sourceName,
                    phase: .skipped,
                    discoveredFileCount: status.discoveredFileCount,
                    message: "Not found or no access"
                )
                TokenBarTelemetry.event(
                    "initial_index.source.skip",
                    metadata: "reason=\(reason) source=\(status.sourceName) path=\(status.rootPath)",
                    success: true,
                    elapsed: Date().timeIntervalSince(sourceStarted)
                )
                continue
            }

            do {
                let watermarks = (try? await usageStore.watermarks()) ?? [:]
                let result = try await Task.detached(priority: .background) {
                    if let budgetedSource = source as? any ResourceBudgetedUsageEventSource {
                        return try await budgetedSource.loadEvents(
                            since: watermarks,
                            referenceDate: referenceDate,
                            calendar: calendar,
                            resourceThrottle: resourceThrottle
                        )
                    }
                    let started = Date()
                    let result = try await source.loadEvents(
                        since: watermarks,
                        referenceDate: referenceDate,
                        calendar: calendar
                    )
                    await resourceThrottle.rest(afterActive: Date().timeIntervalSince(started))
                    return result
                }.value
                guard !Task.isCancelled else { return }
                let state = await usageStore.applyCheckpoint(
                    trigger: "initial-index:\(status.sourceName)",
                    startedAt: sourceStarted,
                    endedAt: Date(),
                    events: result.events,
                    prompts: result.prompts,
                    nextWatermarks: result.nextWatermarks,
                    warnings: result.warnings,
                    referenceDate: referenceDate,
                    calendar: calendar,
                    lastRebuildError: nil,
                    stateIncludesPrompts: false
                )
                wroteCheckpoint = true
                totalEvents += result.events.count
                totalPrompts += result.prompts.count
                updateIndexingSource(
                    status.sourceName,
                    phase: .indexed,
                    discoveredFileCount: status.discoveredFileCount,
                    eventsIndexed: result.events.count,
                    promptsIndexed: result.prompts.count,
                    message: result.events.isEmpty && result.prompts.isEmpty ? "No usage records found" : "Indexed"
                )
                publishStoreState(
                    state,
                    statuses: statuses,
                    referenceDate: referenceDate,
                    refreshState: .refreshing
                )
                publishIndexingTotals(
                    phase: .indexing,
                    checkedFiles: totalFiles,
                    eventsIndexed: totalEvents,
                    promptsIndexed: totalPrompts,
                    activeSourceName: status.sourceName,
                    message: "Indexed \(status.sourceName)"
                )
                TokenBarTelemetry.event(
                    "initial_index.source",
                    metadata: "reason=\(reason) source=\(status.sourceName) files=\(status.discoveredFileCount) events=\(result.events.count) prompts=\(result.prompts.count)",
                    success: true,
                    elapsed: Date().timeIntervalSince(sourceStarted)
                )
            } catch {
                let message = describe(error)
                lastError = [lastError, "\(status.sourceName): \(message)"].compactMap { $0 }.joined(separator: " | ")
                updateIndexingSource(
                    status.sourceName,
                    phase: .failed,
                    discoveredFileCount: status.discoveredFileCount,
                    message: message
                )
                publishDiagnosticsDuringInitialIndex(statuses: statuses, rebuildError: lastError)
                TokenBarTelemetry.event(
                    "initial_index.source",
                    metadata: "reason=\(reason) source=\(status.sourceName) files=\(status.discoveredFileCount)",
                    success: false,
                    elapsed: Date().timeIntervalSince(sourceStarted),
                    error: message
                )
            }
        }

        guard !Task.isCancelled else { return }
        let finishedAt = Date()
        let finalState: UsageStoreState
        if lastError != nil || !wroteCheckpoint {
            finalState = await usageStore.applyCheckpoint(
                trigger: "initial-index:summary",
                startedAt: startedAt,
                endedAt: finishedAt,
                events: [],
                prompts: [],
                warnings: [],
                referenceDate: finishedAt,
                calendar: calendar,
                lastRebuildError: lastError,
                stateIncludesPrompts: false
            )
        } else {
            finalState = await usageStore.state(referenceDate: finishedAt, calendar: calendar, includePrompts: false)
        }
        publishStoreState(
            finalState,
            statuses: statuses,
            referenceDate: finishedAt,
            refreshState: RefreshStateEvaluator.evaluate(
                now: finishedAt,
                lastIndexedAt: finalState.lastIndexedAt,
                lastRebuildError: lastError ?? finalState.lastRebuildError,
                refreshInterval: refreshInterval
            ),
            rebuildError: lastError ?? finalState.lastRebuildError
        )
        publishIndexingTotals(
            phase: lastError == nil ? .completed : .failed,
            checkedFiles: totalFiles,
            eventsIndexed: totalEvents,
            promptsIndexed: totalPrompts,
            activeSourceName: nil,
            message: lastError == nil ? "Local index ready" : "Indexing finished with source issues",
            endedAt: finishedAt
        )
        TokenBarTelemetry.event(
            "initial_index.complete",
            metadata: "reason=\(reason) sources=\(sources.count) files=\(totalFiles) events=\(totalEvents) prompts=\(totalPrompts)",
            success: lastError == nil,
            elapsed: finishedAt.timeIntervalSince(startedAt),
            error: lastError
        )
        if lastError == nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    guard let self, self.indexingState.phase == .completed else { return }
                    self.indexingState = .idle
                }
            }
        }
    }

    func navigate(to route: TokenBarMainRoute, source: String) {
        let started = Date()
        if mainRoute == route {
            TokenBarTelemetry.event(
                "main.route.select.skip",
                metadata: "source=\(source) route=\(route.telemetryName)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }

        TokenBarTelemetry.event(
            "main.route.select",
            metadata: "source=\(source) from=\(mainRoute.telemetryName) to=\(route.telemetryName)",
            success: true
        )
        mainRoute = route
        TokenBarTelemetry.timing(
            "main.route.select.publish",
            startedAt: started,
            metadata: "source=\(source) route=\(route.telemetryName)"
        )
    }

    func openProject(named name: String, source: String = "project.list") {
        let started = Date()
        if selectedProjectName == name, projectDetail?.projectName == name {
            navigate(to: .project(name), source: source)
            TokenBarTelemetry.event(
                "project.open.skip_current",
                metadata: "source=\(source) project=\(name)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }

        projectDetailTask?.cancel()
        let signature = eventSignature
        let cachedDetail = projectDetailCache[name].flatMap { cached -> ProjectDetailSnapshot? in
            cached.eventsSignature == signature ? cached.detail : nil
        }
        TokenBarTelemetry.event(
            "project.open",
            metadata: "source=\(source) project=\(name) cached=\(cachedDetail != nil) events=\(eventCount)",
            success: true
        )
        selectedProjectName = name
        if let cachedDetail {
            projectDetail = cachedDetail
        } else if projectDetail?.projectName != name {
            projectDetail = nil
        }
        navigate(to: .project(name), source: source)
        TokenBarTelemetry.timing(
            "project.open.route_ready",
            startedAt: started,
            metadata: "source=\(source) project=\(name) cached=\(cachedDetail != nil)"
        )

        projectDetailTask = Task {
            let now = Date()
            guard cachedDetail == nil else {
                TokenBarTelemetry.event(
                    "project.open.detail.skip",
                    metadata: "source=\(source) project=\(name) reason=cache",
                    success: true,
                    elapsed: Date().timeIntervalSince(started)
                )
                return
            }

            let loadStarted = Date()
            let projectEvents = (try? await usageStore.projectEvents(projectName: name)) ?? []
            guard !Task.isCancelled else { return }
            TokenBarTelemetry.timing(
                "project.open.project_events",
                startedAt: loadStarted,
                metadata: "source=\(source) project=\(name) events=\(projectEvents.count)"
            )

            let detailStarted = Date()
            let detail = await Task.detached(priority: .utility) {
                Self.makeProjectDetailSnapshot(
                    projectName: name,
                    from: projectEvents,
                    referenceDate: now,
                    calendar: Calendar(identifier: .gregorian)
                )
            }.value
            guard !Task.isCancelled else { return }
            TokenBarTelemetry.timing(
                "project.open.compute_detail",
                startedAt: detailStarted,
                metadata: "source=\(source) project=\(name) events=\(projectEvents.count)"
            )

            guard selectedProjectName == name else { return }
            projectDetail = detail
            if let detail {
                cacheProjectDetail(detail)
            }
            TokenBarTelemetry.event(
                "project.detail.load",
                metadata: "source=\(source) project=\(name) events=\(projectEvents.count) tokens=\(detail?.summary.totalTokens ?? 0)",
                success: detail != nil,
                elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    func archiveProject(named name: String, source: String = "sidebar.project_context") {
        setProjectArchived(name, archived: true, source: source)
    }

    func restoreProject(named name: String, source: String = "sidebar.project_context") {
        setProjectArchived(name, archived: false, source: source)
    }

    private func setProjectArchived(_ name: String, archived: Bool, source: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var next = archivedProjectNames
        let changed: Bool
        if archived {
            changed = next.insert(normalized).inserted
        } else {
            changed = next.remove(normalized) != nil
        }
        guard changed else {
            TokenBarTelemetry.event(
                "project.archive.skip",
                metadata: "source=\(source) project=\(normalized) archived=\(archived)",
                success: true
            )
            return
        }

        archivedProjectNames = next
        settingsStore.archivedProjectNames = next
        TokenBarTelemetry.event(
            "project.archive.change",
            metadata: "source=\(source) project=\(normalized) archived=\(archived) count=\(next.count)",
            success: true
        )

        if archived, selectedProjectName == normalized, mainRoute == .project(normalized) {
            navigate(to: .today, source: "\(source).archived_current")
        }
    }

    func projectDetail(for name: String) async -> ProjectDetailSnapshot? {
        let now = Date()
        let projectEvents = (try? await usageStore.projectEvents(projectName: name)) ?? []
        return Self.makeProjectDetailSnapshot(
            projectName: name,
            from: projectEvents,
            referenceDate: now,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    func projectEvents(for name: String) async -> [UsageEvent] {
        (try? await usageStore.projectEvents(projectName: name)) ?? []
    }

    func overviewRangeData(
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async -> TokenBarOverviewRangeData? {
        guard let bounds = try? await usageStore.eventTimeBounds() else {
            return nil
        }
        let window = tokenbarRangeWindow(
            selection: selection,
            earliestEventDate: bounds.earliest,
            referenceDate: referenceDate,
            calendar: calendar
        )
        guard let aggregate = try? await usageStore.rangeAggregate(
            start: window.start,
            end: window.end,
            calendar: calendar
        ) else {
            return nil
        }
        return TokenBarOverviewRangeData(aggregate: aggregate, window: window)
    }

    func projectBreakdowns(
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async -> [UsageBreakdown]? {
        guard let bounds = try? await usageStore.eventTimeBounds() else {
            return nil
        }
        let window = tokenbarRangeWindow(
            selection: selection,
            earliestEventDate: bounds.earliest,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return try? await usageStore.projectBreakdowns(
            start: window.start,
            end: window.end,
            topCount: nil
        )
    }

    func projectPromptHistory(for name: String, includeContent: Bool = true) async -> [PromptRecord] {
        (try? await usageStore.projectPromptHistory(projectName: name, includeContent: includeContent)) ?? []
    }

    func projectPromptHistoryPage(
        for name: String,
        limit: Int,
        offset: Int,
        includeContent: Bool = true,
        query: String = "",
        kindFilter: PromptHistoryKindFilter = .all
    ) async -> PromptHistoryPage {
        (try? await usageStore.projectPromptHistoryPage(
            projectName: name,
            limit: limit,
            offset: offset,
            includeContent: includeContent,
            query: query,
            kindFilter: kindFilter,
            bookmarkedIds: savedPromptSourceIds
        )) ?? .empty(limit: limit, offset: offset)
    }

    var savedPromptSourceIds: Set<String> {
        Set(savedPrompts.compactMap(\.sourcePromptId))
    }

    func projectPromptCountsByDay(
        for name: String,
        start: Date,
        end: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async -> [Date: Int] {
        (try? await usageStore.projectPromptCountsByDay(
            projectName: name,
            start: start,
            end: end,
            calendar: calendar
        )) ?? [:]
    }

    private func cacheProjectDetail(_ detail: ProjectDetailSnapshot) {
        projectDetailCache[detail.projectName] = CachedProjectDetail(
            detail: detail,
            eventsSignature: eventSignature
        )
    }

    nonisolated private static func eventsSignature(_ events: [UsageEvent]) -> String {
        "\(events.count)|\(events.last?.id ?? "none")"
    }

    nonisolated private static func computeProjectDetailSnapshot(
        projectName: String?,
        from events: [UsageEvent],
        referenceDate: Date,
        calendar: Calendar
    ) async -> ProjectDetailSnapshot? {
        guard let projectName else { return nil }
        return await Task.detached(priority: .utility) {
            Self.makeProjectDetailSnapshot(
                projectName: projectName,
                from: events,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }.value
    }

    nonisolated private static func makeProjectDetailSnapshot(
        projectName: String,
        from events: [UsageEvent],
        referenceDate: Date,
        calendar: Calendar
    ) -> ProjectDetailSnapshot? {
        let started = Date()
        let projectEvents = events.filter { $0.projectName == projectName }
        let days = Self.projectDetailWindowDays(
            projectEvents: projectEvents,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let detail = UsageAggregator.makeProjectDetail(
            projectName: projectName,
            from: events,
            referenceDate: referenceDate,
            calendar: calendar,
            days: days
        )
        TokenBarTelemetry.timing(
            "project.detail.compute_snapshot",
            startedAt: started,
            metadata: "project=\(projectName) project_events=\(projectEvents.count) window_days=\(days) detail=\(detail != nil)"
        )
        return detail
    }

    nonisolated private static func projectDetailWindowDays(
        projectEvents: [UsageEvent],
        referenceDate: Date,
        calendar: Calendar
    ) -> Int {
        guard let earliest = projectEvents.map(\.timestamp).min() else { return 30 }
        let earliestDay = calendar.startOfDay(for: earliest)
        let todayStart = calendar.startOfDay(for: referenceDate)
        let rawDays = calendar.dateComponents([.day], from: earliestDay, to: todayStart).day ?? 29
        return max(30, rawDays + 1)
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
        let nextRefreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: diagnostics.lastIndexedAt,
            lastRebuildError: diagnostics.rebuildError,
            refreshInterval: refreshInterval
        )
        guard refreshState != nextRefreshState || diagnostics.refreshState != nextRefreshState else {
            return
        }
        refreshState = nextRefreshState
        diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: diagnostics.dataSourceStatuses,
            lastIndexedAt: diagnostics.lastIndexedAt,
            lastUIRefreshAt: diagnostics.lastUIRefreshAt,
            lastCheckpointID: diagnostics.lastCheckpointID,
            lastCheckpointEventsAdded: diagnostics.lastCheckpointEventsAdded,
            lastCheckpointPromptsAdded: diagnostics.lastCheckpointPromptsAdded,
            parserWarningCount: diagnostics.parserWarningCount,
            refreshState: nextRefreshState,
            rebuildError: diagnostics.rebuildError
        )
    }

    func rebuildPopoverSnapshot(trigger: String = "manual") {
        let started = Date()
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics
        )
        TokenBarTelemetry.timing(
            "runtime.popover_snapshot.rebuild",
            startedAt: started,
            metadata: "trigger=\(trigger) events=\(events.count)"
        )
    }

    func addCustomSource(
        name: String,
        engine: CustomSourceEngine,
        directory: String,
        globPattern: String,
        format: CustomSourceFormat,
        displayAgent: String,
        fieldMapping: CustomSourceFieldMapping = .default
    ) async -> CustomSourceSaveResult {
        let started = Date()
        let effectiveGlobPattern = globPattern.isEmpty ? engine.defaultGlobPattern : globPattern
        let existing = customSources.first {
            CustomSourceRecord.sourcePathKey(directory: $0.directory, globPattern: $0.globPattern)
            == CustomSourceRecord.sourcePathKey(directory: directory, globPattern: effectiveGlobPattern)
        }
        let source = CustomSourceRecord(
            id: existing?.id ?? UUID().uuidString,
            name: name.isEmpty ? "Custom Source" : name,
            engine: engine,
            directory: directory,
            globPattern: effectiveGlobPattern,
            format: format,
            displayAgent: displayAgent.isEmpty ? engine.displayName : displayAgent,
            enabled: existing?.enabled ?? true,
            fieldMapping: fieldMapping,
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            try await usageStore.upsertCustomSource(source)
            if let existing,
               existing.engine != source.engine || existing.format != source.format || existing.fieldMapping != source.fieldMapping {
                try await usageStore.deleteCustomSourceData(id: existing.id)
                await publishCurrentStoreState(refreshState: .refreshing)
            }
            customSources = await loadCustomSources()
            let trigger = existing == nil ? "custom-source-add" : "custom-source-deduplicate"
            publishCustomSourceRefreshQueued(trigger: trigger, sources: [source])
            scheduleCustomSourceRefresh(trigger: trigger)
            TokenBarTelemetry.event(
                "custom_source.add",
                metadata: "name=\(source.name) deduplicated=\(existing != nil)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return .saved(name: source.name, deduplicated: existing != nil)
        } catch {
            TokenBarTelemetry.event("custom_source.add", metadata: "name=\(source.name)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
            return .failed(String(describing: error))
        }
    }

    func updateCustomSource(
        _ source: CustomSourceRecord,
        name: String,
        engine: CustomSourceEngine,
        directory: String,
        globPattern: String,
        format: CustomSourceFormat,
        displayAgent: String,
        fieldMapping: CustomSourceFieldMapping
    ) async -> CustomSourceSaveResult {
        let started = Date()
        var updated = source
        updated.name = name
        updated.engine = engine
        updated.directory = directory
        updated.globPattern = globPattern.isEmpty ? engine.defaultGlobPattern : globPattern
        updated.format = format
        updated.displayAgent = displayAgent.isEmpty ? engine.displayName : displayAgent
        updated.fieldMapping = fieldMapping
        let requiresReindex = source.engine != updated.engine
            || source.sourcePathKey != updated.sourcePathKey
            || source.format != updated.format
            || source.fieldMapping != updated.fieldMapping
        do {
            try await usageStore.upsertCustomSource(updated)
            if requiresReindex {
                try await usageStore.deleteCustomSourceData(id: source.id)
            }
            customSources = await loadCustomSources()
            let deduplicated = !customSources.contains { $0.id == source.id }
            if requiresReindex, deduplicated,
               let retained = customSources.first(where: { $0.sourcePathKey == updated.sourcePathKey }) {
                try await usageStore.deleteCustomSourceData(id: retained.id)
            }
            if requiresReindex {
                await publishCurrentStoreState(refreshState: .refreshing)
            }
            let trigger = deduplicated ? "custom-source-deduplicate" : "custom-source-update"
            publishCustomSourceRefreshQueued(trigger: trigger, sources: [updated])
            scheduleCustomSourceRefresh(trigger: trigger)
            TokenBarTelemetry.event(
                "custom_source.update",
                metadata: "name=\(updated.name) deduplicated=\(deduplicated) reindex=\(requiresReindex)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return .saved(name: updated.name, deduplicated: deduplicated)
        } catch {
            TokenBarTelemetry.event("custom_source.update", metadata: "name=\(updated.name)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
            return .failed(String(describing: error))
        }
    }

    private func scheduleCustomSourceRefresh(trigger: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.restartFileWatcher()
            while self.indexingState.isActive || self.activeRefreshTrigger != nil {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await self.refresh(trigger: trigger)
        }
    }

    func reparseAllSources() async {
        let started = Date()
        guard !indexingState.isActive else {
            TokenBarTelemetry.event(
                "diagnostics.reparse_all.skip",
                metadata: "reason=initial_index_active",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }
        do {
            try await usageStore.reparseAll()
            let referenceDate = Date()
            let state = await usageStore.state(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian), includePrompts: false)
            publishStoreState(
                state,
                statuses: diagnostics.dataSourceStatuses,
                referenceDate: referenceDate,
                refreshState: .refreshing
            )
            startInitialIndexing(reason: "reparse-all")
            TokenBarTelemetry.event(
                "diagnostics.reparse_all",
                metadata: "mode=initial_index cpu_budget=\(IndexingResourceBudget.initialIndexCPUPercent)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
        } catch {
            TokenBarTelemetry.event("diagnostics.reparse_all", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    /// CL-P1-021: wipe stored prompts. After this returns the prompts list is
    /// empty and the SQLite file shrinks via VACUUM.
    func wipePrompts() async throws {
        let started = Date()
        do {
            try await usageStore.wipePrompts()
            await refresh(trigger: "wipe-prompts")
            TokenBarTelemetry.event("diagnostics.wipe_prompts", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("diagnostics.wipe_prompts", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
            throw error
        }
    }

    func reparseSource(_ sourcePath: String) async {
        let started = Date()
        do {
            try await usageStore.reparseSource(sourcePath)
            await refresh(trigger: "reparse-source")
            TokenBarTelemetry.event("diagnostics.reparse_source", metadata: "source=\(sourcePath)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("diagnostics.reparse_source", metadata: "source=\(sourcePath)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    private func applyRetentionAndReload(referenceDate: Date) async {
        await applyRetention(referenceDate: referenceDate)
        let state = await usageStore.state(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian), includePrompts: false)
        events = state.events
        prompts = []
        publishCollectionMetadata(from: state)
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if let selectedProjectName {
            let computedProjectDetail = await Self.computeProjectDetailSnapshot(
                projectName: selectedProjectName,
                from: state.events,
                referenceDate: referenceDate,
                calendar: Calendar(identifier: .gregorian)
            )
            if self.selectedProjectName == selectedProjectName {
                projectDetail = computedProjectDetail
                if let computedProjectDetail {
                    cacheProjectDetail(computedProjectDetail)
                }
            }
        }
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics,
            referenceDate: referenceDate,
            calendar: Calendar(identifier: .gregorian)
        )
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
        let started = Date()
        var updated = source
        updated.enabled.toggle()
        do {
            try await usageStore.upsertCustomSource(updated)
            if !updated.enabled {
                try await usageStore.deleteCustomSourceData(id: updated.id)
                await publishCurrentStoreState(refreshState: .refreshing)
            }
            customSources = await loadCustomSources()
            await restartFileWatcher()
            await refresh(trigger: "custom-source-toggle")
            TokenBarTelemetry.event("custom_source.toggle", metadata: "name=\(updated.name) enabled=\(updated.enabled)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("custom_source.toggle", metadata: "name=\(updated.name)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    func removeCustomSource(id: String) async {
        let started = Date()
        do {
            try await usageStore.deleteCustomSource(id: id)
            customSources = await loadCustomSources()
            await publishCurrentStoreState(refreshState: .refreshing)
            await restartFileWatcher()
            await refresh(trigger: "custom-source-remove")
            TokenBarTelemetry.event("custom_source.remove", metadata: "id=\(id)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("custom_source.remove", metadata: "id=\(id)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    private func publishCurrentStoreState(refreshState nextRefreshState: RefreshState) async {
        let referenceDate = Date()
        let state = await usageStore.state(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian), includePrompts: false)
        publishStoreState(
            state,
            statuses: diagnostics.dataSourceStatuses,
            referenceDate: referenceDate,
            refreshState: nextRefreshState
        )
    }

    private func publishCollectionMetadata(from state: UsageStoreState) {
        eventCount = state.eventCount
        promptCount = state.promptCount
        eventSignature = state.eventSignature
        promptSignature = state.promptSignature
    }

    private func publishStoreState(
        _ state: UsageStoreState,
        statuses: [UsageDataSourceStatus],
        referenceDate: Date,
        refreshState nextRefreshState: RefreshState,
        rebuildError: String? = nil
    ) {
        events = state.events
        prompts = []
        publishCollectionMetadata(from: state)
        sourceWarnings = state.warnings
        snapshot = state.snapshot
        lastCheckpoint = state.lastCheckpoint
        if selectedProjectName == nil {
            selectedProjectName = state.snapshot.topProjects.first?.name
        }
        projectDetail = selectedProjectName.flatMap {
            Self.makeProjectDetailSnapshot(
                projectName: $0,
                from: state.events,
                referenceDate: referenceDate,
                calendar: Calendar(identifier: .gregorian)
            )
        }
        refreshState = nextRefreshState
        diagnostics = DiagnosticsSnapshot(
            dataSourceStatuses: statuses.sorted { $0.sourceName < $1.sourceName },
            lastIndexedAt: state.lastIndexedAt,
            lastUIRefreshAt: referenceDate,
            lastCheckpointID: state.lastCheckpoint?.id,
            lastCheckpointEventsAdded: state.lastCheckpoint?.eventsAdded ?? 0,
            lastCheckpointPromptsAdded: state.lastCheckpoint?.promptsAdded ?? 0,
            parserWarningCount: state.warnings.count,
            refreshState: nextRefreshState,
            rebuildError: rebuildError ?? state.lastRebuildError
        )
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics,
            referenceDate: referenceDate,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    private func diagnosticsSnapshot(
        from current: DiagnosticsSnapshot,
        statuses: [UsageDataSourceStatus],
        refreshState nextRefreshState: RefreshState,
        rebuildError: String?
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            dataSourceStatuses: statuses.sorted { $0.sourceName < $1.sourceName },
            lastIndexedAt: current.lastIndexedAt,
            lastUIRefreshAt: Date(),
            lastCheckpointID: current.lastCheckpointID,
            lastCheckpointEventsAdded: current.lastCheckpointEventsAdded,
            lastCheckpointPromptsAdded: current.lastCheckpointPromptsAdded,
            parserWarningCount: current.parserWarningCount,
            refreshState: nextRefreshState,
            rebuildError: rebuildError
        )
    }

    private func publishDiagnosticsDuringInitialIndex(statuses: [UsageDataSourceStatus], rebuildError: String?) {
        refreshState = .refreshing
        diagnostics = diagnosticsSnapshot(
            from: diagnostics,
            statuses: statuses,
            refreshState: .refreshing,
            rebuildError: rebuildError
        )
        popoverSnapshot = TokenBarPopoverSnapshot.make(
            snapshot: snapshot,
            events: events,
            diagnostics: diagnostics
        )
    }

    private func publishCustomSourceRefreshQueued(trigger: String, sources: [CustomSourceRecord]) {
        guard !indexingState.isActive else { return }
        let visibleSources = sources.isEmpty ? customSources : sources
        indexingState = TokenBarIndexingState(
            phase: .queued,
            sources: visibleSources.map { source in
                TokenBarIndexingSourceState(
                    sourceName: source.name,
                    rootPath: source.directory,
                    phase: .pending,
                    discoveredFileCount: 0,
                    eventsIndexed: 0,
                    promptsIndexed: 0,
                    message: "Waiting to scan"
                )
            },
            startedAt: Date(),
            endedAt: nil,
            checkedFiles: 0,
            eventsIndexed: 0,
            promptsIndexed: 0,
            message: refreshIndexingMessage(for: trigger, phase: .queued),
            activeSourceName: nil,
            cpuBudgetPercent: IndexingResourceBudget.initialIndexCPUPercent
        )
        refreshState = .refreshing
        diagnostics = diagnosticsSnapshot(
            from: diagnostics,
            statuses: diagnostics.dataSourceStatuses,
            refreshState: .refreshing,
            rebuildError: nil
        )
    }

    private func publishRefreshIndexingDiscovery(
        trigger: String,
        sources: [any InspectableUsageEventSource],
        startedAt: Date,
        resourceThrottle: IndexingResourceThrottle?
    ) {
        let sources = progressSources(from: sources, trigger: trigger)
        indexingState = TokenBarIndexingState(
            phase: .discovering,
            sources: sources.map {
                TokenBarIndexingSourceState(
                    sourceName: $0.sourceName,
                    rootPath: $0.rootPath,
                    phase: .pending,
                    discoveredFileCount: 0,
                    eventsIndexed: 0,
                    promptsIndexed: 0,
                    message: nil
                )
            },
            startedAt: startedAt,
            endedAt: nil,
            checkedFiles: 0,
            eventsIndexed: 0,
            promptsIndexed: 0,
            message: refreshIndexingMessage(for: trigger, phase: .discovering),
            activeSourceName: nil,
            cpuBudgetPercent: resourceThrottle != nil ? IndexingResourceBudget.initialIndexCPUPercent : nil
        )
    }

    private func publishRefreshIndexingProgress(
        trigger: String,
        statuses: [UsageDataSourceStatus],
        startedAt: Date,
        resourceThrottle: IndexingResourceThrottle?
    ) {
        let statuses = progressStatuses(from: statuses, trigger: trigger)
        let sourceStates = statuses.map { status in
            TokenBarIndexingSourceState(
                sourceName: status.sourceName,
                rootPath: status.rootPath,
                phase: status.discoveredFileCount > 0 ? .scanning : .skipped,
                discoveredFileCount: status.discoveredFileCount,
                eventsIndexed: 0,
                promptsIndexed: 0,
                message: sourceMessage(for: status)
            )
        }
        indexingState = TokenBarIndexingState(
            phase: .indexing,
            sources: sourceStates,
            startedAt: startedAt,
            endedAt: nil,
            checkedFiles: statuses.reduce(0) { $0 + $1.discoveredFileCount },
            eventsIndexed: 0,
            promptsIndexed: 0,
            message: refreshIndexingMessage(for: trigger, phase: .indexing),
            activeSourceName: nil,
            cpuBudgetPercent: resourceThrottle != nil ? IndexingResourceBudget.initialIndexCPUPercent : nil
        )
        publishDiagnosticsDuringInitialIndex(statuses: statuses, rebuildError: nil)
    }

    private func publishRefreshIndexingCompletion(
        trigger: String,
        statuses: [UsageDataSourceStatus],
        result: CheckpointRunResult,
        endedAt: Date
    ) {
        let statuses = progressStatuses(from: statuses, trigger: trigger)
        let failedSource = result.failure?.sourceName
        let eventsAdded = result.checkpoint?.eventsAdded ?? 0
        let promptsAdded = result.checkpoint?.promptsAdded ?? 0
        let sourceStates = statuses.map { status in
            let phase: TokenBarIndexingSourcePhase
            let message: String
            if status.sourceName == failedSource {
                phase = .failed
                message = result.failure?.message ?? "Failed"
            } else if status.isReadable || status.discoveredFileCount > 0 {
                phase = .indexed
                message = "Indexed"
            } else {
                phase = .skipped
                message = sourceMessage(for: status)
            }
            return TokenBarIndexingSourceState(
                sourceName: status.sourceName,
                rootPath: status.rootPath,
                phase: phase,
                discoveredFileCount: status.discoveredFileCount,
                eventsIndexed: statuses.count == 1 ? eventsAdded : 0,
                promptsIndexed: statuses.count == 1 ? promptsAdded : 0,
                message: message
            )
        }
        indexingState = TokenBarIndexingState(
            phase: result.failure == nil ? .completed : .failed,
            sources: sourceStates,
            startedAt: indexingState.startedAt,
            endedAt: endedAt,
            checkedFiles: statuses.reduce(0) { $0 + $1.discoveredFileCount },
            eventsIndexed: eventsAdded,
            promptsIndexed: promptsAdded,
            message: refreshIndexingMessage(for: trigger, phase: result.failure == nil ? .completed : .failed),
            activeSourceName: nil,
            cpuBudgetPercent: indexingState.cpuBudgetPercent
        )
        if result.failure == nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                await MainActor.run {
                    guard let self, self.indexingState.phase == .completed else { return }
                    self.indexingState = .idle
                }
            }
        }
    }

    private func refreshIndexingMessage(for trigger: String, phase: TokenBarIndexingPhase) -> String {
        let noun = trigger == "reparse-source" ? "source" : "custom sources"
        switch phase {
        case .queued:
            return "\(noun.capitalized) saved. Waiting for the indexer."
        case .discovering:
            return "Discovering \(noun) before indexing."
        case .indexing:
            return "Indexing \(noun) with a \(Int(IndexingResourceBudget.initialIndexCPUPercent))% CPU budget."
        case .completed:
            return "\(noun.capitalized) index is ready."
        case .failed:
            return "\(noun.capitalized) indexing finished with source issues."
        default:
            return "Indexing \(noun)."
        }
    }

    private func shouldShowRefreshIndexingProgress(for trigger: String) -> Bool {
        (trigger.hasPrefix("custom-source-") && trigger != "custom-source-remove") || trigger == "reparse-source"
    }

    private func progressSources(
        from sources: [any InspectableUsageEventSource],
        trigger: String
    ) -> [any InspectableUsageEventSource] {
        guard trigger.hasPrefix("custom-source-") else { return sources }
        let builtInKeys = Set(builtInSources.map { sourceKey(name: $0.sourceName, rootPath: $0.rootPath) })
        let custom = sources.filter { !builtInKeys.contains(sourceKey(name: $0.sourceName, rootPath: $0.rootPath)) }
        return custom.isEmpty ? sources : custom
    }

    private func progressStatuses(
        from statuses: [UsageDataSourceStatus],
        trigger: String
    ) -> [UsageDataSourceStatus] {
        guard trigger.hasPrefix("custom-source-") else { return statuses }
        let builtInKeys = Set(builtInSources.map { sourceKey(name: $0.sourceName, rootPath: $0.rootPath) })
        let custom = statuses.filter { !builtInKeys.contains(sourceKey(name: $0.sourceName, rootPath: $0.rootPath)) }
        return custom.isEmpty ? statuses : custom
    }

    private func sourceKey(name: String, rootPath: String) -> String {
        "\(name)|\(rootPath)"
    }

    private func markIndexingSource(
        _ sourceName: String,
        phase: TokenBarIndexingSourcePhase,
        message: String?
    ) {
        updateIndexingSource(sourceName, phase: phase, message: message)
        publishIndexingTotals(
            phase: .indexing,
            checkedFiles: indexingState.checkedFiles,
            eventsIndexed: indexingState.eventsIndexed,
            promptsIndexed: indexingState.promptsIndexed,
            activeSourceName: sourceName,
            message: message
        )
    }

    private func updateIndexingSource(
        _ sourceName: String,
        phase: TokenBarIndexingSourcePhase? = nil,
        discoveredFileCount: Int? = nil,
        eventsIndexed: Int? = nil,
        promptsIndexed: Int? = nil,
        message: String? = nil
    ) {
        var next = indexingState
        next.sources = next.sources.map { source in
            guard source.sourceName == sourceName else { return source }
            var mutable = source
            if let phase { mutable.phase = phase }
            if let discoveredFileCount { mutable.discoveredFileCount = discoveredFileCount }
            if let eventsIndexed { mutable.eventsIndexed = eventsIndexed }
            if let promptsIndexed { mutable.promptsIndexed = promptsIndexed }
            if let message { mutable.message = message }
            return mutable
        }
        indexingState = next
    }

    private func publishIndexingTotals(
        phase: TokenBarIndexingPhase,
        checkedFiles: Int,
        eventsIndexed: Int,
        promptsIndexed: Int,
        activeSourceName: String?,
        message: String?,
        endedAt: Date? = nil
    ) {
        var next = indexingState
        next.phase = phase
        next.checkedFiles = checkedFiles
        next.eventsIndexed = eventsIndexed
        next.promptsIndexed = promptsIndexed
        next.activeSourceName = activeSourceName
        next.message = message
        if let endedAt {
            next.endedAt = endedAt
        }
        indexingState = next
    }

    private func sourceMessage(for status: UsageDataSourceStatus) -> String {
        if !status.isReadable && status.discoveredFileCount == 0 {
            return "Not found or no access"
        }
        if status.discoveredFileCount == 0 {
            return "No files discovered"
        }
        return "\(status.discoveredFileCount.formatted()) files discovered"
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
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

    private func loadSavedPrompts() async -> [SavedPrompt] {
        (try? await usageStore.allSavedPrompts()) ?? []
    }

    func applySavedPrompt(_ prompt: SavedPrompt, previousSlug: String?) async throws {
        try await usageStore.upsertSavedPrompt(prompt)
        try savedPromptCommandSync.apply(prompt, previousSlug: previousSlug)
        savedPrompts = await loadSavedPrompts()
        TokenBarTelemetry.event(
            "saved_prompt.apply",
            metadata: "slug=\(prompt.slug) renamed=\(previousSlug.map { $0 != prompt.slug } ?? false)",
            success: true
        )
    }

    func deleteSavedPrompt(_ prompt: SavedPrompt) async throws {
        try await usageStore.deleteSavedPrompt(id: prompt.id)
        try savedPromptCommandSync.remove(slug: prompt.slug)
        savedPrompts = await loadSavedPrompts()
        TokenBarTelemetry.event(
            "saved_prompt.delete",
            metadata: "slug=\(prompt.slug)",
            success: true
        )
    }

    private func activeSources() async -> [any InspectableUsageEventSource] {
        let custom = customSources
            .filter(\.enabled)
            .map { CustomUsageEventSource(record: $0) as any InspectableUsageEventSource }
        return builtInSources + custom
    }

    private func checkpointEngine(
        for sources: [any InspectableUsageEventSource],
        resourceThrottle: IndexingResourceThrottle? = nil
    ) -> CheckpointEngine {
        if let resourceThrottle {
            return CheckpointEngine(
                sources: sources,
                store: usageStore,
                resourceThrottle: resourceThrottle,
                stateIncludesPrompts: false
            )
        }
        let signature = sources.map { "\($0.sourceName):\($0.rootPath)" }.joined(separator: "|")
        if checkpointSourceSignature != signature {
            checkpointSourceSignature = signature
            checkpointEngine = CheckpointEngine(sources: sources, store: usageStore, stateIncludesPrompts: false)
        }
        if let checkpointEngine {
            return checkpointEngine
        }
        let engine = CheckpointEngine(sources: sources, store: usageStore, stateIncludesPrompts: false)
        checkpointEngine = engine
        return engine
    }

    private func backgroundThrottle(for trigger: String) -> IndexingResourceThrottle? {
        if trigger.hasPrefix("custom-source-") || trigger == "reparse-source" {
            return IndexingResourceThrottle(budget: .initialIndex)
        }
        switch trigger {
        case "bootstrap-background", "reparse-all", "file-change":
            return IndexingResourceThrottle(budget: .background)
        default:
            return nil
        }
    }

    private func restartFileWatcher() async {
        await fileWatcher?.stop()
        let customPaths = customSources
            .filter(\.enabled)
            .map(\.directory)
        let watcher = RecursiveFSEventsWatcher(
            paths: ["~/.codex/sessions", "~/.claude/projects", "~/.hermes", "~/.gemini", "~/.local/share/opencode"] + customPaths
        ) { [weak self] in
            await self?.handleSourceChange()
        }
        fileWatcher = watcher
        let watcherStartedAt = Date()
        lastAutomaticRefreshAt = watcherStartedAt
        suppressSourceChangesUntil = watcherStartedAt.addingTimeInterval(15)
        try? await watcher.start()
    }

    private func handleSourceChange() async {
        let now = Date()
        if let suppressSourceChangesUntil, now < suppressSourceChangesUntil {
            TokenBarTelemetry.event(
                "runtime.source_change.skip_startup_grace",
                metadata: "remaining_ms=\(Int(suppressSourceChangesUntil.timeIntervalSince(now) * 1000))",
                success: true
            )
            updateRefreshState()
            return
        }
        suppressSourceChangesUntil = nil

        guard let cadence = refreshInterval.refreshCadence else {
            updateRefreshState()
            return
        }

        let elapsed = lastAutomaticRefreshAt.map { now.timeIntervalSince($0) } ?? cadence
        guard elapsed < cadence else {
            await refresh(trigger: "file-change")
            return
        }
        guard intervalRefreshTask == nil else { return }

        let delay = max(0.5, cadence - elapsed)
        intervalRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh(trigger: "interval")
        }
        updateRefreshState()
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
                GeminiUsageEventSource(),
                OpenCodeUsageEventSource(),
            ]
        return TokenBarRuntimeModel(
            settingsStore: settingsStore,
            usageStore: usageStore,
            sources: sources
        )
    }
}
