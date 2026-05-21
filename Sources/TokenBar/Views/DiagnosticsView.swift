import SwiftUI
import TokenBarCore

struct DiagnosticsView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showReparseConfirm = false  // CL-P1-020
    @State private var showWipeConfirm = false     // CL-P1-021
    @State private var wipeAck = ""                // CL-P1-021: type "WIPE"
    @State private var expandedSourceId: String?   // CL-P1-023

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            header
            sourcesCard
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
                    todayCost: runtimeModel.snapshot.estimatedCostToday.totalCost,
                    rangeCost: runtimeModel.snapshot.estimatedCostLast30.totalCost,
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
                    Task { await runtimeModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(SpinningRefreshLabelStyle(spinning: runtimeModel.refreshState == .refreshing))
                }
                .buttonStyle(DiagnosticsButtonStyle(kind: .primary))
                .disabled(runtimeModel.refreshState == .refreshing)

                Button {
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
                                .background(Color.white.opacity(0.04), in: Capsule())
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
            warnings: "\(checkpoint.warnings)",
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

private struct PendingDiagnosticsAction: View {
    let title: String
    var kind: DiagnosticsButtonStyle.Kind = .ghost
    var size: DiagnosticsButtonStyle.Size = .regular

    init(_ title: String, kind: DiagnosticsButtonStyle.Kind = .ghost, size: DiagnosticsButtonStyle.Size = .regular) {
        self.title = title
        self.kind = kind
        self.size = size
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("Soon")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TokenBarStyle.warn)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(TokenBarStyle.warn.opacity(0.12), in: Capsule())
        }
        .font(.system(size: size == .small ? 10.5 : 12, weight: .medium))
        .padding(.horizontal, size == .small ? 8 : 11)
        .frame(height: size == .small ? 24 : 32)
        .foregroundStyle(kind == .danger ? TokenBarStyle.error : TokenBarStyle.muted)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        .help("Coming soon")
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
            Color(red: 0.12, green: 0.54, blue: 0.82)
        case .ghost:
            Color.white.opacity(0.035)
        case .danger:
            TokenBarStyle.error.opacity(0.08)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary:
            Color.white.opacity(0.12)
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
