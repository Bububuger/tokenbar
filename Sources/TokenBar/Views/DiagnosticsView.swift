import SwiftUI
import TokenBarCore

struct DiagnosticsView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showReparseConfirm = false  // CL-P1-020
    @State private var showWipeConfirm = false     // CL-P1-021
    @State private var wipeAck = ""                // CL-P1-021: type "WIPE"
    @State private var expandedSourceId: String?   // CL-P1-023
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            header
            dataAuditCard
            sourcesCard
            warningsCard
            checkpointsCard
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diagnostics")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Source health, parser status, and checkpoint history.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                }
                Spacer()
                TopRightCluster(
                    todayCost: tokenbarEstimatedCost(events: runtimeModel.events, days: 1),
                    rangeCost: tokenbarEstimatedCost(events: runtimeModel.events, days: 30),
                    todayTokens: runtimeModel.snapshot.today.totalTokens,
                    totalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                    todaySessions: tokenbarSessionCount(runtimeModel.events),
                    refreshState: runtimeModel.refreshState,
                    onRefresh: { Task { await runtimeModel.refresh() } }
                )
            }

            HStack(spacing: 8) {
                Spacer()
                // CL-P0-021: Refresh is disabled while a refresh is in flight
                // and the icon spins to surface the "click registered" state.
                Button {
                    TokenBarTelemetry.event("diagnostics.refresh.click", success: true)
                    Task { await runtimeModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(SpinningRefreshLabelStyle(spinning: runtimeModel.refreshState == .refreshing))
                }
                .buttonStyle(DiagnosticsButtonStyle(kind: .primary))
                .disabled(runtimeModel.refreshState == .refreshing)

                Button {
                    TokenBarTelemetry.event("diagnostics.reparse_all.confirm.open", success: true)
                    showReparseConfirm = true
                } label: {
                    Label("Reparse all", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(DiagnosticsButtonStyle(kind: .ghost))
                .disabled(runtimeModel.refreshState == .refreshing)
                .confirmationDialog("Reparse all sources?",
                                    isPresented: $showReparseConfirm) {
                    Button("Reparse", role: .destructive) {
                        Task { await runtimeModel.reparseAllSources() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Estimated ~\(estimatedReparseSeconds())s. Token totals will rebuild from raw events.")
                }

                Button(role: .destructive) {
                    TokenBarTelemetry.event("diagnostics.wipe_prompts.confirm.open", success: true)
                    showWipeConfirm = true
                    wipeAck = ""
                } label: {
                    Label("Wipe prompts", systemImage: "trash")
                }
                .buttonStyle(DiagnosticsButtonStyle(kind: .ghost))
                .alert("Wipe all stored prompt text?", isPresented: $showWipeConfirm) {
                    TextField("Type WIPE to confirm", text: $wipeAck)
                    Button("Cancel", role: .cancel) {}
                    Button("Wipe", role: .destructive) {
                        guard wipeAck == "WIPE" else { return }
                        Task { try? await runtimeModel.wipePrompts() }
                    }
                    .disabled(wipeAck != "WIPE")
                } message: {
                    Text("This deletes every prompt record. Token totals are unaffected. Type WIPE to confirm.")
                }
            }
        }
    }

    private func estimatedReparseSeconds() -> Int {
        // 1 second per ~100 events, min 1s, capped at 60s for UI display
        max(1, min(runtimeModel.events.count / 100, 60))
    }

    private var dataAuditCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Token Data Audit")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Indexed raw totals by source. Cache share is calculated from stored usage_events.")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    Text("\(runtimeModel.events.count.formatted()) events")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(TokenBarStyle.surfaceRaised, in: Capsule())
                }

                Grid(horizontalSpacing: 14, verticalSpacing: 0) {
                    GridRow {
                        auditHead("Source", align: .leading)
                        auditHead("Input")
                        auditHead("Output")
                        auditHead("Cache")
                        auditHead("Cache %")
                    }
                    Divider().gridCellColumns(5).overlay(TokenBarStyle.line)
                    ForEach(dataAuditRows) { row in
                        GridRow {
                            auditCell(row.name, align: .leading)
                            auditCell(row.input)
                            auditCell(row.output, color: TokenBarStyle.output)
                            auditCell(row.cache, color: TokenBarStyle.cache)
                            auditCell(row.cacheShare, color: row.cacheShareValue < 0.10 ? TokenBarStyle.warn : TokenBarStyle.muted)
                        }
                        .padding(.vertical, 8)
                        Divider().gridCellColumns(5).overlay(TokenBarStyle.line.opacity(0.55))
                    }
                }
            }
        }
    }

    /// CL-P1-023: drawer body — most recent 50 events whose `sourcePath`
    /// prefix matches the source row's path token.
    @ViewBuilder
    private func sourceEventsDrawer(matching path: String) -> some View {
        let prefix = (path as NSString).expandingTildeInPath
        let matched = runtimeModel.events
            .filter { $0.sourcePath.hasPrefix(prefix) || $0.sourcePath.contains(path) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(50)
        if matched.isEmpty {
            Text("No indexed events for this source yet.")
                .font(.caption)
                .foregroundStyle(TokenBarStyle.muted)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(matched), id: \.id) { event in
                    HStack(spacing: 10) {
                        Text(event.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.muted)
                        Text(event.parser.rawValue)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                        Spacer()
                        Text(tokenbarTokens(event.inputTokens + event.outputTokens + event.cacheTokens))
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var sourcesCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sources")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))

                ForEach(sourceRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                expandedSourceId = (expandedSourceId == row.id.uuidString) ? nil : row.id.uuidString
                            }
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: row.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(row.color)
                                    .frame(width: 24, height: 24)
                                    .background(row.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.name)
                                        .font(.system(size: 14, weight: .medium))
                                    Text(row.path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.muted)
                                        .lineLimit(1)
                                    if let note = row.note {
                                        Text(note)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(row.color)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(row.events)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .monospacedDigit()
                                    Text(row.when)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                }

                                // CL-P1-022: per-source reparse hook. Delete
                                // the matching watermark prefix and refresh.
                                Button("Reparse") {
                                    TokenBarTelemetry.event("diagnostics.source.reparse.click", metadata: "source=\(row.path)", success: true)
                                    Task { await runtimeModel.reparseSource(row.path) }
                                }
                                .controlSize(.small)
                                .disabled(runtimeModel.refreshState == .refreshing)
                            }
                        }
                        .buttonStyle(.plain)
                        // CL-P1-023: drawer listing the last 50 indexed events
                        // for the matching source path.
                        if expandedSourceId == row.id.uuidString {
                            sourceEventsDrawer(matching: row.path)
                                .transition(.opacity)
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
                }
            }
        }
    }

    private var warningsCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Actionable Warnings")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Internal indexing notes are hidden. Only source issues that may need your action appear here.")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    Text("\(runtimeModel.sourceWarnings.count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(runtimeModel.sourceWarnings.isEmpty ? TokenBarStyle.faint : TokenBarStyle.warn)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((runtimeModel.sourceWarnings.isEmpty ? TokenBarStyle.surfaceRaised : TokenBarStyle.warn.opacity(0.12)), in: Capsule())
                }

                if runtimeModel.sourceWarnings.isEmpty {
                    Text("No source issues need action from the latest refresh.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(runtimeModel.sourceWarnings.prefix(10).enumerated()), id: \.offset) { _, warning in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(warning.sourceName)
                                        .font(.system(size: 11.5, weight: .semibold))
                                    if let line = warning.lineNumber {
                                        Text("line \(line)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(TokenBarStyle.faint)
                                    }
                                    Spacer()
                                }
                                Text(warning.message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.warn)
                                    .lineLimit(2)
                                Text(warning.sourcePath)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.faint)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.55)), alignment: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var checkpointsCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Checkpoints")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))

                Grid(horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        tableHead("When")
                        tableHead("Trigger")
                        tableHead("Events")
                        tableHead("Prompts")
                        tableHead("Warnings")
                        tableHead("Duration")
                    }
                    Divider().gridCellColumns(6).overlay(TokenBarStyle.line)
                    ForEach(checkpointRows) { row in
                        GridRow {
                            tableCell(row.when, muted: true)
                            Text(row.trigger)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TokenBarStyle.muted)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(TokenBarStyle.surfaceRaised, in: Capsule())
                            tableCell(row.events)
                            tableCell(row.prompts)
                            tableCell(row.warnings, color: row.warnings == "0" ? TokenBarStyle.faint : TokenBarStyle.warn)
                            tableCell(row.duration)
                        }
                        .padding(.vertical, 9)
                        Divider().gridCellColumns(6).overlay(TokenBarStyle.line.opacity(0.65))
                    }
                }

                Text("Model attribution note: Hermes is session-level until per-call model details exist; Codex and Claude use per-event model metadata when present.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.muted)
            }
        }
    }

    private var sourceRows: [SourceRow] {
        if runtimeModel.diagnostics.dataSourceStatuses.isEmpty {
            return [
                SourceRow(name: "Claude Code", path: "~/.claude/projects/", state: .pending, events: "pending", when: "after refresh", note: nil),
                SourceRow(name: "Codex", path: "~/.codex/sessions/", state: .pending, events: "pending", when: "after refresh", note: nil),
                SourceRow(name: "Hermes", path: "~/.hermes/state.db", state: .pending, events: "pending", when: "after refresh", note: "session-level model attribution"),
            ]
        }

        return runtimeModel.diagnostics.dataSourceStatuses.map { status in
            let eventCount = runtimeModel.events.filter { event in
                event.sourcePath.hasPrefix(status.rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory()))
            }.count
            let note: String?
            if !status.isReadable {
                note = "path unavailable - will retry"
            } else if status.sourceName.localizedCaseInsensitiveContains("Hermes") {
                note = "session-level model attribution"
            } else {
                note = nil
            }
            return SourceRow(
                name: status.sourceName,
                path: status.rootPath,
                state: status.isReadable ? .ok : .err,
                events: eventCount > 0 ? "\(eventCount.formatted()) events" : "\(status.discoveredFileCount.formatted()) files",
                when: tokenbarRelativeTime(runtimeModel.diagnostics.lastIndexedAt),
                note: note
            )
        }
    }

    private var checkpointRows: [CheckpointRow] {
        guard let checkpoint = runtimeModel.lastCheckpoint else {
            return [
                CheckpointRow(when: "never", trigger: "none", events: "0", prompts: "0", warnings: "\(runtimeModel.diagnostics.parserWarningCount)", duration: "n/a")
            ]
        }
        let duration = checkpoint.endedAt.map { $0.timeIntervalSince(checkpoint.startedAt) }
        let latest = CheckpointRow(
            when: tokenbarRelativeTime(checkpoint.startedAt),
            trigger: checkpoint.trigger,
            events: "\(checkpoint.eventsAdded)",
            prompts: "\(checkpoint.promptsAdded)",
            warnings: "\(runtimeModel.diagnostics.parserWarningCount)",
            duration: duration.map(formatDuration) ?? "running"
        )
        let uiRefresh = CheckpointRow(
            when: tokenbarRelativeTime(runtimeModel.diagnostics.lastUIRefreshAt),
            trigger: "ui-refresh",
            events: "\(runtimeModel.events.count.formatted())",
            prompts: "\(runtimeModel.prompts.count.formatted())",
            warnings: "\(runtimeModel.diagnostics.parserWarningCount)",
            duration: "derived"
        )
        let indexState = CheckpointRow(
            when: tokenbarRelativeTime(runtimeModel.diagnostics.lastIndexedAt),
            trigger: "index-state",
            events: "\(runtimeModel.diagnostics.lastCheckpointEventsAdded)",
            prompts: "\(runtimeModel.diagnostics.lastCheckpointPromptsAdded)",
            warnings: runtimeModel.diagnostics.rebuildError == nil ? "0" : "1",
            duration: runtimeModel.diagnostics.refreshState.rawValue
        )
        return [
            latest,
            uiRefresh,
            indexState,
        ]
    }

    private var dataAuditRows: [DataAuditRow] {
        let grouped = Dictionary(grouping: runtimeModel.events, by: { $0.agent.displayName })
        let rows = grouped.map { agent, events -> DataAuditRow in
            let summary = UsageSummary(
                inputTokens: events.reduce(0) { $0 + $1.inputTokens },
                outputTokens: events.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: events.reduce(0) { $0 + $1.cacheTokens }
            )
            return DataAuditRow(name: agent, summary: summary)
        }
        .sorted { $0.summary.totalTokens > $1.summary.totalTokens }

        let total = UsageSummary(
            inputTokens: runtimeModel.events.reduce(0) { $0 + $1.inputTokens },
            outputTokens: runtimeModel.events.reduce(0) { $0 + $1.outputTokens },
            cacheTokens: runtimeModel.events.reduce(0) { $0 + $1.cacheTokens }
        )
        return [DataAuditRow(name: "All sources", summary: total)] + rows
    }

    private func auditHead(_ text: String, align: Alignment = .trailing) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TokenBarStyle.faint)
            .frame(maxWidth: .infinity, alignment: align)
    }

    private func auditCell(_ text: String, color: Color? = nil, align: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(color ?? TokenBarStyle.foreground)
            .frame(maxWidth: .infinity, alignment: align)
    }

    private func tableHead(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TokenBarStyle.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String, muted: Bool = false, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color ?? (muted ? TokenBarStyle.muted : TokenBarStyle.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        if ms < 1000 { return "\(ms)ms" }
        return "\(Int(seconds.rounded()))s"
    }
}

private struct SourceRow: Identifiable {
    enum State {
        case ok
        case pending
        case off
        case err
    }

    let id = UUID()
    let name: String
    let path: String
    let state: State
    let events: String
    let when: String
    let note: String?

    var color: Color {
        switch state {
        case .ok:
            TokenBarStyle.cache
        case .pending:
            TokenBarStyle.warn
        case .off:
            TokenBarStyle.muted
        case .err:
            TokenBarStyle.error
        }
    }

    var icon: String {
        switch state {
        case .ok:
            "checkmark.circle"
        case .pending:
            "exclamationmark.triangle"
        case .off:
            "minus.circle"
        case .err:
            "xmark.circle"
        }
    }
}

private struct CheckpointRow: Identifiable {
    let id = UUID()
    let when: String
    let trigger: String
    let events: String
    let prompts: String
    let warnings: String
    let duration: String
}

private struct DataAuditRow: Identifiable {
    let id = UUID()
    let name: String
    let summary: UsageSummary

    var input: String { tokenbarCompactTokens(summary.inputTokens) }
    var output: String { tokenbarCompactTokens(summary.outputTokens) }
    var cache: String { tokenbarCompactTokens(summary.cacheTokens) }

    var cacheShareValue: Double {
        guard summary.totalTokens > 0 else { return 0 }
        return Double(summary.cacheTokens) / Double(summary.totalTokens)
    }

    var cacheShare: String {
        String(format: "%.2f%%", cacheShareValue * 100)
    }
}

private struct DiagnosticsButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case ghost
        case danger
    }

    enum Size {
        case regular
        case small
    }

    let kind: Kind
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 11 : 12.5, weight: .medium))
            .padding(.horizontal, size == .small ? 9 : 13)
            .frame(height: size == .small ? 24 : 32)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous).stroke(stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            .white
        case .ghost:
            TokenBarStyle.foreground
        case .danger:
            TokenBarStyle.error
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            TokenBarStyle.accent
        case .ghost:
            TokenBarStyle.surfaceRaised
        case .danger:
            TokenBarStyle.error.opacity(0.08)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary:
            TokenBarStyle.accent.opacity(0.35)
        case .ghost:
            TokenBarStyle.line
        case .danger:
            TokenBarStyle.error.opacity(0.30)
        }
    }
}

/// CL-P0-021: rotates the icon 360° while `spinning` is true. Reduce Motion is
/// respected — when the environment disables motion the icon stays static.
struct SpinningRefreshLabelStyle: LabelStyle {
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .rotationEffect(.degrees(reduceMotion ? 0 : angle))
                .animation(spinning && !reduceMotion
                           ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                           : .default,
                           value: angle)
                .onAppear { if spinning { angle = 360 } }
                .onChange(of: spinning) { _, isSpinning in
                    angle = isSpinning ? 360 : 0
                }
            configuration.title
        }
    }
}
