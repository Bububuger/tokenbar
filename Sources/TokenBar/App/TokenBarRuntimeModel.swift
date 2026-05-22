import AppKit
import Foundation
import TokenBarCore

enum ProjectSwitchPhase: String, Sendable {
    case snap
    case stream
    case done
}

struct ProjectSwitchState: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectName: String
    let phase: ProjectSwitchPhase
    let progress: Double
}

@MainActor
final class TokenBarRuntimeModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var diagnostics: DiagnosticsSnapshot
    @Published private(set) var prompts: [PromptRecord]
    @Published private(set) var lastCheckpoint: CheckpointSummary?
    @Published private(set) var refreshState: RefreshState
    @Published private(set) var selectedProjectName: String?
    @Published private(set) var projectDetail: ProjectDetailSnapshot?
    @Published private(set) var projectSwitchState: ProjectSwitchState?
    @Published private(set) var customSources: [CustomSourceRecord]
    @Published private(set) var events: [UsageEvent]
    @Published private(set) var sourceWarnings: [UsageSourceWarning]
    @Published private(set) var popoverSnapshot: TokenBarPopoverSnapshot
    @Published var mainRoute: TokenBarMainRoute = .today

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
    private var intervalRefreshTask: Task<Void, Never>?
    // CL-P0-026: scheduled to fire just after local midnight so the Today KPI
    // resets, the 30d strip shifts, and the Popover briefly shows a "Day
    // changed — refreshing…" hint. `dayChangedAt` is published so views can
    // observe it and animate a transient banner.
    private var midnightTask: Task<Void, Never>?
    private var projectSwitchTask: Task<Void, Never>?
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
        self.projectSwitchState = nil
        self.prompts = []
        self.lastCheckpoint = nil
        self.events = []
        self.sourceWarnings = []
        self.popoverSnapshot = .empty
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
        var stageStarted = Date()
        await loadPersistedSnapshot()
        TokenBarTelemetry.timing(
            "runtime.bootstrap.stage.load_persisted_snapshot",
            startedAt: stageStarted,
            metadata: "events=\(events.count) prompts=\(prompts.count) warnings=\(sourceWarnings.count)"
        )
        stageStarted = Date()
        await restartFileWatcher()
        TokenBarTelemetry.timing("runtime.bootstrap.stage.restart_file_watcher", startedAt: stageStarted)
        scheduleNextMidnightRollover()
        observeSystemPowerEvents()
        TokenBarTelemetry.event(
            "runtime.bootstrap",
            metadata: "events=\(events.count) prompts=\(prompts.count) warnings=\(sourceWarnings.count)",
            success: diagnostics.rebuildError == nil,
            elapsed: Date().timeIntervalSince(started),
            error: diagnostics.rebuildError
        )
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            await self?.refresh(trigger: "bootstrap-background")
        }
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
        await applyRetention(referenceDate: now)
        TokenBarTelemetry.timing("runtime.load_persisted.stage.apply_retention", startedAt: stageStarted)
        stageStarted = Date()
        let state = await usageStore.state(referenceDate: now, calendar: calendar)
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.usage_store_state",
            startedAt: stageStarted,
            metadata: "events=\(state.events.count) prompts=\(state.prompts.count) warnings=\(state.warnings.count)"
        )
        stageStarted = Date()
        events = state.events
        prompts = state.prompts
        sourceWarnings = state.warnings
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
            metadata: "events=\(events.count)"
        )
        TokenBarTelemetry.timing(
            "runtime.load_persisted.stage.publish_diagnostics",
            startedAt: stageStarted,
            metadata: "refresh_state=\(refreshState)"
        )
        TokenBarTelemetry.timing(
            "runtime.load_persisted.total",
            startedAt: started,
            metadata: "events=\(events.count) prompts=\(prompts.count) warnings=\(sourceWarnings.count)"
        )
    }

    func refresh(trigger: String = "manual") async {
        let started = Date()
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
        let engine = checkpointEngine(for: sources)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.checkpoint_engine_prepare",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger)"
        )
        stageStarted = Date()
        _ = await engine.run(trigger: trigger, startedAt: now, referenceDate: now, calendar: Calendar(identifier: .gregorian))
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.checkpoint_engine_run",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger)"
        )
        stageStarted = Date()
        await applyRetention(referenceDate: now)
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.apply_retention",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger)"
        )
        stageStarted = Date()
        let state = await usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian))
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.usage_store_state",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) events=\(state.events.count) prompts=\(state.prompts.count) warnings=\(state.warnings.count)"
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
        prompts = state.prompts
        sourceWarnings = state.warnings
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
            metadata: "trigger=\(trigger) events=\(events.count)"
        )
        TokenBarTelemetry.timing(
            "runtime.refresh.stage.publish_diagnostics",
            startedAt: stageStarted,
            metadata: "trigger=\(trigger) refresh_state=\(refreshState)"
        )
        TokenBarTelemetry.event(
            "runtime.refresh",
            metadata: "trigger=\(trigger) events=\(state.events.count) prompts=\(state.prompts.count) warnings=\(state.warnings.count)",
            success: state.lastRebuildError == nil,
            elapsed: Date().timeIntervalSince(started),
            error: state.lastRebuildError
        )
    }

    func openProject(named name: String) {
        let started = Date()
        if selectedProjectName == name, projectDetail?.projectName == name, projectSwitchState == nil {
            mainRoute = .project(name)
            TokenBarTelemetry.event("project.open.skip_current", metadata: "project=\(name)", success: true)
            return
        }

        projectSwitchTask?.cancel()
        let switchID = UUID()
        TokenBarTelemetry.event("project.open", metadata: "project=\(name)", success: true)
        selectedProjectName = name
        mainRoute = .project(name)
        let previewNow = Date()
        projectDetail = UsageAggregator.makeProjectDetail(
            projectName: name,
            from: events,
            referenceDate: previewNow,
            calendar: Calendar(identifier: .gregorian)
        )
        projectSwitchState = ProjectSwitchState(id: switchID, projectName: name, phase: .snap, progress: 0.08)

        projectSwitchTask = Task {
            let now = Date()
            async let stateTask = usageStore.state(referenceDate: now, calendar: Calendar(identifier: .gregorian))

            func publishSwitch(phase: ProjectSwitchPhase, progress: Double) async {
                await MainActor.run {
                    guard self.projectSwitchState?.id == switchID else { return }
                    self.projectSwitchState = ProjectSwitchState(
                        id: switchID,
                        projectName: name,
                        phase: phase,
                        progress: progress
                    )
                }
            }

            func sleepUntil(_ targetElapsed: TimeInterval) async {
                let remaining = targetElapsed - Date().timeIntervalSince(started)
                guard remaining > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            let steps: [(time: TimeInterval, phase: ProjectSwitchPhase, progress: Double)] = [
                (0.08, .snap, 0.16),
                (0.15, .stream, 0.26),
                (0.25, .stream, 0.40),
                (0.36, .stream, 0.56),
                (0.50, .stream, 0.74),
                (0.64, .stream, 0.90),
            ]

            for step in steps {
                await sleepUntil(step.time)
                guard !Task.isCancelled else { return }
                await publishSwitch(phase: step.phase, progress: step.progress)
            }

            let state = await stateTask
            let detail = UsageAggregator.makeProjectDetail(
                projectName: name,
                from: state.events,
                referenceDate: now,
                calendar: Calendar(identifier: .gregorian)
            )

            await MainActor.run {
                guard self.projectSwitchState?.id == switchID else { return }
                prompts = state.prompts
                events = state.events
                sourceWarnings = state.warnings
                projectDetail = detail
                popoverSnapshot = TokenBarPopoverSnapshot.make(
                    snapshot: snapshot,
                    events: events,
                    diagnostics: diagnostics,
                    referenceDate: now,
                    calendar: Calendar(identifier: .gregorian)
                )
            }

            await sleepUntil(0.72)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.projectSwitchState?.id == switchID else { return }
                projectSwitchState = ProjectSwitchState(id: switchID, projectName: name, phase: .done, progress: 1.0)
                TokenBarTelemetry.event(
                    "project.detail.load",
                    metadata: "project=\(name) events=\(detail?.summary.totalTokens ?? 0)",
                    success: detail != nil,
                    elapsed: Date().timeIntervalSince(started)
                )
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.projectSwitchState?.id == switchID {
                    self.projectSwitchState = nil
                }
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
        directory: String,
        globPattern: String,
        format: CustomSourceFormat,
        displayAgent: String,
        fieldMapping: CustomSourceFieldMapping = .default
    ) async {
        let started = Date()
        let source = CustomSourceRecord(
            name: name.isEmpty ? "Custom Source" : name,
            directory: directory,
            globPattern: globPattern.isEmpty ? "**/*.jsonl" : globPattern,
            format: format,
            displayAgent: displayAgent.isEmpty ? "Custom" : displayAgent,
            fieldMapping: fieldMapping
        )
        do {
            try await usageStore.upsertCustomSource(source)
            customSources = await loadCustomSources()
            await restartFileWatcher()
            await refresh(trigger: "custom-source-add")
            TokenBarTelemetry.event("custom_source.add", metadata: "name=\(source.name)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("custom_source.add", metadata: "name=\(source.name)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    func updateCustomSource(
        _ source: CustomSourceRecord,
        name: String,
        directory: String,
        globPattern: String,
        format: CustomSourceFormat,
        displayAgent: String,
        fieldMapping: CustomSourceFieldMapping
    ) async {
        let started = Date()
        var updated = source
        updated.name = name
        updated.directory = directory
        updated.globPattern = globPattern.isEmpty ? "**/*.jsonl" : globPattern
        updated.format = format
        updated.displayAgent = displayAgent
        updated.fieldMapping = fieldMapping
        do {
            try await usageStore.upsertCustomSource(updated)
            customSources = await loadCustomSources()
            await restartFileWatcher()
            await refresh(trigger: "custom-source-update")
            TokenBarTelemetry.event("custom_source.update", metadata: "name=\(updated.name)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("custom_source.update", metadata: "name=\(updated.name)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
    }

    func reparseAllSources() async {
        let started = Date()
        do {
            try await usageStore.reparseAll()
            await refresh(trigger: "reparse-all")
            TokenBarTelemetry.event("diagnostics.reparse_all", success: true, elapsed: Date().timeIntervalSince(started))
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
            await restartFileWatcher()
            await refresh(trigger: "custom-source-remove")
            TokenBarTelemetry.event("custom_source.remove", metadata: "id=\(id)", success: true, elapsed: Date().timeIntervalSince(started))
        } catch {
            TokenBarTelemetry.event("custom_source.remove", metadata: "id=\(id)", success: false, elapsed: Date().timeIntervalSince(started), error: String(describing: error))
        }
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
            await self?.handleSourceChange()
        }
        fileWatcher = watcher
        try? await watcher.start()
    }

    private func handleSourceChange() async {
        guard let cadence = refreshInterval.refreshCadence else {
            updateRefreshState()
            return
        }

        let now = Date()
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
            ]
        return TokenBarRuntimeModel(
            settingsStore: settingsStore,
            usageStore: usageStore,
            sources: sources
        )
    }
}
