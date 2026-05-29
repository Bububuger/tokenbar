import AppKit
import SwiftUI
import TokenBarCore

struct ProjectDetailView: View {
    let detail: ProjectDetailSnapshot
    let projectPath: String?
    let allTimeSummary: UsageSummary
    let allTimeCost: UsageCostProjection
    let events: [UsageEvent]
    @Binding var selectedRange: String
    let refreshState: RefreshState
    let todayCost: Double
    let rangeCost: Double
    let todayTokens: Int
    let totalTokens: Int
    let todaySessions: Int
    let onRefresh: (() -> Void)?
    let onBack: () -> Void

    @State private var revealPrompts = true
    @State private var isRangeLoading = false
    @State private var promptSearchText = ""
    @State private var promptClusterFilter: PromptClusterFilter = .all
    @State private var promptPage = 0
    @State private var selectedPromptID: String?
    @State private var projectMetrics = ProjectDetailRangeMetrics.empty
    @State private var promptHistoryPage = PromptHistoryPage.empty(limit: 12, offset: 0)
    @State private var promptCountsByDay: [Date: Int] = [:]
    @State private var hasPromptHistoryLoaded = false
    @State private var isPromptHistoryLoading = false
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    // CL-P1-016: which session row is expanded into the detail drawer.
    @State private var expandedSession: String?
    @State private var saveAsTemplateTarget: SavedPromptEditorTarget?
    // CL-P0-033: Reveal is gated by the global prompt text display setting.
    // When text is hidden, the button is disabled and hovering it explains
    // where to enable full local text display.
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel

    init(
        detail: ProjectDetailSnapshot,
        projectPath: String?,
        allTimeSummary: UsageSummary,
        allTimeCost: UsageCostProjection,
        events: [UsageEvent],
        selectedRange: Binding<String>,
        refreshState: RefreshState,
        todayCost: Double,
        rangeCost: Double,
        todayTokens: Int,
        totalTokens: Int,
        todaySessions: Int,
        onRefresh: (() -> Void)?,
        onBack: @escaping () -> Void
    ) {
        self.detail = detail
        self.projectPath = projectPath
        self.allTimeSummary = allTimeSummary
        self.allTimeCost = allTimeCost
        self.events = events
        self._selectedRange = selectedRange
        self.refreshState = refreshState
        self.todayCost = todayCost
        self.rangeCost = rangeCost
        self.todayTokens = todayTokens
        self.totalTokens = totalTokens
        self.todaySessions = todaySessions
        self.onRefresh = onRefresh
        self.onBack = onBack
        self._projectMetrics = State(
            initialValue: ProjectDetailRangeMetrics.snapshot(
                detail: detail,
                rangeCost: rangeCost,
                todayCost: todayCost,
                todayTokens: todayTokens,
                totalTokens: totalTokens,
                todaySessions: todaySessions
            )
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LazyVStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                header
                projectTodayStrip
                kpiRow
                RangeBarsCard(
                    days: rangeDays,
                    title: tokenbarRangeTitle(selectedRange),
                    subtitle: projectMetrics.availabilityNote,
                    summary: projectRangeSummary,
                    promptCounts: promptCountsByDay
                )
                HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                    agentShareCard
                    recentSessionsCard
                }
                ModelBreakdownTable(
                    title: "Model",
                    subtitle: "Cost and token attribution used by \(detail.projectName).",
                    totalCost: tokenbarCompactCurrency(projectRangeCost),
                    rows: modelRows
                )
                promptHistoryCard
            }
            if isRangeLoading {
                TokenBarPageUpdatingOverlay(label: "updating \(tokenbarRangeShortLabel(selectedRange))")
            }
        }
        .animation(.easeOut(duration: 0.14), value: isRangeLoading)
        .task(id: projectMetricsTaskID) {
            await rebuildProjectMetrics(reason: "range_or_events")
        }
        .onAppear {
            let started = Date()
            TokenBarTelemetry.event(
                "project.detail.view.appear",
                metadata: "project=\(detail.projectName) events=\(events.count) prompts=\(promptHistoryPage.totalCount)",
                success: true
            )
            Task { @MainActor in
                await Task.yield()
                TokenBarTelemetry.timing(
                    "project.detail.view.first_runloop",
                    startedAt: started,
                    metadata: "project=\(detail.projectName) events=\(events.count)"
                )
            }
        }
        .onChange(of: selectedRange) { oldValue, newValue in
            withAnimation(.easeOut(duration: 0.12)) {
                isRangeLoading = true
            }
            TokenBarTelemetry.event(
                "project.detail.range.select",
                metadata: "project=\(detail.projectName) from=\(oldValue) to=\(newValue) events=\(projectEvents.count)",
                success: true
            )
        }
        .sheet(item: $saveAsTemplateTarget) { target in
            SavedPromptEditorView(target: target) {
                saveAsTemplateTarget = nil
            }
            .environmentObject(runtimeModel)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // CL-P1-014: 11×11 chevron, hover from tertiary → primary label
            // color so the affordance is discoverable without being noisy.
            HoverableBackButton(action: onBack)

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Project")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(TokenBarStyle.faint)
                        .textCase(.uppercase)
                    Text(detail.projectName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(projectPath ?? detail.projectName)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    TopRightCluster(
                        todayCost: projectTodayCost,
                        rangeCost: projectRangeCost,
                        todayTokens: projectTodaySummary.totalTokens,
                        totalTokens: projectRangeSummary.totalTokens,
                        todaySessions: projectTodaySessionCount,
                        refreshState: refreshState,
                        onRefresh: onRefresh,
                        rangeLabel: tokenbarRangeShortLabel(selectedRange)
                    )
                    DateRangeControl(selection: $selectedRange)
                    HStack(spacing: 34) {
                        statBlock(label: "Est. cost", value: tokenbarCompactCurrency(projectRangeCost), color: TokenBarStyle.cost)
                        statBlock(label: "All-time total", value: tokenbarCompactTokens(allTimeSummary.totalTokens), color: TokenBarStyle.foreground)
                    }
                }
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: TokenBarStyle.sectionSpacing) {
            TokenBarKPI(title: "Total", value: tokenbarTokens(projectRangeSummary.totalTokens), meta: tokenbarRangeShortLabel(selectedRange), color: TokenBarStyle.muted)
            TokenBarKPI(title: "Input", value: tokenbarTokens(projectRangeSummary.inputTokens), meta: "project input", color: TokenBarStyle.input)
            TokenBarKPI(title: "Output", value: tokenbarTokens(projectRangeSummary.outputTokens), meta: "project output", color: TokenBarStyle.output)
            TokenBarKPI(title: "Cache", value: tokenbarTokens(projectRangeSummary.cacheTokens), meta: "project cache", color: TokenBarStyle.cache)
        }
    }

    private var projectTodayStrip: some View {
        TokenBarCard {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("\(projectTodaySessionCount) sessions")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                }
                .frame(width: 116, alignment: .leading)

                todayMetric("Total", value: projectTodaySummary.totalTokens, color: TokenBarStyle.foreground)
                todayMetric("Input", value: projectTodaySummary.inputTokens, color: TokenBarStyle.input)
                todayMetric("Output", value: projectTodaySummary.outputTokens, color: TokenBarStyle.output)
                todayMetric("Cache", value: projectTodaySummary.cacheTokens, color: TokenBarStyle.cache)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(tokenbarCompactCurrency(projectTodayCost))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenBarStyle.cost)
                        .monospacedDigit()
                    Text("est. cost")
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.faint)
                }
            }
        }
    }

    private func todayMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TokenBarStyle.faint)
                .textCase(.uppercase)
            Text(tokenbarTokens(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectEvents: [UsageEvent] {
        events
    }

    private var projectMetricsTaskID: String {
        "\(detail.projectName)|\(selectedRange)|\(events.count)|\(events.last?.id ?? "none")|\(runtimeModel.promptSignature)|\(pricingOverridesJSON)"
    }

    private var projectRangeSummary: UsageSummary {
        projectMetrics.rangeSummary
    }

    private var projectTodaySummary: UsageSummary {
        projectMetrics.todaySummary
    }

    private var projectTodayCost: Double {
        projectMetrics.todayCost
    }

    private var projectTodaySessionCount: Int {
        projectMetrics.todaySessionCount
    }

    private var rangeDays: [UsageDay] {
        projectMetrics.days
    }

    private var modelRows: [TokenBarModelBreakdown] {
        projectMetrics.modelRows
    }

    private var projectRangeCost: Double {
        projectMetrics.rangeCost
    }

    private var projectAgentShare: [AgentShareSlice] {
        projectMetrics.agentShare
    }

    private var projectRecentSessions: [ProjectSessionSummary] {
        projectMetrics.recentSessions
    }

    @MainActor
    private func rebuildProjectMetrics(reason: String) async {
        let projectName = detail.projectName
        let selectedRange = selectedRange
        let events = events
        let started = Date()
        guard !events.isEmpty else {
            isRangeLoading = false
            TokenBarTelemetry.event(
                "project.detail.metrics.compute.skip",
                metadata: "reason=\(reason) project=\(projectName) range=\(selectedRange) events=0",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }
        TokenBarTelemetry.event(
            "project.detail.metrics.compute.begin",
            metadata: "reason=\(reason) project=\(projectName) range=\(selectedRange) events=\(events.count)",
            success: true
        )
        let metrics = await Task.detached(priority: .userInitiated) {
            ProjectDetailRangeMetrics.make(
                projectName: projectName,
                events: events,
                selection: selectedRange
            )
        }.value
        guard !Task.isCancelled, self.selectedRange == selectedRange else { return }
        projectMetrics = metrics
        let countsByDay: [Date: Int]
        let calendar = Calendar(identifier: .gregorian)
        if let firstDay = metrics.days.first?.date,
           let lastDay = metrics.days.last?.date,
           let end = calendar.date(byAdding: .day, value: 1, to: lastDay) {
            countsByDay = await runtimeModel.projectPromptCountsByDay(
                for: projectName,
                start: firstDay,
                end: end,
                calendar: calendar
            )
        } else {
            countsByDay = [:]
        }
        guard !Task.isCancelled, self.selectedRange == selectedRange else { return }
        promptCountsByDay = countsByDay
        TokenBarTelemetry.timing(
            "project.detail.metrics.compute",
            startedAt: started,
            metadata: "project=\(projectName) range=\(selectedRange) days=\(metrics.days.count) prompt_days=\(countsByDay.count) sessions=\(metrics.recentSessions.count) models=\(metrics.modelRows.count) tokens=\(metrics.rangeSummary.totalTokens)"
        )
        if self.selectedRange == selectedRange {
            withAnimation(.easeOut(duration: 0.14)) {
                isRangeLoading = false
            }
        }
    }

    private var agentShareCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent Share")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 22) {
                    TokenBarDonut(slices: projectAgentShare)
                        .frame(width: 150, height: 150)
                    VStack(spacing: 9) {
                        if projectAgentShare.isEmpty {
                            Text("No agent share available in this project window.")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(projectAgentShare.prefix(5)) { slice in
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(TokenBarStyle.agentColor(slice.name))
                                        .frame(width: 7, height: 7)
                                    Text(slice.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(tokenbarPercent(slice.percentage))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(TokenBarStyle.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 246, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 286)
    }

    private var recentSessionsCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if projectRecentSessions.isEmpty {
                    Text("No sessions in the current project window.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    ForEach(projectRecentSessions.prefix(6)) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                toggleExpandedSession(session.sessionId)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(TokenBarStyle.agentColor(session.agentName))
                                        .frame(width: 7, height: 7)
                                    Text(session.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.muted)
                                        .frame(width: 82, alignment: .leading)
                                    Text(shortSessionID(session.sessionId))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                        .frame(width: 74, alignment: .leading)
                                    Text(session.agentName)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.muted)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(TokenBarStyle.surfaceRaised, in: Capsule())
                                        .lineLimit(1)
                                        .frame(width: 82, alignment: .center)
                                    Text(tokenbarTokens(session.summary.totalTokens))
                                        .font(.system(size: 13, design: .monospaced))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(width: 70, alignment: .trailing)
                                    Image(systemName: expandedSession == session.sessionId ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .frame(width: 12, alignment: .trailing)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            // CL-P1-016: drawer with input/output/cache split.
                            if expandedSession == session.sessionId {
                                HStack(spacing: 18) {
                                    sessionStat("Input", value: session.summary.inputTokens, color: TokenBarStyle.input)
                                    sessionStat("Output", value: session.summary.outputTokens, color: TokenBarStyle.output)
                                    sessionStat("Cache", value: session.summary.cacheTokens, color: TokenBarStyle.cache)
                                    Spacer()
                                    Text(session.sessionId)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(TokenBarStyle.surfaceRaised,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 5)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func shortSessionID(_ sessionId: String) -> String {
        guard !sessionId.isEmpty else { return "session n/a" }
        return "sid " + String(sessionId.prefix(8))
    }

    private let promptPageSize = 12
    private let promptPanelHeight: CGFloat = 430

    private var promptHistoryCard: some View {
        let pagePrompts = pagedPromptHistory
        let currentSelectedPrompt = selectedPrompt(in: pagePrompts)

        return TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text("Prompt History")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Button {
                        revealPrompts.toggle()
                    } label: {
                        Label(revealPrompts ? "Hide" : "Reveal", systemImage: revealPrompts ? "eye.slash" : "eye")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TokenBarStyle.surfaceRaised, in: Capsule())
                            .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!runtimeModel.storePromptTextInClearText)
                    .opacity(runtimeModel.storePromptTextInClearText ? 1 : 0.5)
                    .help(runtimeModel.storePromptTextInClearText
                          ? (revealPrompts ? "Hide prompt text" : "Reveal stored prompt text")
                          : "Enable Prompt Text in Settings to allow Reveal")
                }

                promptHistoryControls

                Group {
                    if isPromptHistoryLoading && !hasPromptHistoryLoaded {
                        Text("Preparing prompt index.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if promptHistoryPage.totalCount == 0 {
                        Text(promptEmptyMessage)
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if pagePrompts.isEmpty {
                        Text("No prompts match the current search or cluster.")
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            promptListPane(
                                pagePrompts: pagePrompts,
                                currentSelectedPromptID: currentSelectedPrompt?.id
                            )
                            if let prompt = currentSelectedPrompt {
                                promptDetailPane(prompt)
                            }
                        }
                    }
                }
                .frame(height: promptPanelHeight, alignment: .top)
            }
        }
        .task(id: promptHistoryTaskID) {
            await loadPromptHistoryPage()
        }
    }

    private var promptHistorySubtitle: String {
        let loadingSuffix = isPromptHistoryLoading ? " · loading" : ""
        return "\(promptHistoryPage.totalCount) prompts · human \(promptHistoryPage.kindCounts.humanCount) · subagent \(promptHistoryPage.kindCounts.subagentCount) · command \(promptHistoryPage.kindCounts.commandCount)\(loadingSuffix)"
    }

    private var promptEmptyMessage: String {
        if !promptSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || promptClusterFilter != .all {
            return "No prompts match the current search or cluster."
        }
        return "No local prompt captures for this project."
    }

    private var promptHistoryControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            promptSearchField
            HStack(spacing: 7) {
                ForEach(PromptClusterFilter.allCases) { filter in
                    Button {
                        promptClusterFilter = filter
                        promptPage = 0
                        selectedPromptID = nil
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.displayName)
                            Text("\(promptFilterCount(filter))")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(promptClusterFilter == filter ? TokenBarStyle.foreground : TokenBarStyle.faint)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(promptClusterFilter == filter ? TokenBarStyle.foreground : TokenBarStyle.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            promptClusterFilter == filter ? TokenBarStyle.accent.opacity(0.18) : TokenBarStyle.surfaceRaised,
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .onChange(of: promptSearchText) { _, _ in
            promptPage = 0
            selectedPromptID = nil
        }
        .onChange(of: promptHistoryPage.totalCount) { _, _ in
            promptPage = min(promptPage, max(promptPageCount - 1, 0))
            selectedPromptID = nil
        }
    }

    private var promptSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.faint)
            TextField("Search prompt text, session, agent", text: $promptSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            if !promptSearchText.isEmpty {
                Button {
                    promptSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func promptListPane(
        pagePrompts: [PromptRecord],
        currentSelectedPromptID: String?
    ) -> some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(pagePrompts) { prompt in
                        promptHistoryRow(prompt, currentSelectedPromptID: currentSelectedPromptID)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(8)
            .background(TokenBarStyle.surface.opacity(0.52), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line.opacity(0.75), lineWidth: 1))

            promptPaginationControls
        }
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 400, maxHeight: .infinity, alignment: .top)
    }

    private var promptPaginationControls: some View {
        HStack(spacing: 8) {
            Text(promptPageLabel)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            Spacer()
            Button {
                promptPage = max(promptPage - 1, 0)
                selectedPromptID = nil
            } label: {
                Label("Prev", systemImage: "chevron.left")
            }
            .disabled(promptPage == 0)
            Button {
                promptPage = min(promptPage + 1, max(promptPageCount - 1, 0))
                selectedPromptID = nil
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(promptPage >= promptPageCount - 1)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(TokenBarStyle.muted)
        .padding(.top, 2)
    }

    private var pagedPromptHistory: [PromptRecord] {
        promptHistoryPage.prompts
    }

    private func selectedPrompt(in pagePrompts: [PromptRecord]) -> PromptRecord? {
        if let selectedPromptID,
           let prompt = pagePrompts.first(where: { $0.id == selectedPromptID }) {
            return prompt
        }
        return pagePrompts.first
    }

    private func promptHistoryRow(_ prompt: PromptRecord, currentSelectedPromptID: String?) -> some View {
        let cluster = promptCluster(for: prompt)
        let selected = currentSelectedPromptID == prompt.id
        let allowReveal = revealPrompts && runtimeModel.storePromptTextInClearText
        let metadata = promptMetadata(prompt)

        return Button {
            self.selectedPromptID = prompt.id
            TokenBarTelemetry.event(
                "project.detail.prompt.select",
                metadata: "project=\(detail.projectName) cluster=\(cluster.rawValue)",
                success: true
            )
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: cluster.iconName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(cluster.color)
                        .frame(width: 16, height: 16)
                        .background(cluster.color.opacity(0.14), in: Circle())
                    Text(cluster.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(cluster.color)
                    if runtimeModel.savedPromptSourceIds.contains(prompt.id) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.accent)
                            .help("Saved as prompt template")
                    }
                    Spacer(minLength: 8)
                    Text(prompt.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }

                Text(allowReveal ? promptRowTitle(prompt) : maskedPrompt(prompt.content))
                    .font(.system(size: 12.5, weight: .semibold, design: allowReveal && cluster == .command ? .monospaced : .default))
                    .foregroundStyle(allowReveal ? TokenBarStyle.foreground : TokenBarStyle.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(prompt.agent.displayName)
                    Text(shortSessionID(prompt.sessionId))
                    Text("\(metadata.lineCount)l")
                    Text("\(metadata.characterCount)c")
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? cluster.color.opacity(0.12) : TokenBarStyle.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? cluster.color.opacity(0.55) : TokenBarStyle.line.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func promptDetailPane(_ prompt: PromptRecord) -> some View {
        let cluster = promptCluster(for: prompt)
        let allowReveal = revealPrompts && runtimeModel.storePromptTextInClearText
        let metadata = promptMetadata(prompt)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(cluster == .command ? "Command detail" : "Prompt detail")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(TokenBarStyle.faint)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    copyPrompt(prompt.content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.muted)
                .disabled(!allowReveal)
                .opacity(allowReveal ? 1 : 0.35)
                .help(allowReveal ? "Copy prompt text" : "Reveal prompt text before copying")
                let existingTemplate = runtimeModel.savedPrompts.first { $0.sourcePromptId == prompt.id }
                Button {
                    if let existingTemplate {
                        saveAsTemplateTarget = .edit(existingTemplate)
                    } else {
                        saveAsTemplateTarget = .new(from: prompt)
                    }
                } label: {
                    Image(systemName: existingTemplate != nil ? "bookmark.fill" : "bookmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(existingTemplate != nil ? TokenBarStyle.accent : TokenBarStyle.muted)
                .disabled(!allowReveal)
                .opacity(allowReveal ? 1 : 0.35)
                .help(allowReveal
                      ? (existingTemplate != nil
                          ? "Edit saved template (/tbar:\(existingTemplate?.slug ?? ""))"
                          : "Save as reusable Claude Code slash command template")
                      : "Reveal prompt text before saving as a template")
            }

            promptDetailContent(prompt: prompt, cluster: cluster, allowReveal: allowReveal, metadata: metadata)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: promptPanelHeight, maxHeight: promptPanelHeight, alignment: .topLeading)
        .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line.opacity(0.75), lineWidth: 1))
    }

    @ViewBuilder
    private func promptDetailContent(
        prompt: PromptRecord,
        cluster: PromptCluster,
        allowReveal: Bool,
        metadata: PromptDisplayMetadata
    ) -> some View {
        if !allowReveal {
            promptHiddenPane()
        } else if cluster == .command, let command = promptCommandParts(prompt.content) {
            promptCommandPane(command)
        } else {
            promptLongTextPane(prompt.content, metadata: metadata)
        }
    }

    private func promptHiddenPane() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(maskedPrompt(""))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(TokenBarStyle.muted)
                .lineLimit(1)
            Text("Prompt text is hidden. Enable Prompt Text in Settings, then use Reveal.")
                .font(.caption)
                .foregroundStyle(TokenBarStyle.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TokenBarStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func promptCommandPane(_ command: PromptCommandParts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                promptSectionLabel("Command")
                Text(command.command)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.output)
                    .textSelection(.enabled)
            }

            if !command.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    promptSectionLabel("Arguments")
                    ScrollView {
                        Text(command.arguments)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.foreground)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(11)
                    }
                    .frame(maxHeight: 220)
                    .background(TokenBarStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(TokenBarStyle.line.opacity(0.75), lineWidth: 1))
                }
            }
        }
    }

    private func promptLongTextPane(_ content: String, metadata: PromptDisplayMetadata) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                promptSectionLabel(metadata.lineCount > 8 || metadata.characterCount > 700 ? "Long Input" : "Input")
                Spacer()
                Text("\(metadata.lineCount) lines · \(metadata.characterCount) chars")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
            }

            ScrollView {
                Text(content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.foreground)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxHeight: 310)
            .background(TokenBarStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(TokenBarStyle.line.opacity(0.75), lineWidth: 1))
        }
    }

    private func promptSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(TokenBarStyle.faint)
            .textCase(.uppercase)
    }

    private func promptRowTitle(_ prompt: PromptRecord) -> String {
        if let command = promptCommandParts(prompt.content) {
            return command.arguments.isEmpty
                ? command.command
                : "\(command.command) \(firstReadableLine(command.arguments))"
        }
        return compactPromptText(prompt.content, limit: 160)
    }

    private func promptMetadata(_ prompt: PromptRecord) -> PromptDisplayMetadata {
        PromptDisplayMetadata.make(prompt.content)
    }

    private func promptCommandParts(_ content: String) -> PromptCommandParts? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let command = promptSlashCommandToken(firstLine) else {
            return nil
        }
        let inlineArguments = firstLine
            .dropFirst(command.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let restArguments = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: String
        if inlineArguments.isEmpty {
            arguments = restArguments
        } else if restArguments.isEmpty {
            arguments = inlineArguments
        } else {
            arguments = inlineArguments + "\n" + restArguments
        }
        return PromptCommandParts(command: command, arguments: arguments)
    }

    private func firstReadableLine(_ source: String) -> String {
        let first = source
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? source
        return compactPromptText(first, limit: 96)
    }

    private func compactPromptText(_ source: String, limit: Int) -> String {
        let compact = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !compact.isEmpty else { return "Empty prompt" }
        guard compact.count > limit else { return compact }
        return String(compact.prefix(max(limit - 1, 1))) + "…"
    }

    private func copyPrompt(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        TokenBarTelemetry.event(
            "project.detail.prompt.copy",
            metadata: "project=\(detail.projectName) chars=\(content.count)",
            success: true
        )
    }

    private var promptPageCount: Int {
        max(1, Int(ceil(Double(promptHistoryPage.totalCount) / Double(promptPageSize))))
    }

    private var promptPageLabel: String {
        guard promptHistoryPage.totalCount > 0 else { return "0 of 0" }
        let safePage = min(promptPage, max(promptPageCount - 1, 0))
        let start = safePage * promptPageSize + 1
        let end = min(start + promptPageSize - 1, promptHistoryPage.totalCount)
        return "\(start)-\(end) of \(promptHistoryPage.totalCount) · page \(safePage + 1)/\(promptPageCount)"
    }

    private func promptFilterCount(_ filter: PromptClusterFilter) -> Int {
        switch filter {
        case .all:
            promptHistoryPage.kindCounts.totalCount
        case .human:
            promptHistoryPage.kindCounts.humanCount
        case .subagent:
            promptHistoryPage.kindCounts.subagentCount
        case .command:
            promptHistoryPage.kindCounts.commandCount
        case .bookmarked:
            promptHistoryPage.kindCounts.bookmarkedCount
        }
    }

    private func promptCluster(for prompt: PromptRecord) -> PromptCluster {
        PromptCluster.classify(prompt)
    }

    private var promptHistoryTaskID: String {
        [
            detail.projectName,
            "\(promptPage)",
            "\(promptPageSize)",
            promptSearchText,
            promptClusterFilter.rawValue,
            runtimeModel.promptSignature,
            "saved:\(runtimeModel.savedPromptSourceIds.count)",
        ].joined(separator: "|")
    }

    @MainActor
    private func loadPromptHistoryPage() async {
        let query = promptSearchText
        let filter = promptClusterFilter
        let page = promptPage
        let started = Date()
        isPromptHistoryLoading = true
        TokenBarTelemetry.event(
            "project.detail.prompt.page.begin",
            metadata: "project=\(detail.projectName) page=\(page) filter=\(filter.rawValue) query_chars=\(query.count)",
            success: true
        )
        let pageResult = await runtimeModel.projectPromptHistoryPage(
            for: detail.projectName,
            limit: promptPageSize,
            offset: page * promptPageSize,
            includeContent: true,
            query: query,
            kindFilter: filter.coreFilter
        )
        guard !Task.isCancelled,
              self.promptSearchText == query,
              self.promptClusterFilter == filter,
              self.promptPage == page else {
            isPromptHistoryLoading = false
            return
        }
        promptHistoryPage = pageResult
        hasPromptHistoryLoaded = true
        isPromptHistoryLoading = false
        promptPage = min(promptPage, max(promptPageCount - 1, 0))
        TokenBarTelemetry.timing(
            "project.detail.prompt.page",
            startedAt: started,
            metadata: "project=\(detail.projectName) page=\(page) rows=\(pageResult.prompts.count) total=\(pageResult.totalCount) filter=\(filter.rawValue)"
        )
    }

    private func toggleExpandedSession(_ sessionId: String) {
        let started = Date()
        let nextSession = expandedSession == sessionId ? nil : sessionId
        TokenBarTelemetry.event(
            "project.detail.session.toggle.begin",
            metadata: "project=\(detail.projectName) session=\(sessionId) expanding=\(nextSession != nil) cached_sessions=\(projectMetrics.recentSessions.count)",
            success: true
        )
        withAnimation(.easeOut(duration: 0.18)) {
            expandedSession = nextSession
        }
        Task { @MainActor in
            await Task.yield()
            TokenBarTelemetry.timing(
                "project.detail.session.toggle.first_runloop",
                startedAt: started,
                metadata: "project=\(detail.projectName) expanded=\(nextSession != nil)"
            )
            try? await Task.sleep(for: .milliseconds(16))
            TokenBarTelemetry.timing(
                "project.detail.session.toggle.first_frame_16ms",
                startedAt: started,
                metadata: "project=\(detail.projectName) expanded=\(nextSession != nil)"
            )
        }
    }

    private func sessionStat(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(TokenBarStyle.faint)
            Text(tokenbarTokens(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .tbNumberTooltip(precise: value, window: label.lowercased())
        }
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(TokenBarStyle.muted)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private func maskedPrompt(_ source: String) -> String {
        // CL-P0-033: exactly 54 bullet characters per entry (design canvas
        // spec) so all rows have a uniform "redacted" silhouette.
        guard !source.isEmpty else { return String(repeating: "•", count: 54) }
        return String(repeating: "•", count: 54)
    }
}

private struct ProjectDetailRangeMetrics: Sendable, Hashable {
    let days: [UsageDay]
    let availabilityNote: String
    let rangeSummary: UsageSummary
    let todaySummary: UsageSummary
    let rangeCost: Double
    let todayCost: Double
    let todaySessionCount: Int
    let modelRows: [TokenBarModelBreakdown]
    let agentShare: [AgentShareSlice]
    let recentSessions: [ProjectSessionSummary]

    static let empty = ProjectDetailRangeMetrics(
        days: [],
        availabilityNote: "Preparing range",
        rangeSummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        todaySummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        rangeCost: 0,
        todayCost: 0,
        todaySessionCount: 0,
        modelRows: [],
        agentShare: [],
        recentSessions: []
    )

    static func snapshot(
        detail: ProjectDetailSnapshot,
        rangeCost: Double,
        todayCost: Double,
        todayTokens: Int,
        totalTokens: Int,
        todaySessions: Int
    ) -> ProjectDetailRangeMetrics {
        let rangeSummary = totalTokens > 0
            ? detail.summary
            : UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        return ProjectDetailRangeMetrics(
            days: detail.last30Days,
            availabilityNote: "Preparing selected range",
            rangeSummary: rangeSummary,
            todaySummary: UsageSummary(inputTokens: todayTokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
            rangeCost: rangeCost,
            todayCost: todayCost,
            todaySessionCount: todaySessions,
            modelRows: [],
            agentShare: detail.agentShare,
            recentSessions: detail.recentSessions
        )
    }

    static func make(
        projectName: String,
        events: [UsageEvent],
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> ProjectDetailRangeMetrics {
        let projectEvents = events.filter { $0.projectName == projectName }
        let rangeEvents = tokenbarRangeEvents(
            events: projectEvents,
            selection: selection,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let todayEvents = tokenbarEventsInLastDays(
            events: projectEvents,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let days = tokenbarUsageDays(
            events: projectEvents,
            selection: selection,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return ProjectDetailRangeMetrics(
            days: days,
            availabilityNote: tokenbarRangeAvailabilityNote(
                selection: selection,
                days: days,
                events: projectEvents,
                referenceDate: referenceDate,
                calendar: calendar
            ),
            rangeSummary: tokenbarSummary(rangeEvents),
            todaySummary: tokenbarSummary(todayEvents),
            rangeCost: tokenbarEstimatedCost(events: rangeEvents),
            todayCost: tokenbarEstimatedCost(events: todayEvents),
            todaySessionCount: tokenbarSessionCount(projectEvents, referenceDate: referenceDate),
            modelRows: tokenbarModelBreakdowns(events: rangeEvents, days: nil, referenceDate: referenceDate, calendar: calendar),
            agentShare: tokenbarAgentShare(events: rangeEvents),
            recentSessions: tokenbarRecentSessions(events: rangeEvents, limit: 6)
        )
    }
}

private struct PromptDisplayMetadata: Sendable, Hashable {
    let characterCount: Int
    let lineCount: Int

    static func make(_ content: String) -> PromptDisplayMetadata {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = max(1, trimmed.split(whereSeparator: \.isNewline).count)
        return PromptDisplayMetadata(characterCount: trimmed.count, lineCount: lineCount)
    }
}

private struct PromptCommandParts: Sendable, Hashable {
    let command: String
    let arguments: String
}

private func promptSlashCommandToken(_ firstLine: String) -> String? {
    guard let firstToken = firstLine
        .split(whereSeparator: \.isWhitespace)
        .first
        .map(String.init),
        firstToken.hasPrefix("/") else {
        return nil
    }

    let commandBody = firstToken.dropFirst()
    guard !commandBody.isEmpty,
          !commandBody.contains("/") else {
        return nil
    }

    guard commandBody.allSatisfy({ character in
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }) else {
        return nil
    }

    return "/" + String(commandBody)
}

private enum PromptCluster: String, CaseIterable, Hashable, Sendable {
    case human
    case subagent
    case command

    var displayName: String {
        switch self {
        case .human:
            "Human"
        case .subagent:
            "Subagent"
        case .command:
            "Command"
        }
    }

    var iconName: String {
        switch self {
        case .human:
            "person.text.rectangle"
        case .subagent:
            "point.3.connected.trianglepath.dotted"
        case .command:
            "terminal"
        }
    }

    var color: Color {
        switch self {
        case .human:
            TokenBarStyle.input
        case .subagent:
            TokenBarStyle.cache
        case .command:
            TokenBarStyle.output
        }
    }

    static func classify(_ prompt: PromptRecord) -> PromptCluster {
        let content = prompt.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedContent = content.lowercased()
        let lowercasedPath = prompt.sourcePath.lowercased()

        if looksLikeCommand(content) {
            return .command
        }

        if lowercasedPath.contains("/subagents/")
            || lowercasedContent.contains("subagent")
            || lowercasedContent.contains("sub-agent")
            || lowercasedContent.contains("mainagent")
            || lowercasedContent.contains("main agent")
            || lowercasedContent.contains("assigned task")
            || lowercasedContent.contains("you are not alone in the codebase") {
            return .subagent
        }

        return .human
    }

    private static func looksLikeCommand(_ content: String) -> Bool {
        guard let firstLine = content
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return promptSlashCommandToken(firstLine) != nil
    }
}

private enum PromptClusterFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case human
    case subagent
    case command
    case bookmarked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            "All"
        case .human:
            "Human"
        case .subagent:
            "Subagent"
        case .command:
            "Command"
        case .bookmarked:
            "Bookmarked"
        }
    }

    var coreFilter: PromptHistoryKindFilter {
        switch self {
        case .all:
            .all
        case .human:
            .human
        case .subagent:
            .subagent
        case .command:
            .command
        case .bookmarked:
            .bookmarked
        }
    }
}

/// CL-P1-014: hoverable Back chevron with design-spec 11pt glyph.
private struct HoverableBackButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 11, height: 11)
                Text("Back")
                    .font(.caption)
            }
            .foregroundStyle(hovered ? TokenBarStyle.foreground : TokenBarStyle.faint)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut(.escape, modifiers: [])
    }
}
