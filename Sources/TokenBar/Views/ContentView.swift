import AppKit
import SwiftUI
import TokenBarCore

struct ContentView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var selectedRange = "30d"
    @State private var sidebarProjectsCache: [UsageBreakdown] = []
    @State private var sidebarSourcesCache: [UsageBreakdown] = []
    @State private var sidebarModelsCache: [UsageBreakdown] = []
    @State private var isSidebarProjectsLoading = false
    @State private var hasSidebarProjectsLoaded = false
    @State private var detailPageData: DetailPageData?
    @State private var overviewRangeMetrics = TokenBarOverviewRangeMetrics.empty
    @State private var isOverviewRangeUpdating = false
    @State private var projectPageData: ProjectPageData?
    @State private var routeTransitionStartedAt: Date?
    @State private var routeTransitionFrom = "none"
    @State private var routeTransitionTo = "none"
    @State private var routeTransitionSequence = 0
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"

    var body: some View {
        HStack(spacing: 0) {
            TokenBarSidebar(
                activeRoute: runtimeModel.mainRoute,
                projects: sidebarProjects,
                sources: sidebarSourcesCache,
                models: sidebarModelsCache,
                warnings: warningCount,
                refreshState: runtimeModel.refreshState,
                lastIndexedAt: runtimeModel.diagnostics.lastIndexedAt,
                onSelectOverview: { runtimeModel.navigate(to: .today, source: "sidebar.overview") },
                onSelectLibrary: { runtimeModel.navigate(to: .library, source: "sidebar.library") },
                onSelectDiagnostics: { runtimeModel.navigate(to: .diagnostics, source: "sidebar.diagnostics") },
                onSelectSettings: { runtimeModel.navigate(to: .settings, source: "sidebar.settings") },
                onSelectSavedPrompts: { runtimeModel.navigate(to: .savedPrompts, source: "sidebar.saved_prompts") },
                onSelectProject: { runtimeModel.openProject(named: $0, source: "sidebar.project") },
                onSelectSource: { runtimeModel.openSource(named: $0, source: "sidebar.source") },
                onSelectModel: { runtimeModel.openModel(named: $0, source: "sidebar.model") }
            )
            .frame(width: TokenBarStyle.sidebarWidth)

            Divider()
                .overlay(TokenBarStyle.line)

            ZStack {
                TokenBarGlassBackground()
                // Route swaps cross-fade over 220ms — `.id(route)` forces
                // SwiftUI to treat each route as a distinct view so
                // `.transition(.opacity)` fires on swap.
                Group {
                    if runtimeModel.mainRoute == .settings {
                        SettingsView()
                            .environmentObject(runtimeModel)
                            .onAppear { recordRouteViewAppear(.settings) }
                    } else if runtimeModel.mainRoute == .library {
                        LibraryContainer()
                            .environmentObject(runtimeModel)
                            .onAppear { recordRouteViewAppear(.library) }
                    } else if runtimeModel.mainRoute == .savedPrompts {
                        // CL-SAVED-1: rendered outside the shared
                        // ScrollView+LazyVStack chassis. Nesting a single
                        // switch-case inside that lazy container left this
                        // route blank on first appearance until the user
                        // scrolled to force a re-measure.
                        ScrollView {
                            SavedPromptsListView()
                                .environmentObject(runtimeModel)
                                .padding(TokenBarStyle.pagePadding)
                                .onAppear { recordRouteViewAppear(.savedPrompts) }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                                switch runtimeModel.mainRoute {
                                case .today:
                                    OverviewPage(
                                        selectedRange: $selectedRange,
                                        rangeMetrics: $overviewRangeMetrics,
                                        isRangeLoading: $isOverviewRangeUpdating
                                    )
                                        .environmentObject(runtimeModel)
                                        .onAppear { recordRouteViewAppear(.today) }
                                case .diagnostics:
                                    DiagnosticsView()
                                        .environmentObject(runtimeModel)
                                        .onAppear { recordRouteViewAppear(.diagnostics) }
                                case .settings:
                                    EmptyView()
                                case .library:
                                    EmptyView()
                                case .savedPrompts:
                                    EmptyView()
                                case .project(let projectName):
                                    projectPage(projectName)
                                case .source(let sourceName):
                                    sourcePage(sourceName)
                                case .model(let modelName):
                                    modelPage(modelName)
                                }
                            }
                            .padding(TokenBarStyle.pagePadding)
                        }
                    }
                }
                .id(runtimeModel.mainRoute)
                .transition(.opacity)
            }
            .animation(.smooth(duration: 0.22), value: runtimeModel.mainRoute)
        }
        .frame(minWidth: 1280, minHeight: 980)
        .overlay {
            // Full-bleed restart theater — mounted at the root so it escapes
            // the sidebar popover's anchor and covers the whole window.
            if runtimeModel.isRestartTheaterActive {
                RestartOverlayView(
                    version: runtimeModel.restartTargetVersion ?? "",
                    onDone: { runtimeModel.isRestartTheaterActive = false }
                )
                .environmentObject(runtimeModel)
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: runtimeModel.isRestartTheaterActive)
        .foregroundStyle(TokenBarStyle.foreground)
        .background(WindowAccessor { window in
            // Stop SwiftUI/AppKit from auto-focusing the first TextField
            // (the sidebar "Search projects" field) on launch / window
            // becoming key. Setting `initialFirstResponder = nil` blocks the
            // default behavior at the source; the additional makeFirstResponder
            // call covers the case where focus was already assigned before
            // this view installed.
            window.initialFirstResponder = nil
            window.makeFirstResponder(nil)
            // Window also tries again the next time it becomes key.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                window.makeFirstResponder(nil)
            }
        })
        .task { await runtimeModel.bootstrapIfNeeded() }
        .task(id: sidebarProjectsTaskID) {
            await rebuildSidebarProjects(reason: "range_or_events")
        }
        .task(id: overviewRangeMetricsTaskID) {
            await rebuildOverviewRangeMetrics(reason: "range_or_events")
        }
        .task(id: projectPageTaskID) {
            await rebuildProjectPageData(reason: "route_range_events")
        }
        .task(id: detailPageTaskID) {
            await rebuildDetailPageData(reason: "route_events")
        }
        .onAppear {
            recordRouteRender(runtimeModel.mainRoute, previous: nil, reason: "appear")
        }
        .onChange(of: runtimeModel.mainRoute) { oldValue, newValue in
            beginRouteTransition(from: oldValue, to: newValue)
            recordRouteRender(newValue, previous: oldValue, reason: "change")
        }
    }

    private var warningCount: Int {
        // Sidebar badge surfaces **error-severity scenarios only** — warnings
        // (line-level recoverable issues like "partial trailing JSONL line")
        // still appear inside the Diagnostics detail page but don't pile up
        // on the sidebar number. Same logic mirrored in PopoverSnapshot.
        runtimeModel.sourceWarnings
            .groupedByScenario()
            .filter { $0.severity == .error }
            .count
    }

    private var sidebarProjects: [UsageBreakdown] {
        if !hasSidebarProjectsLoaded {
            return runtimeModel.snapshot.topProjects
        }
        return sidebarProjectsCache
    }

    private var sidebarProjectsTaskID: String {
        "\(selectedRange)|\(runtimeModel.eventSignature)"
    }

    private var overviewRangeMetricsTaskID: String {
        "\(selectedRange)|\(runtimeModel.eventSignature)"
    }

    private var projectPageTaskID: String {
        guard case .project(let projectName) = runtimeModel.mainRoute else {
            return "none|\(runtimeModel.mainRoute.telemetryName)"
        }
        return [
            projectName,
            selectedRange,
            runtimeModel.eventSignature,
            pricingOverridesJSON,
        ].joined(separator: "|")
    }

    private var detailPageTaskID: String {
        switch runtimeModel.mainRoute {
        case .source(let name):
            return "source:\(name)|\(runtimeModel.eventSignature)"
        case .model(let name):
            return "model:\(name)|\(runtimeModel.eventSignature)"
        default:
            return "none|\(runtimeModel.mainRoute.telemetryName)"
        }
    }

    @MainActor
    private func rebuildSidebarProjects(reason: String) async {
        let selection = selectedRange
        let started = Date()
        isSidebarProjectsLoading = true
        TokenBarTelemetry.event(
            "main.sidebar.projects.compute.begin",
            metadata: "reason=\(reason) range=\(selection) events=\(runtimeModel.eventCount)",
            success: true
        )
        let rows: [UsageBreakdown]
        if let dbRows = await runtimeModel.projectBreakdowns(selection: selection) {
            rows = dbRows
        } else {
            let events = runtimeModel.events
            rows = await Task.detached(priority: .utility) {
                tokenbarBreakdowns(
                    events: events,
                    selection: selection,
                    kind: .project,
                    topCount: nil
                )
            }.value
        }
        guard selection == selectedRange else { return }
        sidebarProjectsCache = rows
        hasSidebarProjectsLoaded = true
        isSidebarProjectsLoading = false
        // Sources / Models sidebar lists are all-time token rankings computed
        // from the in-memory events (same data the detail pages drill into).
        // Sources are keyed per configured source (built-in agent or named
        // custom source), not by raw agent — so each custom source the user
        // added shows up individually.
        let events = runtimeModel.events
        let customNames = runtimeModel.customSourceNamesById
        let (sources, models) = await Task.detached(priority: .utility) {
            (
                tokenbarSourceBreakdowns(events: events, customNamesById: customNames),
                tokenbarModelBreakdownsAsBreakdowns(events: events)
            )
        }.value
        guard selection == selectedRange else { return }
        sidebarSourcesCache = sources
        sidebarModelsCache = models
        TokenBarTelemetry.timing(
            "main.sidebar.projects.compute",
            startedAt: started,
            metadata: "range=\(selection) rows=\(rows.count) events=\(runtimeModel.eventCount)"
        )
    }

    @MainActor
    private func rebuildOverviewRangeMetrics(reason: String) async {
        let selection = selectedRange
        let started = Date()
        TokenBarTelemetry.event(
            "main.overview.range.compute.begin",
            metadata: "reason=\(reason) range=\(selection) events=\(runtimeModel.eventCount)",
            success: true
        )
        let metrics: TokenBarOverviewRangeMetrics
        if let rangeData = await runtimeModel.overviewRangeData(selection: selection) {
            metrics = TokenBarOverviewRangeMetrics.make(
                aggregate: rangeData.aggregate,
                selection: selection,
                window: rangeData.window
            )
        } else {
            let events = runtimeModel.events
            metrics = await Task.detached(priority: .userInitiated) {
                TokenBarOverviewRangeMetrics.make(events: events, selection: selection)
            }.value
        }
        guard !Task.isCancelled, selection == selectedRange else { return }
        overviewRangeMetrics = metrics
        TokenBarTelemetry.timing(
            "main.overview.range.compute",
            startedAt: started,
            metadata: "range=\(selection) days=\(metrics.days.count) projects=\(metrics.projectCount) agents=\(metrics.agentCount) models=\(metrics.modelRows.count) tokens=\(metrics.summary.totalTokens)"
        )
        withAnimation(.easeOut(duration: 0.14)) {
            isOverviewRangeUpdating = false
        }
    }

    @MainActor
    private func rebuildProjectPageData(reason: String) async {
        guard case .project(let projectName) = runtimeModel.mainRoute else {
            return
        }

        let selection = selectedRange
        let pricingOverrides = pricingOverridesJSON
        let eventSignature = runtimeModel.eventSignature
        if projectPageData?.isCurrent(
            projectName: projectName,
            selection: selection,
            eventSignature: eventSignature,
            pricingOverridesJSON: pricingOverrides
        ) == true {
            return
        }

        let started = Date()
        TokenBarTelemetry.event(
            "main.project.page_data.compute.begin",
            metadata: "reason=\(reason) project=\(projectName) range=\(selection) events=\(runtimeModel.eventCount) prompts=\(runtimeModel.promptCount)",
            success: true
        )
        let projectEvents = await runtimeModel.projectEvents(for: projectName)
        guard !Task.isCancelled else { return }
        let data = await Task.detached(priority: .userInitiated) {
            ProjectPageData.make(
                projectName: projectName,
                selection: selection,
                events: projectEvents,
                eventSignature: eventSignature,
                pricingOverridesJSON: pricingOverrides
            )
        }.value
        guard !Task.isCancelled,
              case .project(let currentProjectName) = runtimeModel.mainRoute,
              currentProjectName == projectName,
              selectedRange == selection,
              runtimeModel.eventSignature == eventSignature,
              pricingOverridesJSON == pricingOverrides else {
            return
        }
        projectPageData = data
        TokenBarTelemetry.timing(
            "main.project.page_data.compute",
            startedAt: started,
            metadata: "project=\(projectName) range=\(selection) project_events=\(data.events.count)"
        )
    }

    @MainActor
    private func rebuildDetailPageData(reason: String) async {
        let route = runtimeModel.mainRoute
        let key: DetailPageData.Key
        switch route {
        case .source(let name):
            key = .source(name)
        case .model(let name):
            key = .model(name)
        default:
            return
        }
        let eventSignature = runtimeModel.eventSignature
        if detailPageData?.isCurrent(key: key, eventSignature: eventSignature) == true {
            return
        }
        let started = Date()
        let allEvents = runtimeModel.events
        let customNames = runtimeModel.customSourceNamesById
        let events = await Task.detached(priority: .userInitiated) { () -> [UsageEvent] in
            switch key {
            case .source(let name):
                return allEvents.filter { tokenbarSourceName(for: $0, customNamesById: customNames) == name }
            case .model(let name):
                return allEvents.filter { event in
                    let resolved = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
                    return resolved == name
                }
            }
        }.value
        guard !Task.isCancelled,
              runtimeModel.mainRoute == route,
              runtimeModel.eventSignature == eventSignature else {
            return
        }
        detailPageData = DetailPageData(key: key, eventSignature: eventSignature, events: events)
        TokenBarTelemetry.timing(
            "main.detail.page_data.compute",
            startedAt: started,
            metadata: "key=\(key.telemetry) events=\(events.count) reason=\(reason)"
        )
    }

    @ViewBuilder
    private func projectPage(_ projectName: String) -> some View {
        let isDetailReady = (runtimeModel.projectDetail?.projectName == projectName)
        Group {
            if let detail = runtimeModel.projectDetail, detail.projectName == projectName {
                let pageData = projectPageData?.isCurrent(
                    projectName: projectName,
                    selection: selectedRange,
                    eventSignature: runtimeModel.eventSignature,
                    pricingOverridesJSON: pricingOverridesJSON
                ) == true
                    ? projectPageData
                    : ProjectPageData.placeholder(projectName: projectName, selection: selectedRange, detail: detail)
                ProjectDetailView(
                    detail: detail,
                    projectPath: pageData?.projectPath,
                    allTimeSummary: pageData?.allTimeSummary ?? detail.summary,
                    allTimeCost: pageData?.allTimeCost ?? detail.estimatedCost,
                    events: pageData?.events ?? [],
                    selectedRange: $selectedRange,
                    refreshState: runtimeModel.refreshState,
                    todayCost: pageData?.todayCost ?? 0,
                    rangeCost: pageData?.rangeCost ?? detail.estimatedCost.totalCost,
                    todayTokens: pageData?.todayTokens ?? 0,
                    totalTokens: pageData?.totalTokens ?? detail.summary.totalTokens,
                    todaySessions: pageData?.todaySessions ?? detail.recentSessions.count,
                    onRefresh: { Task { await runtimeModel.refresh() } },
                    onBack: { runtimeModel.navigate(to: .today, source: "project.back") }
                )
                .id(projectName)
                .onAppear { recordRouteViewAppear(.project(projectName)) }
                .transition(.opacity)
            } else {
                // 180ms grace before the pending placeholder shows — if real
                // data arrives within that window the user only ever sees the
                // outer route cross-fade, no flash of placeholder.
                DelayedAppear(delay: .milliseconds(180), fadeIn: .easeOut(duration: 0.12)) {
                    ProjectDetailPendingView(projectName: projectName)
                        .onAppear {
                            recordRouteViewAppear(.project(projectName))
                            TokenBarTelemetry.event(
                                "main.project.pending.appear",
                                metadata: "project=\(projectName) events=\(runtimeModel.eventCount)",
                                success: true
                            )
                        }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: isDetailReady)
    }

    @ViewBuilder
    private func sourcePage(_ sourceName: String) -> some View {
        let events = detailPageData?.events(for: .source(sourceName)) ?? []
        SourceDetailView(
            sourceName: sourceName,
            events: events,
            allTimeSummary: tokenbarSummary(events),
            allTimeCost: tokenbarEstimatedCost(events: events),
            selectedRange: $selectedRange,
            refreshState: runtimeModel.refreshState,
            onRefresh: { Task { await runtimeModel.refresh() } },
            onBack: { runtimeModel.navigate(to: .today, source: "source.back") },
            onSelectProject: { runtimeModel.openProject(named: $0, source: "source.project_share") }
        )
        .id(sourceName)
        .onAppear { recordRouteViewAppear(.source(sourceName)) }
        .transition(.opacity)
    }

    @ViewBuilder
    private func modelPage(_ modelName: String) -> some View {
        let events = detailPageData?.events(for: .model(modelName)) ?? []
        ModelDetailView(
            modelName: modelName,
            events: events,
            allTimeSummary: tokenbarSummary(events),
            allTimeCost: tokenbarEstimatedCost(events: events),
            selectedRange: $selectedRange,
            refreshState: runtimeModel.refreshState,
            onRefresh: { Task { await runtimeModel.refresh() } },
            onBack: { runtimeModel.navigate(to: .today, source: "model.back") },
            onSelectProject: { runtimeModel.openProject(named: $0, source: "model.project_share") }
        )
        .id(modelName)
        .onAppear { recordRouteViewAppear(.model(modelName)) }
        .transition(.opacity)
    }

    private func beginRouteTransition(from previous: TokenBarMainRoute, to route: TokenBarMainRoute) {
        routeTransitionStartedAt = Date()
        routeTransitionFrom = previous.telemetryName
        routeTransitionTo = route.telemetryName
        routeTransitionSequence += 1
        TokenBarSignpost.event("route-switch-start", "\(previous.telemetryName)->\(route.telemetryName)")
        TokenBarTelemetry.event(
            "main.route.switch.begin",
            metadata: routeTelemetryMetadata(
                route: route,
                previous: previous.telemetryName,
                sequence: routeTransitionSequence,
                extra: "range=\(selectedRange)"
            ),
            success: true
        )
    }

    private func recordRouteRender(_ route: TokenBarMainRoute, previous: TokenBarMainRoute?, reason: String) {
        let started = Date()
        let previousText = previous?.telemetryName ?? "none"
        let sequence = routeTransitionSequence
        TokenBarTelemetry.event(
            "main.route.render.begin",
            metadata: routeTelemetryMetadata(
                route: route,
                previous: previousText,
                sequence: sequence,
                extra: "reason=\(reason) range=\(selectedRange) sidebar_rows=\(sidebarProjects.count) sidebar_loading=\(isSidebarProjectsLoading)"
            ),
            success: true
        )
        Task { @MainActor in
            await Task.yield()
            TokenBarTelemetry.timing(
                "main.route.render.first_runloop",
                startedAt: started,
                metadata: routeTelemetryMetadata(route: route, previous: previousText, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(16))
            TokenBarTelemetry.timing(
                "main.route.render.first_frame_16ms",
                startedAt: started,
                metadata: routeTelemetryMetadata(route: route, previous: previousText, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(100))
            TokenBarTelemetry.timing(
                "main.route.render.settled_100ms",
                startedAt: started,
                metadata: routeTelemetryMetadata(route: route, previous: previousText, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(400))
            TokenBarTelemetry.timing(
                "main.route.render.settled_500ms",
                startedAt: started,
                metadata: routeTelemetryMetadata(route: route, previous: previousText, sequence: sequence)
            )
        }
    }

    private func recordRouteViewAppear(_ route: TokenBarMainRoute) {
        let transitionStarted = routeTransitionTo == route.telemetryName ? routeTransitionStartedAt : nil
        let sequence = routeTransitionSequence
        let previous = routeTransitionFrom
        TokenBarTelemetry.event(
            "main.route.view.appear",
            metadata: routeTelemetryMetadata(route: route, previous: previous, sequence: sequence),
            success: true,
            elapsed: transitionStarted.map { Date().timeIntervalSince($0) }
        )
        if let transitionStarted {
            TokenBarSignpost.event("route-switch-view-appear", "\(previous)->\(route.telemetryName)")
            recordRouteSwitchMilestones(
                route: route,
                previous: previous,
                sequence: sequence,
                startedAt: transitionStarted
            )
        }
    }

    private func recordRouteSwitchMilestones(
        route: TokenBarMainRoute,
        previous: String,
        sequence: Int,
        startedAt: Date
    ) {
        Task { @MainActor in
            await Task.yield()
            TokenBarTelemetry.timing(
                "main.route.switch.first_runloop",
                startedAt: startedAt,
                metadata: routeTelemetryMetadata(route: route, previous: previous, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(16))
            TokenBarTelemetry.timing(
                "main.route.switch.first_frame_16ms",
                startedAt: startedAt,
                metadata: routeTelemetryMetadata(route: route, previous: previous, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(100))
            TokenBarTelemetry.timing(
                "main.route.switch.settled_100ms",
                startedAt: startedAt,
                metadata: routeTelemetryMetadata(route: route, previous: previous, sequence: sequence)
            )
            try? await Task.sleep(for: .milliseconds(400))
            TokenBarTelemetry.timing(
                "main.route.switch.settled_500ms",
                startedAt: startedAt,
                metadata: routeTelemetryMetadata(route: route, previous: previous, sequence: sequence)
            )
        }
    }

    private func routeTelemetryMetadata(
        route: TokenBarMainRoute,
        previous: String,
        sequence: Int,
        extra: String = ""
    ) -> String {
        [
            "seq=\(sequence)",
            "previous=\(previous)",
            "route=\(route.telemetryName)",
            "events=\(runtimeModel.eventCount)",
            "prompts=\(runtimeModel.promptCount)",
            "warnings=\(runtimeModel.snapshot.warningCount)",
            "refresh_state=\(runtimeModel.refreshState.rawValue)",
            extra,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

}

private struct ProjectPageData: Sendable {
    let projectName: String
    let selection: String
    let eventSignature: String
    let pricingOverridesJSON: String
    let projectPath: String?
    let allTimeSummary: UsageSummary
    let allTimeCost: UsageCostProjection
    let events: [UsageEvent]
    let todayCost: Double
    let rangeCost: Double
    let todayTokens: Int
    let totalTokens: Int
    let todaySessions: Int

    static func eventsSignature(_ events: [UsageEvent]) -> String {
        "\(events.count)|\(events.last?.id ?? "none")"
    }

    func isCurrent(
        projectName: String,
        selection: String,
        eventSignature: String,
        pricingOverridesJSON: String
    ) -> Bool {
        self.projectName == projectName
            && self.selection == selection
            && self.eventSignature == eventSignature
            && self.pricingOverridesJSON == pricingOverridesJSON
    }

    static func placeholder(
        projectName: String,
        selection: String,
        detail: ProjectDetailSnapshot
    ) -> ProjectPageData {
        ProjectPageData(
            projectName: projectName,
            selection: selection,
            eventSignature: "placeholder",
            pricingOverridesJSON: "",
            projectPath: nil,
            allTimeSummary: detail.summary,
            allTimeCost: detail.estimatedCost,
            events: [],
            todayCost: 0,
            rangeCost: detail.estimatedCost.totalCost,
            todayTokens: 0,
            totalTokens: detail.summary.totalTokens,
            todaySessions: detail.recentSessions.count
        )
    }

    static func make(
        projectName: String,
        selection: String,
        events: [UsageEvent],
        eventSignature: String,
        pricingOverridesJSON: String
    ) -> ProjectPageData {
        var projectEvents: [UsageEvent] = []
        projectEvents.reserveCapacity(min(events.count, 512))
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var latestPath: String?
        var latestPathTimestamp = Date.distantPast

        for event in events where event.projectName == projectName {
            projectEvents.append(event)
            inputTokens += event.inputTokens
            outputTokens += event.outputTokens
            cacheReadTokens += event.cacheReadTokens
            cacheCreationTokens += event.cacheCreationTokens
            if let projectPath = event.projectPath,
               !projectPath.isEmpty,
               event.timestamp > latestPathTimestamp {
                latestPath = projectPath
                latestPathTimestamp = event.timestamp
            }
        }

        let allTimeSummary = UsageSummary(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens
        )
        let todayEvents = tokenbarEventsInLastDays(events: projectEvents)
        let rangeEvents = tokenbarRangeEvents(events: projectEvents, selection: selection)
        let rangeSummary = tokenbarSummary(rangeEvents)

        return ProjectPageData(
            projectName: projectName,
            selection: selection,
            eventSignature: eventSignature,
            pricingOverridesJSON: pricingOverridesJSON,
            projectPath: latestPath,
            allTimeSummary: allTimeSummary,
            allTimeCost: tokenbarCostProjection(events: projectEvents),
            events: projectEvents,
            todayCost: tokenbarEstimatedCost(events: todayEvents),
            rangeCost: tokenbarEstimatedCost(events: rangeEvents),
            todayTokens: tokenbarSummary(todayEvents).totalTokens,
            totalTokens: rangeSummary.totalTokens,
            todaySessions: tokenbarSessionCount(projectEvents)
        )
    }
}

private struct DetailPageData: Sendable {
    enum Key: Sendable, Equatable {
        case source(String)
        case model(String)

        var telemetry: String {
            switch self {
            case .source(let name): "source:\(name)"
            case .model(let name): "model:\(name)"
            }
        }
    }

    let key: Key
    let eventSignature: String
    let events: [UsageEvent]

    func isCurrent(key: Key, eventSignature: String) -> Bool {
        self.key == key && self.eventSignature == eventSignature
    }

    func events(for key: Key) -> [UsageEvent]? {
        self.key == key ? events : nil
    }
}

private struct ProjectDetailPendingView: View {
    let projectName: String

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("~/code/\(projectName)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
                Text(projectName)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text("Loading project detail from the local index")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 220, alignment: .top)
    }
}

private enum SidebarListTab: String, CaseIterable {
    case projects, sources, models

    var title: String {
        switch self {
        case .projects: "Projects"
        case .sources: "Sources"
        case .models: "Models"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .projects: "Search projects"
        case .sources: "Search sources"
        case .models: "Search models"
        }
    }
}

private struct TokenBarSidebar: View {
    let activeRoute: TokenBarMainRoute
    let projects: [UsageBreakdown]
    let sources: [UsageBreakdown]
    let models: [UsageBreakdown]
    let warnings: Int
    let refreshState: RefreshState
    let lastIndexedAt: Date?
    let onSelectOverview: () -> Void
    let onSelectLibrary: () -> Void
    let onSelectDiagnostics: () -> Void
    let onSelectSettings: () -> Void
    let onSelectSavedPrompts: () -> Void
    let onSelectProject: (String) -> Void
    let onSelectSource: (String) -> Void
    let onSelectModel: (String) -> Void
    @State private var projectSearchText = ""
    @State private var listTab: SidebarListTab = .projects

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    TokenBarBrandGlyph(size: 30)
                    Text("TokenBar")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }

                VStack(spacing: 6) {
                    routeRow(icon: "square.grid.2x2", title: "Overview", value: "", selected: isOverview, action: onSelectOverview)
                    routeRow(icon: "book.closed", title: "Library", value: "", selected: isLibrary, action: onSelectLibrary)
                    routeRow(icon: "bookmark", title: "Prompt Templates", value: "", selected: isSavedPrompts, action: onSelectSavedPrompts)
                    routeRow(icon: "waveform.path.ecg", title: "Diagnostics", value: warnings > 0 ? "\(warnings)" : "", selected: isDiagnostics, action: onSelectDiagnostics)
                    routeRow(icon: "gearshape", title: "Settings", value: "", selected: isSettings, action: onSelectSettings)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 9) {
                listTabPicker

                sidebarSearchField

                // CL-P1-012: scroll once row count exceeds the visible slots
                // so long workspaces / source / model lists stay reachable.
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        if filteredRows.isEmpty {
                            Text(emptyListMessage)
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.faint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        ForEach(filteredRows) { row in
                            sidebarListRow(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                // When we have not finished a first scan, render the dot as
                // muted instead of the "idle = all good" green, so it does not
                // implicitly tell the user that an empty database is healthy.
                let dotColor: Color = lastIndexedAt == nil
                    ? TokenBarStyle.muted
                    : TokenBarStyle.statusColor(for: refreshState)
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: dotColor.opacity(0.55), radius: 5)
                AboutHelpButton()
                Spacer()
                Text(lastIndexedAt == nil ? "first scan…" : tokenbarRelativeTime(lastIndexedAt))
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(TokenBarStyle.faint)
            .padding(16)
        }
        // CL-P0-008: sidebar uses the standard SwiftUI .bar material with a
        // Reduce Transparency fallback (see TokenBarSidebarBackground).
        .background(TokenBarSidebarBackground())
    }

    private var isOverview: Bool {
        activeRoute == .today
    }

    private var isLibrary: Bool {
        activeRoute == .library
    }

    private var isDiagnostics: Bool {
        activeRoute == .diagnostics
    }

    private var isSettings: Bool {
        activeRoute == .settings
    }

    private var isSavedPrompts: Bool {
        activeRoute == .savedPrompts
    }

    private var filteredRows: [UsageBreakdown] {
        let base: [UsageBreakdown]
        switch listTab {
        case .projects: base = projects
        case .sources:  base = sources
        case .models:   base = models
        }
        let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var emptyListMessage: String {
        let searching = !projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch listTab {
        case .projects:
            return searching ? "No matching projects" : "No projects indexed yet"
        case .sources:
            return searching ? "No matching sources" : "No sources indexed yet"
        case .models:
            return searching ? "No matching models" : "No models indexed yet"
        }
    }

    private var listTabPicker: some View {
        Picker("List", selection: $listTab) {
            ForEach(SidebarListTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private func sidebarListRow(_ row: UsageBreakdown) -> some View {
        let selected = isRowSelected(row.name)
        Button {
            switch listTab {
            case .projects: onSelectProject(row.name)
            case .sources:  onSelectSource(row.name)
            case .models:   onSelectModel(row.name)
            }
        } label: {
            HStack(spacing: 8) {
                if listTab != .projects {
                    Circle()
                        .fill(TokenBarStyle.agentColor(row.name))
                        .frame(width: 7, height: 7)
                }
                Text(row.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                Text(tokenbarTokens(row.summary.totalTokens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
    }

    private func isRowSelected(_ name: String) -> Bool {
        switch (listTab, activeRoute) {
        case (.projects, .project(let n)): return n == name
        case (.sources, .source(let n)):   return n == name
        case (.models, .model(let n)):     return n == name
        default: return false
        }
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.faint)
            TextField(listTab.searchPlaceholder, text: $projectSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            if !projectSearchText.isEmpty {
                Button {
                    projectSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func routeRow(icon: String, title: String, value: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? TokenBarStyle.input : TokenBarStyle.muted)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.warn)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(TokenBarStyle.warn.opacity(0.10), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected
                          ? Color(nsColor: .controlAccentColor).opacity(0.18)
                          : Color.clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TokenBarStyle.line, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
    }
}

private struct OverviewPage: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Binding var selectedRange: String
    @Binding var rangeMetrics: TokenBarOverviewRangeMetrics
    @Binding var isRangeLoading: Bool
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    /// CL-P0-012: which KPI (Total / Input / Output / Cache) is currently
    /// expanded into a detail drawer. `nil` = collapsed.
    @State private var expandedKPI: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                pageHeader
                if runtimeModel.showsIndexingCard {
                    TokenBarIndexingStatusCard(
                        state: runtimeModel.indexingState,
                        compact: true,
                        showSourceList: false,
                        onPause: { runtimeModel.pauseInitialIndexing() },
                        onRetry: { runtimeModel.retryInitialIndexing() },
                        onOpenDiagnostics: { runtimeModel.navigate(to: .diagnostics, source: "overview.initial_index") }
                    )
                }
                // CL-P0-027: when no events and no custom sources, the user has
                // pointed TokenBar at nothing — show onboarding instead of empty
                // KPI/chart cards that look like data is broken.
                if showIndexingOnly || showCatchingUp {
                    EmptyView()
                } else if showOnboarding {
                    OnboardingCard(onOpenSettings: { runtimeModel.navigate(to: .settings, source: "overview.onboarding") })
                } else {
                    kpiRow
                    if let expandedKPI {
                        TokenBarKPIDetailDrawer(
                            title: expandedKPI,
                            today: kpiToday(expandedKPI),
                            yesterday: kpiYesterday(expandedKPI),
                            sevenDayAverage: kpiSevenDayAverage(expandedKPI),
                            cost: expandedKPI == "Total" ? todayCost : nil,
                            onClose: { withAnimation(.easeOut(duration: 0.18)) { self.expandedKPI = nil } }
                        )
                    }
                    hourlyCard
                    RangeBarsCard(
                        days: rangeMetrics.days,
                        title: rangeTitle,
                        subtitle: rangeMetrics.availabilityNote,
                        summary: rangeMetrics.summary,
                        promptCounts: [:]
                    )
                    HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                        RankingCard(
                            title: "Top projects",
                            footnote: "\(rangeMetrics.projectRows.count) of \(rangeMetrics.projectCount)",
                            rows: rangeMetrics.projectRows,
                            onSelect: { runtimeModel.openProject(named: $0, source: "overview.ranking.project") }
                        )
                        RankingCard(
                            title: "Top agents",
                            footnote: "\(rangeMetrics.agentCount) active",
                            rows: rangeMetrics.agentRows,
                            onSelect: nil
                        )
                    }
                    ModelBreakdownTable(
                        title: "Model",
                        subtitle: "Share of tokens · \(tokenbarRangeTitle(selectedRange).lowercased())",
                        totalCost: tokenbarCompactCurrency(rangeMetrics.cost),
                        rows: rangeMetrics.modelRows
                    )
                }
            }
            if isPageUpdating && !showIndexingOnly && !showCatchingUp && !showOnboarding {
                TokenBarPageUpdatingOverlay(label: "updating \(tokenbarRangeShortLabel(selectedRange))")
            }
        }
        .animation(.easeOut(duration: 0.14), value: isPageUpdating)
        .onChange(of: selectedRange) { oldValue, newValue in
            withAnimation(.easeOut(duration: 0.12)) {
                isRangeLoading = true
            }
            TokenBarTelemetry.event(
                "overview.range.select",
                metadata: "from=\(oldValue) to=\(newValue) events=\(runtimeModel.eventCount)",
                success: true
            )
        }
    }

    private var showOnboarding: Bool {
        runtimeModel.events.isEmpty && runtimeModel.customSources.isEmpty && !runtimeModel.indexingState.isVisible && !runtimeModel.isInitialMeasurement
    }

    private var showIndexingOnly: Bool {
        runtimeModel.events.isEmpty && runtimeModel.indexingState.isActive
    }

    /// Show only the indexing card (no KPI/chart cards) during the bootstrap
    /// window when the store is empty. Uses the stable `isInitialMeasurement`
    /// signal so the layout does not toggle on every periodic refresh.
    private var showCatchingUp: Bool {
        runtimeModel.events.isEmpty && runtimeModel.isInitialMeasurement && !runtimeModel.indexingState.isActive
    }

    private var pageHeader: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            Spacer()
            TopRightCluster(
                todayCost: todayCost,
                rangeCost: rangeMetrics.cost,
                todayTokens: runtimeModel.snapshot.today.totalTokens,
                totalTokens: rangeMetrics.summary.totalTokens,
                todaySessions: runtimeModel.popoverSnapshot.todaySessionCount,
                refreshState: runtimeModel.refreshState,
                onRefresh: { Task { await runtimeModel.refresh() } },
                measuring: runtimeModel.isMeasuringToday,
                rangeLabel: tokenbarRangeShortLabel(selectedRange)
            )
            .layoutPriority(2)
            DateRangeControl(selection: $selectedRange)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var headerSubtitle: String {
        Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var isPageUpdating: Bool {
        isRangeLoading
    }

    private var todayCost: Double {
        runtimeModel.popoverSnapshot.todayCost
    }

    private var kpiRow: some View {
        HStack(spacing: TokenBarStyle.sectionSpacing) {
            kpiCard(title: "Total", value: runtimeModel.snapshot.today.totalTokens, meta: "today", color: TokenBarStyle.muted)
            kpiCard(title: "Input", value: runtimeModel.snapshot.today.inputTokens, meta: inputShare, color: TokenBarStyle.input)
            kpiCard(title: "Output", value: runtimeModel.snapshot.today.outputTokens, meta: outputShare, color: TokenBarStyle.output)
            kpiCard(title: "Cache", value: runtimeModel.snapshot.today.cacheTokens, meta: cacheShare, color: TokenBarStyle.cache)
        }
    }

    private func kpiCard(title: String, value: Int, meta: String, color: Color) -> some View {
        let baseline = kpiSevenDayAverage(title)  // proxy for 30d P50
        let status = TokenBarUsageStatus.compute(today: value, baseline30d: baseline)
        return TokenBarKPI(
            title: title,
            value: tokenbarTokens(value),
            meta: meta,
            color: color,
            onTap: {
                withAnimation(.easeOut(duration: 0.18)) {
                    expandedKPI = (expandedKPI == title) ? nil : title
                }
            },
            isExpanded: expandedKPI == title,
            preciseValue: value,
            status: status
        )
    }

    private func kpiToday(_ title: String) -> Int {
        switch title {
        case "Input":  return runtimeModel.snapshot.today.inputTokens
        case "Output": return runtimeModel.snapshot.today.outputTokens
        case "Cache":  return runtimeModel.snapshot.today.cacheTokens
        default:       return runtimeModel.snapshot.today.totalTokens
        }
    }

    private func kpiYesterday(_ title: String) -> Int {
        guard runtimeModel.snapshot.last30Days.count >= 2 else { return 0 }
        let yesterday = runtimeModel.snapshot.last30Days[runtimeModel.snapshot.last30Days.count - 2]
        switch title {
        case "Input":  return yesterday.summary.inputTokens
        case "Output": return yesterday.summary.outputTokens
        case "Cache":  return yesterday.summary.cacheTokens
        default:       return yesterday.summary.totalTokens
        }
    }

    private func kpiSevenDayAverage(_ title: String) -> Int {
        let window = Array(runtimeModel.snapshot.last30Days.suffix(7))
        guard !window.isEmpty else { return 0 }
        let total: Int
        switch title {
        case "Input":  total = window.reduce(0) { $0 + $1.summary.inputTokens }
        case "Output": total = window.reduce(0) { $0 + $1.summary.outputTokens }
        case "Cache":  total = window.reduce(0) { $0 + $1.summary.cacheTokens }
        default:       total = window.reduce(0) { $0 + $1.summary.totalTokens }
        }
        return total / window.count
    }

    private var hourlyCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("By hour")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("24 buckets · local timezone")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    Text("peak \(hourlyPeakTimeText) · \(tokenbarTokens(hourly.peakHourOfDay?.summary.totalTokens ?? 0))")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.cache)
                }
                HourlyHeatmapView(hours: hourly.hoursOfDay)
            }
        }
    }

    private var hourly: HourlyUsageSnapshot {
        runtimeModel.popoverSnapshot.hourly
    }

    private var hourlyPeakTimeText: String {
        guard let peak = hourly.peakHourOfDay else { return "--:--" }
        return String(format: "%02d:00", peak.hourOfDay)
    }

    private var rangeTitle: String {
        tokenbarRangeTitle(selectedRange)
    }

    private var inputShare: String { shareText(runtimeModel.snapshot.today.inputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var outputShare: String { shareText(runtimeModel.snapshot.today.outputTokens, total: runtimeModel.snapshot.today.totalTokens) }
    private var cacheShare: String { shareText(runtimeModel.snapshot.today.cacheTokens, total: runtimeModel.snapshot.today.totalTokens) }

    private func shareText(_ value: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))%"
    }
}

struct TopRightCluster: View {
    let todayCost: Double
    let rangeCost: Double
    let todayTokens: Int
    let totalTokens: Int
    let todaySessions: Int
    let refreshState: RefreshState
    let onRefresh: (() -> Void)?
    var measuring: Bool = false

    @AppStorage("tokenbar.menuBarMirrorMode") private var mirrorModeRaw = MenuBarMirrorMode.off.rawValue
    @AppStorage("tokenbar.menuBarPaused") private var isPaused = false
    @State private var showFlyout = false

    var rangeLabel = "30d"

    private func copyCostSummary() {
        let line = "Today ~ \(tokenbarCompactCurrency(todayCost)) · \(rangeLabel) ~ \(tokenbarCompactCurrency(rangeCost)) · \(tokenbarCompactTokens(totalTokens)) tokens"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Today ~")
                        .foregroundStyle(TokenBarStyle.muted)
                    Text(measuring ? "—" : tokenbarCompactCurrency(todayCost))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Divider().frame(height: 15).overlay(TokenBarStyle.line)
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.cache)
                    Text("\(rangeLabel) ~")
                        .foregroundStyle(TokenBarStyle.muted)
                    Text(measuring ? "—" : tokenbarCompactCurrency(rangeCost))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .foregroundStyle(TokenBarStyle.faint)
                    Text(measuring ? "—" : tokenbarCompactTokens(totalTokens))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TokenBarStyle.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
            // CL-P2-006: clicking the cost capsule copies a human-readable
            // string to the pasteboard and shows a brief toast tooltip.
            .contentShape(Capsule())
            .onTapGesture { if !measuring { copyCostSummary() } }
            .help(measuring ? "Catching up — totals will appear once indexing finishes" : "Click to copy today / \(rangeLabel) cost summary")

            Button {
                showFlyout.toggle()
            } label: {
                HStack(spacing: 7) {
                    TokenBarStatusGlyph(state: refreshState, paused: isPaused)
                    if mirrorMode != .off {
                        Text(menuValue)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Circle()
                        .fill(isPaused ? TokenBarStyle.warn : TokenBarStyle.statusColor(for: refreshState))
                        .frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(TokenBarStyle.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
            .help("Menu bar mirrors \(mirrorMode.title.lowercased()).")
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $showFlyout, arrowEdge: .bottom) {
                menuFlyout
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var mirrorMode: MenuBarMirrorMode {
        MenuBarMirrorMode(rawValue: mirrorModeRaw) ?? .off
    }

    private var menuValue: String {
        tokenbarMirrorValue(
            mode: mirrorMode,
            todayTokens: todayTokens,
            todayCost: todayCost,
            todaySessions: todaySessions
        )
    }

    private var menuFlyout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar mirrors")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Circle()
                    .fill(isPaused ? TokenBarStyle.warn : TokenBarStyle.statusColor(for: refreshState))
                    .frame(width: 6, height: 6)
                Text(menuValue.isEmpty ? "hidden" : menuValue)
                    .font(.system(size: 12.5, design: .monospaced))
                Spacer()
                Text("updated now")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
            }
            .padding(9)
            .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            flyoutButton("Force refresh", systemImage: "arrow.clockwise", trailing: "⌘R") {
                onRefresh?()
            }
            flyoutButton(isPaused ? "Resume tracking" : "Pause tracking", systemImage: isPaused ? "play" : "pause", trailing: isPaused ? "paused" : "tracking") {
                isPaused.toggle()
            }
            flyoutButton("Reopen popover", systemImage: "menubar.rectangle", trailing: "click status item") {
                showFlyout = false
            }

            Text("Show in menu bar")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
                .padding(.top, 2)

            HStack(spacing: 5) {
                ForEach(MenuBarMirrorMode.allCases) { mode in
                    Button {
                        mirrorModeRaw = mode.rawValue
                    } label: {
                        VStack(spacing: 2) {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: .medium))
                            Text(tokenbarMirrorValue(mode: mode, todayTokens: todayTokens, todayCost: todayCost, todaySessions: todaySessions).isEmpty ? "—" : tokenbarMirrorValue(mode: mode, todayTokens: todayTokens, todayCost: todayCost, todaySessions: todaySessions))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(mirrorMode == mode ? TokenBarStyle.foreground.opacity(0.75) : TokenBarStyle.faint)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(mirrorMode == mode ? TokenBarStyle.input.opacity(0.22) : TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit TokenBar")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(TokenBarStyle.error)
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 310)
        .background(TokenBarGlassBackground())
    }

    private func flyoutButton(_ title: String, systemImage: String, trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                Text(title)
                Spacer()
                Text(trailing)
                    .foregroundStyle(TokenBarStyle.faint)
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(TokenBarStyle.foreground)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct RankingCard: View {
    let title: String
    let footnote: String
    let rows: [TokenBarRankingRow]
    let onSelect: ((String) -> Void)?

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.faint)
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { index, row in
                        Button {
                            onSelect?(row.name)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(rankColor(index))
                                    .frame(width: 22, height: 22)
                                    .background(rankColor(index).opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    // CL-P0-015: real per-row attribution
                                    // (top agents for project rows, top
                                    // projects for agent rows) replaces the
                                    // old hard-coded "local indexed usage".
                                    Text(row.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(tokenbarCompactTokens(row.totalTokens))
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(TokenBarStyle.foreground)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                        .tbNumberTooltip(precise: row.totalTokens, window: row.name)
                                    Text(tokenbarCompactCurrency(row.cost))
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(TokenBarStyle.cost)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                        .tbNumberTooltip(precise: row.cost, window: row.name)
                                }
                                .frame(width: 92, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(onSelect != nil)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.6)), alignment: .bottom)
                    }
                    if rows.isEmpty {
                        Text("No local rows yet.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // CL-P1-009: positions 4+ use quaternaryLabelColor so the badge fades
    // back rather than reusing the (token-coded) line color and confusing
    // viewers about meaning.
    private func rankColor(_ index: Int) -> Color {
        switch index {
        case 0: TokenBarStyle.accent
        case 1: TokenBarStyle.output
        case 2: TokenBarStyle.cache
        case 3: Color(nsColor: .systemPurple)
        default: Color(nsColor: .quaternaryLabelColor)
        }
    }
}

/// CL-P0-027: shown on Overview when no events and no custom sources exist.
/// Tapping the button routes the user to Settings where they can add a source.
private struct OnboardingCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        TokenBarCard(padding: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.accent)
                    Text("Welcome — point TokenBar at your first source")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                Text("TokenBar reads usage events from local data sources only. Nothing leaves this Mac. Add a source to begin indexing.")
                    .font(.callout)
                    .foregroundStyle(TokenBarStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sidebar-footer version label + the "?" that opens the About / version-
/// updater popover (design §00e). Shows a compact `v<version>` and a help
/// button; the button carries a pulsing lime dot when an update is available.
/// The full update flow (check → download → restart) lives in the popover.
struct AboutHelpButton: View {
    @EnvironmentObject var runtimeModel: TokenBarRuntimeModel
    @State private var showAbout = false
    @State private var badgePulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasUpdate: Bool { runtimeModel.availableUpdate != nil }

    var body: some View {
        HStack(spacing: 6) {
            Text("v\(currentVersion)")
                .font(.system(size: 10.5, design: .monospaced))
            Button { showAbout.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hasUpdate ? TokenBarStyle.lime : TokenBarStyle.faint)
                    .overlay(alignment: .topTrailing) {
                        if hasUpdate {
                            Circle()
                                .fill(TokenBarStyle.lime)
                                .frame(width: 5, height: 5)
                                .shadow(color: TokenBarStyle.lime.opacity(0.7), radius: 3)
                                .scaleEffect(badgePulse && !reduceMotion ? 1.4 : 1)
                                .opacity(badgePulse && !reduceMotion ? 0.6 : 1)
                                .offset(x: 2, y: -1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(hasUpdate ? "Update available — open About" : "About TokenBar")
            .popover(isPresented: $showAbout, arrowEdge: .top) {
                AboutVersionPopover(onClose: { showAbout = false })
                    .environmentObject(runtimeModel)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { badgePulse = true }
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

/// Holds back a view for `delay` after the wrapper appears, then fades it in.
/// Used to suppress loading placeholders during fast async fetches so the user
/// only ever sees a placeholder when a load truly takes longer than the grace
/// window.
private struct DelayedAppear<Content: View>: View {
    var delay: Duration = .milliseconds(180)
    var fadeIn: Animation = .easeOut(duration: 0.12)
    @ViewBuilder var content: () -> Content

    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                content()
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(fadeIn, value: ready)
        .task {
            try? await Task.sleep(for: delay)
            ready = true
        }
    }
}

/// Bridges to the underlying `NSWindow` so we can override AppKit-level
/// behavior that SwiftUI doesn't expose (e.g. initial first responder).
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    // Intentionally a no-op: `configure` is run once on install via
    // `makeNSView`. Re-running it on every SwiftUI update would, for example,
    // accumulate notification-center observers and repeatedly steal focus
    // from fields the user is actively typing into.
    func updateNSView(_ view: NSView, context: Context) {}
}
