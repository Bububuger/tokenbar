import SwiftUI
import TokenBarCore

struct DiagnosticsView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showReparseConfirm = false  // CL-P1-020
    @State private var showWipeConfirm = false     // CL-P1-021
    @State private var wipeAck = ""                // CL-P1-021: type "WIPE"
    @State private var expandedSourceId: String?   // CL-P1-023
    @State private var derivedRows = DiagnosticsDerivedRows.empty
    @State private var isBuildingDerivedRows = false
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            header
            if runtimeModel.indexingState.isVisible {
                TokenBarIndexingStatusCard(
                    state: runtimeModel.indexingState,
                    showActions: true,
                    onPause: { runtimeModel.pauseInitialIndexing() },
                    onRetry: { runtimeModel.retryInitialIndexing() },
                    onOpenDiagnostics: nil
                )
            }
            diagStatStrip
            tokenDataAndSourcesCard
            pluginSourcesCard
            normalizeActivityCard
            executableRuntimeCard
            warningsCard
            checkpointsCard
        }
        .task(id: diagnosticsDerivedRowsTaskID) {
            await rebuildDerivedRows()
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
                    todayCost: runtimeModel.popoverSnapshot.todayCost,
                    rangeCost: runtimeModel.popoverSnapshot.last30Cost,
                    todayTokens: runtimeModel.snapshot.today.totalTokens,
                    totalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                    todaySessions: runtimeModel.popoverSnapshot.todaySessionCount,
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
                .help("Incrementally checks known sources and imports only new records since the last watermark.")

                Button {
                    TokenBarTelemetry.event("diagnostics.reparse_all.confirm.open", success: true)
                    showReparseConfirm = true
                } label: {
                    Label("Reparse all", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(DiagnosticsButtonStyle(kind: .ghost))
                .disabled(runtimeModel.refreshState == .refreshing)
                .help("Clears parser watermarks and rebuilds token totals from the raw local source files.")
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
                .help("Deletes stored prompt text only. Token totals, sessions, and costs remain.")
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

    private var diagnosticsDerivedRowsTaskID: String {
        [
            runtimeModel.eventSignature,
            runtimeModel.customSources.map { "\($0.id):\($0.name):\($0.enabled)" }.joined(separator: ","),
            runtimeModel.diagnostics.dataSourceStatuses.map { "\($0.sourceName):\($0.rootPath):\($0.discoveredFileCount):\($0.isReadable)" }.joined(separator: ","),
            runtimeModel.diagnostics.lastIndexedAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()).description } ?? "never",
        ].joined(separator: "|")
    }

    @MainActor
    private func rebuildDerivedRows() async {
        let started = Date()
        let events = runtimeModel.events
        let customSources = runtimeModel.customSources
        let statuses = runtimeModel.diagnostics.dataSourceStatuses
        let lastIndexedAt = runtimeModel.diagnostics.lastIndexedAt
        isBuildingDerivedRows = true
        TokenBarTelemetry.event(
            "diagnostics.derived_rows.begin",
            metadata: "events=\(events.count) custom_sources=\(customSources.count) statuses=\(statuses.count)",
            success: true
        )
        let rows = await Task.detached(priority: .utility) {
            DiagnosticsDerivedRows.make(
                events: events,
                customSources: customSources,
                statuses: statuses,
                lastIndexedAt: lastIndexedAt
            )
        }.value
        guard !Task.isCancelled else {
            isBuildingDerivedRows = false
            return
        }
        derivedRows = rows
        isBuildingDerivedRows = false
        TokenBarTelemetry.timing(
            "diagnostics.derived_rows",
            startedAt: started,
            metadata: "source_rows=\(rows.sourceRows.count) audit_rows=\(rows.dataAuditRows.count)"
        )
    }

    private func estimatedReparseSeconds() -> Int {
        // 1 second per ~100 events, min 1s, capped at 60s for UI display
        max(1, min(runtimeModel.eventCount / 100, 60))
    }

    private var diagStatStrip: some View {
        let builtinCount = sourceRows.filter { !$0.id.hasPrefix("custom|") && !$0.id.hasPrefix("plugin-") }.count
        let pluginCount = runtimeModel.customSources.filter { $0.isPlugin }.count
        let builtinWarnings = sourceRows.filter { $0.state != .ok && !$0.id.hasPrefix("custom|") }.count
        let pluginWarnings = runtimeModel.customSources.filter { $0.isPlugin && !$0.enabled }.count
        return HStack(spacing: 12) {
            diagStatTile(value: "\(builtinCount)", label: "built-in sources", sub: "\(builtinWarnings) warning\(builtinWarnings == 1 ? "" : "s")", subWarn: builtinWarnings > 0)
            diagStatTile(value: "\(pluginCount)", label: "plugins installed", sub: "\(pluginWarnings) warning\(pluginWarnings == 1 ? "" : "s")", subWarn: pluginWarnings > 0)
            diagStatTile(value: "\(runtimeModel.eventCount.formatted())", label: "total events", sub: "across all sources", subWarn: false)
            diagStatTile(value: "\(runtimeModel.diagnostics.parserWarningCount)", label: "warnings", sub: "from latest refresh", subWarn: runtimeModel.diagnostics.parserWarningCount > 0)
        }
    }

    private func diagStatTile(value: String, label: String, sub: String, subWarn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(TokenBarStyle.foreground)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TokenBarStyle.muted)
            Text(sub)
                .font(.system(size: 10.5))
                .foregroundStyle(subWarn ? TokenBarStyle.warn : TokenBarStyle.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private var pluginSourcesCard: some View {
        let pluginSources = runtimeModel.customSources.filter { $0.isPlugin }
        return TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Plugin Sources")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Community manifests via registry \u{00B7} \(pluginSources.count) installed")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    Button("manage in Settings \u{2192} Plugins") {}
                        .font(.system(size: 11))
                        .foregroundStyle(TokenBarStyle.accent)
                        .buttonStyle(.plain)
                }

                if pluginSources.isEmpty {
                    Text("No plugins installed. Install from Settings \u{2192} Plugins.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(pluginSources, id: \.id) { source in
                        HStack(spacing: 14) {
                            Text(String(source.name.prefix(2)).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 28, height: 28)
                                .background(TokenBarStyle.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(TokenBarStyle.accent)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(source.name)
                                        .font(.system(size: 14, weight: .medium))
                                    Text(source.plugin.isPlugin ? source.plugin.displayName : "plugin")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(red: 0.83, green: 0.97, blue: 0.42).opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color(red: 0.83, green: 0.97, blue: 0.42))
                                }
                                Text(source.directory)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.muted)
                                    .lineLimit(1)
                                if source.inputIncludesCached {
                                    Text("inputIncludesCached:true \u{00B7} normalizer subtracts cache_read on every event")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.input)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                Text(source.enabled ? "enabled" : "paused")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(source.enabled ? TokenBarStyle.cache : TokenBarStyle.faint)
                                if let version = source.pluginVersion {
                                    Text("v\(version)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(TokenBarStyle.faint)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
                    }
                }
            }
        }
    }

    private var normalizeActivityCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Token Normalize Activity")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Every event passes the normalizer \u{00B7} clamp negatives \u{2192} 0 \u{00B7} if inputIncludesCached:true, subtract cache_read from input")
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.muted)
                }
                let pluginsWithCacheSub = runtimeModel.customSources.filter { $0.isPlugin && $0.inputIncludesCached }
                if pluginsWithCacheSub.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.cache)
                        Text("All sources report net input tokens \u{2014} no cache subtraction needed.")
                            .font(.system(size: 12))
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(pluginsWithCacheSub, id: \.id) { source in
                        HStack(spacing: 10) {
                            Text(source.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(TokenBarStyle.foreground)
                            Text("cache-subtracted")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color(red: 1.0, green: 0.71, blue: 0.33).opacity(0.14), in: Capsule())
                                .foregroundStyle(Color(red: 1.0, green: 0.71, blue: 0.33))
                            Spacer()
                            Text("input -= min(cache_read, input)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(TokenBarStyle.faint)
                        }
                        .padding(.vertical, 6)
                        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.55)), alignment: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var executableRuntimeCard: some View {
        let execSources = runtimeModel.customSources.filter { $0.plugin == .pluginExecutable }
        return TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Executable Plugin Runtime")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Spawned subprocesses \u{00B7} NDJSON on stdout \u{00B7} stderr \u{2192} ParseWarning \u{00B7} timeout-capped")
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.muted)
                }

                if execSources.isEmpty {
                    Text("No executable plugins installed.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                        .padding(.vertical, 6)
                } else {
                    Grid(horizontalSpacing: 14, verticalSpacing: 0) {
                        GridRow {
                            execHead("Plugin")
                            execHead("Command")
                            execHead("Timeout")
                            execHead("Status")
                        }
                        Divider().gridCellColumns(4).overlay(TokenBarStyle.line)
                        ForEach(execSources, id: \.id) { source in
                            GridRow {
                                Text(source.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(source.executableConfig?.command ?? "\u{2014}")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                Text("\(source.executableConfig?.effectiveTimeout ?? 30)s")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.faint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(source.enabled ? "active" : "paused")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(source.enabled ? TokenBarStyle.cache : TokenBarStyle.faint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            Divider().gridCellColumns(4).overlay(TokenBarStyle.line.opacity(0.55))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func execHead(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TokenBarStyle.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenDataAndSourcesCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 16) {
                // Token Data Audit Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Token Data Audit")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text("Indexed raw totals by configured source. Cache share is calculated from stored usage_events.")
                                .font(.caption2)
                                .foregroundStyle(TokenBarStyle.muted)
                        }
                        Spacer()
                        Text("\(runtimeModel.eventCount.formatted()) events")
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

                Divider().overlay(TokenBarStyle.line)

                // Sources Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sources")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))

                    ForEach(sourceRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedSourceId = (expandedSourceId == row.id) ? nil : row.id
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

                                    Button("Reparse") {
                                        TokenBarTelemetry.event("diagnostics.source.reparse.click", metadata: "source=\(row.path)", success: true)
                                        Task { await runtimeModel.reparseSource(row.path) }
                                    }
                                    .controlSize(.small)
                                    .disabled(runtimeModel.refreshState == .refreshing)
                                }
                            }
                            .buttonStyle(.plain)
                            if expandedSourceId == row.id {
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
    }

    private var dataAuditCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Token Data Audit")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Indexed raw totals by configured source. Cache share is calculated from stored usage_events.")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    Text("\(runtimeModel.eventCount.formatted()) events")
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
        let matched = Array(
            runtimeModel.events.reversed().lazy
                .filter { $0.sourcePath.hasPrefix(prefix) || $0.sourcePath.contains(path) }
                .prefix(50)
        )
        if matched.isEmpty {
            Text("No indexed events for this source yet.")
                .font(.caption)
                .foregroundStyle(TokenBarStyle.muted)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matched, id: \.id) { event in
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
                                expandedSourceId = (expandedSourceId == row.id) ? nil : row.id
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
                        if expandedSourceId == row.id {
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
        let scenarios = runtimeModel.sourceWarnings.groupedByScenario()
        let errorCount = scenarios.filter { $0.severity == .error }.count
        let warnCount = scenarios.filter { $0.severity == .warning }.count
        return TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Issue Scenarios")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Same kind of issue grouped into one row. Number on the right is occurrences across all files.")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if errorCount > 0 {
                            scenarioBadge(label: "ERROR", count: errorCount, tone: .error)
                        }
                        if warnCount > 0 {
                            scenarioBadge(label: "WARN", count: warnCount, tone: .warning)
                        }
                        if errorCount == 0 && warnCount == 0 {
                            scenarioBadge(label: "", count: 0, tone: .clean)
                        }
                    }
                }

                if scenarios.isEmpty {
                    Text("No source issues from the latest refresh.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(scenarios) { scenario in
                            scenarioRow(scenario)
                                .padding(.vertical, 8)
                                .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.55)), alignment: .bottom)
                        }
                    }
                }
            }
        }
    }

    private enum ScenarioBadgeTone { case error, warning, clean }

    private func scenarioBadge(label: String, count: Int, tone: ScenarioBadgeTone) -> some View {
        let color: Color = {
            switch tone {
            case .error: return TokenBarStyle.error
            case .warning: return TokenBarStyle.warn
            case .clean: return TokenBarStyle.faint
            }
        }()
        let display: String = tone == .clean ? "✓ clean" : "\(label) · \(count)"
        return Text(display)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tone == .clean ? TokenBarStyle.faint : color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                tone == .clean ? TokenBarStyle.surfaceRaised : color.opacity(0.14),
                in: Capsule()
            )
    }

    @ViewBuilder
    private func scenarioRow(_ s: WarningScenario) -> some View {
        let color: Color = s.severity == .error ? TokenBarStyle.error : TokenBarStyle.warn
        let occurrenceText = "\(s.occurrenceCount) event\(s.occurrenceCount == 1 ? "" : "s") affected"
        let fileSummary: String = {
            switch s.affectedPaths.count {
            case 0: return ""
            case 1: return "across 1 file"
            default: return "across \(s.affectedPaths.count) files"
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(s.severity.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                Text(s.sourceName)
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(occurrenceText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            Text(s.kind)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(TokenBarStyle.foreground)
            HStack(spacing: 8) {
                Text(fileSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                if let line = s.firstLineNumber {
                    Text("first @ line \(line)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                Spacer()
            }
            if let firstPath = s.affectedPaths.first {
                Text(firstPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        if !runtimeModel.indexingState.sources.isEmpty {
            return runtimeModel.indexingState.sources.map { source in
                SourceRow(
                    id: "indexing|\(source.sourceName)|\(source.rootPath)",
                    name: source.sourceName,
                    path: source.rootPath,
                    state: sourceRowState(source.phase),
                    events: source.eventsIndexed > 0 ? "\(source.eventsIndexed.formatted()) events" : "\(source.discoveredFileCount.formatted()) files",
                    when: source.phase.rawValue,
                    note: source.message
                )
            }
        }

        if derivedRows.sourceRows.isEmpty, isBuildingDerivedRows {
            return [
                SourceRow(
                    id: "diagnostics-loading",
                    name: "Sources",
                    path: "building source counts",
                    state: .pending,
                    events: "loading",
                    when: "now",
                    note: "counting indexed events off the main thread"
                )
            ]
        }
        return derivedRows.sourceRows
    }

    private func sourceRowState(_ phase: TokenBarIndexingSourcePhase) -> SourceRow.State {
        switch phase {
        case .pending:
            .pending
        case .scanning:
            .pending
        case .indexed:
            .ok
        case .skipped:
            .off
        case .failed:
            .err
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
            events: "\(runtimeModel.eventCount.formatted())",
            prompts: "\(runtimeModel.promptCount.formatted())",
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
        if derivedRows.dataAuditRows.isEmpty, isBuildingDerivedRows {
            return [DataAuditRow(name: "Building audit", summary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0))]
        }
        return derivedRows.dataAuditRows
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

private struct DiagnosticsDerivedRows: Sendable, Hashable {
    let sourceRows: [SourceRow]
    let dataAuditRows: [DataAuditRow]

    static let empty = DiagnosticsDerivedRows(sourceRows: [], dataAuditRows: [])

    static func make(
        events: [UsageEvent],
        customSources: [CustomSourceRecord],
        statuses: [UsageDataSourceStatus],
        lastIndexedAt: Date?
    ) -> DiagnosticsDerivedRows {
        var builtInCounts: [AgentKind: Int] = [:]
        var customCounts: [String: Int] = [:]
        var auditTotals: [String: UsageSummary] = [:]
        var total = UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        let allCustomNamesByID = Dictionary(uniqueKeysWithValues: customSources.map { ($0.id, $0.name) })
        let enabledCustomNamesByID = Dictionary(uniqueKeysWithValues: customSources.filter(\.enabled).map { ($0.id, $0.name) })

        for event in events {
            let customID = customSourceID(from: event.id)
            if let customID, allCustomNamesByID[customID] != nil {
                customCounts[customID, default: 0] += 1
            } else {
                builtInCounts[event.agent, default: 0] += 1
            }

            let auditName = customID.flatMap { enabledCustomNamesByID[$0] } ?? event.agent.displayName
            auditTotals[auditName] = add(event, to: auditTotals[auditName])
            total = add(event, to: total)
        }

        let sourceRows: [SourceRow]
        if statuses.isEmpty {
            let builtInRows = [
                builtInSourceRow(
                    id: "builtin|claude",
                    name: "Claude Code",
                    path: "~/.claude/projects/",
                    count: builtInCounts[.claudeCode, default: 0],
                    lastIndexedAt: lastIndexedAt,
                    note: nil
                ),
                builtInSourceRow(
                    id: "builtin|codex",
                    name: "Codex",
                    path: "~/.codex/sessions/",
                    count: builtInCounts[.codex, default: 0],
                    lastIndexedAt: lastIndexedAt,
                    note: nil
                ),
                builtInSourceRow(
                    id: "builtin|hermes",
                    name: "Hermes",
                    path: "~/.hermes/state.db",
                    count: builtInCounts[.hermes, default: 0],
                    lastIndexedAt: lastIndexedAt,
                    note: "session-level model attribution"
                ),
                builtInSourceRow(
                    id: "builtin|warp",
                    name: "Warp",
                    path: WarpUsageEventSource.discoverDatabasePath() ?? "~/Library/Group Containers/*.dev.warp/.../warp.sqlite",
                    count: builtInCounts[.warp, default: 0],
                    lastIndexedAt: lastIndexedAt,
                    note: "conversation-level total tokens"
                ),
            ]
            sourceRows = builtInRows + customSourceRows(
                customSources: customSources,
                customCounts: customCounts,
                excluding: []
            )
        } else {
            let statusRows = statuses.map { status in
                let count = countForStatus(
                    status,
                    builtInCounts: builtInCounts,
                    customSources: customSources,
                    customCounts: customCounts
                )
                let note: String?
                if !status.isReadable {
                    note = "path unavailable - will retry"
                } else if status.sourceName.localizedCaseInsensitiveContains("Hermes") {
                    note = "session-level model attribution"
                } else {
                    note = nil
                }
                return SourceRow(
                    id: "status|\(status.sourceName)|\(status.rootPath)",
                    name: status.sourceName,
                    path: status.rootPath,
                    state: status.isReadable ? .ok : .err,
                    events: count > 0 ? "\(count.formatted()) events" : "\(status.discoveredFileCount.formatted()) files",
                    when: tokenbarRelativeTime(lastIndexedAt),
                    note: note
                )
            }
            let existingPaths = Set(statuses.map { normalizedPath($0.rootPath) })
            sourceRows = statusRows + customSourceRows(
                customSources: customSources,
                customCounts: customCounts,
                excluding: existingPaths
            )
        }

        let auditRows = auditTotals.map { DataAuditRow(name: $0.key, summary: $0.value) }
            .sorted { $0.summary.totalTokens > $1.summary.totalTokens }

        return DiagnosticsDerivedRows(
            sourceRows: sourceRows,
            dataAuditRows: [DataAuditRow(name: "All sources", summary: total)] + auditRows
        )
    }

    private static func add(_ event: UsageEvent, to summary: UsageSummary?) -> UsageSummary {
        let summary = summary ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        return UsageSummary(
            inputTokens: summary.inputTokens + event.inputTokens,
            outputTokens: summary.outputTokens + event.outputTokens,
            cacheReadTokens: summary.cacheReadTokens + event.cacheReadTokens,
            cacheCreationTokens: summary.cacheCreationTokens + event.cacheCreationTokens
        )
    }

    private static func customSourceID(from eventID: String) -> String? {
        guard eventID.hasPrefix("custom:") else { return nil }
        let remainder = eventID.dropFirst("custom:".count)
        guard let end = remainder.firstIndex(of: ":") else { return nil }
        return String(remainder[..<end])
    }

    private static func builtInSourceRow(
        id: String,
        name: String,
        path: String,
        count: Int,
        lastIndexedAt: Date?,
        note: String?
    ) -> SourceRow {
        SourceRow(
            id: id,
            name: name,
            path: path,
            state: count > 0 ? .ok : .pending,
            events: count > 0 ? "\(count.formatted()) events" : "pending",
            when: count > 0 ? tokenbarRelativeTime(lastIndexedAt) : "after refresh",
            note: note
        )
    }

    private static func customSourceRows(
        customSources: [CustomSourceRecord],
        customCounts: [String: Int],
        excluding existingPaths: Set<String>
    ) -> [SourceRow] {
        customSources.compactMap { source in
            guard !existingPaths.contains(normalizedPath(source.directory)) else { return nil }
            let eventCount = customCounts[source.id, default: 0]
            let state: SourceRow.State = source.enabled ? (eventCount > 0 ? .ok : .pending) : .off
            return SourceRow(
                id: "custom|\(source.id)",
                name: source.name,
                path: source.directory,
                state: state,
                events: eventCount > 0 ? "\(eventCount.formatted()) events" : "pending",
                when: source.enabled ? "waiting for index" : "disabled",
                note: source.enabled ? "\(source.plugin.displayName) · \(source.globPattern)" : "disabled"
            )
        }
    }

    private static func countForStatus(
        _ status: UsageDataSourceStatus,
        builtInCounts: [AgentKind: Int],
        customSources: [CustomSourceRecord],
        customCounts: [String: Int]
    ) -> Int {
        if let custom = customSources.first(where: {
            $0.name == status.sourceName || normalizedPath($0.directory) == normalizedPath(status.rootPath)
        }) {
            return customCounts[custom.id, default: 0]
        }

        let sourceName = status.sourceName.lowercased()
        let rootPath = status.rootPath.lowercased()
        if sourceName.contains("codex") || rootPath.contains(".codex") {
            return builtInCounts[.codex, default: 0]
        }
        if sourceName.contains("claude") || rootPath.contains(".claude") {
            return builtInCounts[.claudeCode, default: 0]
        }
        if sourceName.contains("hermes") || rootPath.contains(".hermes") {
            return builtInCounts[.hermes, default: 0]
        }
        if sourceName.contains("warp") || rootPath.contains("dev.warp") {
            return builtInCounts[.warp, default: 0]
        }
        return 0
    }

    private static func normalizedPath(_ path: String) -> String {
        CodexDataSource.expandHome(in: path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct SourceRow: Identifiable, Sendable, Hashable {
    enum State: Sendable, Hashable {
        case ok
        case pending
        case off
        case err
    }

    let id: String
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

private struct DataAuditRow: Identifiable, Sendable, Hashable {
    var id: String { name }
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
