import AppKit
import SwiftUI
import TokenBarCore

let tokenbarDefaultPricingRows: [PricingRow] = [
    PricingRow(model: "gpt-5.5", input: "2.5", output: "10", cacheRead: "0.25", cacheCreation: "2.5"),
    PricingRow(model: "gpt-5-codex", input: "2.5", output: "10", cacheRead: "0.25", cacheCreation: "2.5"),
    PricingRow(model: "claude-opus-4.7", input: "5", output: "25", cacheRead: "0.5", cacheCreation: "6.25"),
    PricingRow(model: "claude-sonnet-4.5", input: "3", output: "15", cacheRead: "0.3", cacheCreation: "3.75"),
    PricingRow(model: "gpt-5-mini", input: "0.25", output: "2", cacheRead: "0.025", cacheCreation: "0.25"),
    PricingRow(model: "o4-mini", input: "1.1", output: "4.4", cacheRead: "0.275", cacheCreation: "1.1"),
    PricingRow(model: "claude-haiku-4", input: "1", output: "5", cacheRead: "0.1", cacheCreation: "1.25"),
    PricingRow(model: "hermes-3-70b", input: "0.4", output: "0.8", cacheRead: "0.1", cacheCreation: "0.4"),
    PricingRow(model: "composer-1", input: "1.2", output: "6", cacheRead: "0.12", cacheCreation: "1.2"),
]

struct SettingsView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showAddSource = false
    @AppStorage("tokenbar.theme") private var theme = "Dark"
    @State private var editingSource: CustomSourceRecord?
    // CL-P0-017 / CL-P0-018: per-row overrides persisted as JSON in
    // UserDefaults. Reset to Defaults wipes the dict.
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    @State private var editingModel: String?
    @State private var editBuffer = PricingValues()
    @State private var showResetConfirm = false
    @State private var showResetAllConfirm = false  // CL-P1-019
    @State private var resetAck = ""                // CL-P1-019: type "RESET"
    @State private var sourceSaveMessage: String?
    @State private var sourcePendingDelete: CustomSourceRecord?
    private let themeOptions = ["Dark", "Light"]
    private let pricingColumns: [CGFloat] = [180, 86, 86, 86, 86, 78, 108]

    static let defaultPricingRows = tokenbarDefaultPricingRows

    private var pricingRows: [PricingRow] {
        let overrides = decodedOverrides()
        return Self.defaultPricingRows.map { row in
            if let o = overrides[row.model] {
                return PricingRow(model: row.model, input: o.input, output: o.output, cacheRead: o.cacheRead, cacheCreation: o.cacheCreation, source: "override")
            }
            return row
        }
    }

    private func decodedOverrides() -> [String: PricingValues] {
        guard let data = pricingOverridesJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: PricingValues].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveOverride(_ model: String, values: PricingValues) {
        var dict = decodedOverrides()
        dict[model] = values
        if let data = try? JSONEncoder().encode(dict), let str = String(data: data, encoding: .utf8) {
            pricingOverridesJSON = str
            runtimeModel.rebuildPopoverSnapshot(trigger: "pricing-override")
        }
    }

    private func resetAllOverrides() {
        pricingOverridesJSON = "{}"
        runtimeModel.rebuildPopoverSnapshot(trigger: "pricing-reset")
    }

    /// CL-P1-018: NSSavePanel-driven JSON export of the entire local index.
    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "tokenbar-export-\(date).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        struct ExportPayload: Codable {
            let exportedAt: Date
            let summary: Summary
            let customSources: [CustomSource]
            let eventCount: Int
            let promptCount: Int
            struct Summary: Codable {
                let todayTotalTokens: Int
                let last30TotalTokens: Int
                let estimatedCostToday: Double
                let estimatedCostLast30: Double
            }
            struct CustomSource: Codable {
                let id: String
                let name: String
                let engine: CustomSourceEngine
                let directory: String
                let enabled: Bool
                let fieldMapping: CustomSourceFieldMapping
            }
        }

        let payload = ExportPayload(
            exportedAt: Date(),
            summary: .init(
                todayTotalTokens: runtimeModel.snapshot.today.totalTokens,
                last30TotalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                estimatedCostToday: runtimeModel.popoverSnapshot.todayCost,
                estimatedCostLast30: runtimeModel.popoverSnapshot.last30Cost
            ),
            customSources: runtimeModel.customSources.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    engine: $0.engine,
                    directory: $0.directory,
                    enabled: $0.enabled,
                    fieldMapping: $0.fieldMapping
                )
            },
            eventCount: runtimeModel.eventCount,
            promptCount: runtimeModel.promptCount
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url)
        }
    }

    /// CL-P1-019: hard reset — clears pricing overrides, calls runtime to
    /// wipe prompts, and removes custom sources. Built-in sources remain.
    private func resetAll() async {
        pricingOverridesJSON = "{}"
        try? await runtimeModel.wipePrompts()
        for source in runtimeModel.customSources {
            await runtimeModel.removeCustomSource(id: source.id)
        }
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                TokenBarGlassBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        header
                        checkpointSection
                        promptSection
                        themeSection
                        pricingSection
                        retentionSection
                        customSourcesSection
                    }
                    .padding(16)
                }
                .scrollIndicators(.visible)

                if showAddSource {
                    AddCustomSourceOverlay(
                        isPresented: $showAddSource,
                        source: editingSource,
                        onSaved: showSourceSaved
                    )
                    .environmentObject(runtimeModel)
                    .id(editingSource?.id ?? "new")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .zIndex(10)
                }

                if let sourceSaveMessage {
                    Text(sourceSaveMessage)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.foreground)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(TokenBarStyle.cache.opacity(0.18), in: Capsule())
                        .overlay(Capsule().stroke(TokenBarStyle.cache.opacity(0.35), lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(11)
                }
            }
        }
        .onChange(of: showAddSource) { _, newValue in
            if !newValue {
                editingSource = nil
            }
        }
        .onChange(of: theme) { _, newValue in
            TokenBarTelemetry.event("settings.theme.change", metadata: "value=\(newValue)", success: true)
        }
        .alert(
            "Delete Custom Source?",
            isPresented: Binding(
                get: { sourcePendingDelete != nil },
                set: { if !$0 { sourcePendingDelete = nil } }
            ),
            presenting: sourcePendingDelete
        ) { source in
            Button("Cancel", role: .cancel) {
                sourcePendingDelete = nil
            }
            Button("Delete Source", role: .destructive) {
                sourcePendingDelete = nil
                Task { await runtimeModel.removeCustomSource(id: source.id) }
            }
        } message: { source in
            Text("This removes \(source.name) and hides its indexed usage, prompts, and watermarks from TokenBar. Built-in sources are untouched.")
        }
    }

    private func showSourceSaved(_ name: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            sourceSaveMessage = "Source saved: \(name)"
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.16)) {
                    sourceSaveMessage = nil
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Local-first. Nothing ever leaves your machine.")
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
    }

    private var checkpointSection: some View {
        settingsSection(
            title: "Checkpoint Interval",
            subtitle: "How often TokenBar pulls fresh data from sources."
        ) {
            HStack(spacing: 5) {
                ForEach(RefreshIntervalOption.allCases, id: \.self) { option in
                    pill(option.displayName, selected: runtimeModel.refreshInterval == option) {
                        runtimeModel.refreshInterval = option
                    }
                }
            }
        }
    }

    private var promptSection: some View {
        settingsSection(
            title: "Prompt Capture",
            subtitle: "Stores user-only prompts locally. Project history reveals text by default."
        ) {
            HStack(spacing: 5) {
                pill("Off", selected: !runtimeModel.storePromptTextInClearText) {
                    runtimeModel.storePromptTextInClearText = false
                }
                pill("Full", selected: runtimeModel.storePromptTextInClearText) {
                    runtimeModel.storePromptTextInClearText = true
                }
            }
        }
    }

    private var themeSection: some View {
        settingsSection(
            title: "Theme",
            subtitle: "Dark is the default — switch to Light for daylight reading."
        ) {
            ThemeChoiceGrid(selection: $theme, options: themeOptions)
        }
    }

    private var pricingSection: some View {
        settingsSection(
            title: "Pricing",
            subtitle: "USD per 1,000,000 tokens. Used to estimate cost across the app."
        ) {
            VStack(spacing: 0) {
                Grid(horizontalSpacing: 14, verticalSpacing: 0) {
                    GridRow {
                        priceHead("Model", width: pricingColumns[0])
                        priceHead("Input $/1M", width: pricingColumns[1])
                        priceHead("Output $/1M", width: pricingColumns[2])
                        priceHead("CacheRead $/1M", width: pricingColumns[3])
                        priceHead("CacheCreate $/1M", width: pricingColumns[4])
                        priceHead("Source", width: pricingColumns[5])
                        priceHead("Actions", width: pricingColumns[6], align: .trailing)
                    }
                    Divider().gridCellColumns(7).overlay(TokenBarStyle.line)
                    ForEach(pricingRows) { row in
                        pricingGridRow(row)
                        Divider().gridCellColumns(7).overlay(TokenBarStyle.line.opacity(0.6))
                    }
                }
            }
        } trailing: {
            // CL-P0-018: Reset is disabled when there are no overrides.
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SettingsButtonStyle(kind: .normal))
            .disabled(decodedOverrides().isEmpty)
            .confirmationDialog("Reset all pricing overrides to defaults?",
                                isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) { resetAllOverrides() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This affects \(decodedOverrides().count) row(s). Cost estimates will recompute immediately.")
            }
        }
    }

    @ViewBuilder
    private func pricingGridRow(_ row: PricingRow) -> some View {
        if editingModel == row.model {
            GridRow {
                Text(row.model)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: pricingColumns[0], alignment: .leading)
                priceField($editBuffer.input, width: pricingColumns[1])
                priceField($editBuffer.output, width: pricingColumns[2])
                priceField($editBuffer.cacheRead, width: pricingColumns[3])
                priceField($editBuffer.cacheCreation, width: pricingColumns[4])
                Text(row.source == "default" ? "default" : "override")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.accent)
                    .frame(width: pricingColumns[5], alignment: .leading)
                HStack(spacing: 4) {
                    Button("Save") {
                        saveOverride(row.model, values: editBuffer.normalized)
                        editingModel = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editBuffer.isValid)
                    Button("Cancel") { editingModel = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(width: pricingColumns[6], alignment: .trailing)
                .controlSize(.small)
            }
            .padding(.vertical, 9)
        } else {
            GridRow {
                Text(row.model)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: pricingColumns[0], alignment: .leading)
                priceCell(row.input, width: pricingColumns[1])
                priceCell(row.output, width: pricingColumns[2])
                priceCell(row.cacheRead, width: pricingColumns[3])
                priceCell(row.cacheCreation, width: pricingColumns[4])
                Text(row.source)
                    .font(.caption)
                    .foregroundStyle(row.source == "override" ? TokenBarStyle.warn : TokenBarStyle.cache)
                    .frame(width: pricingColumns[5], alignment: .leading)
                Button("Edit") {
                    editBuffer = PricingValues(input: row.input, output: row.output, cacheRead: row.cacheRead, cacheCreation: row.cacheCreation)
                    editingModel = row.model
                }
                .controlSize(.small)
                .frame(width: pricingColumns[6], alignment: .trailing)
            }
            .padding(.vertical, 9)
        }
    }

    private func priceField(_ binding: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .frame(width: width)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        binding.wrappedValue.trimmedPrice.isValidPrice ? Color.clear : TokenBarStyle.error,
                        lineWidth: 1.5
                    )
            )
    }

    private var customSourcesSection: some View {
        settingsSection(
            title: "Custom Sources",
            subtitle: "Point TokenBar at any agent that writes JSONL or sqlite locally."
        ) {
            if runtimeModel.indexingState.isVisible {
                SettingsIndexingProgressStrip(state: runtimeModel.indexingState)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                customSourceTile(name: "Codex", path: "~/.codex/sessions", color: TokenBarStyle.agentColor("Codex"), enabled: true)
                customSourceTile(name: "Claude Code", path: "~/.claude/projects", color: TokenBarStyle.agentColor("Claude Code"), enabled: true)
                customSourceTile(name: "Hermes", path: "~/.hermes/state.db", color: TokenBarStyle.agentColor("Hermes"), enabled: true)
                customSourceTile(name: "Gemini CLI", path: "~/.gemini/tmp/**/chats/*.json", color: TokenBarStyle.agentColor("Gemini CLI"), enabled: true)
                customSourceTile(name: "OpenClaw", path: "~/.openclaw/agents/**/sessions/*.jsonl", color: TokenBarStyle.agentColor("OpenClaw"), enabled: true)
                customSourceTile(name: "OpenCode", path: "~/.local/share/opencode/opencode.db", color: TokenBarStyle.agentColor("OpenCode"), enabled: true)
                customSourceTile(name: "Warp", path: "~/Library/Group Containers/*.dev.warp/.../warp.sqlite", color: TokenBarStyle.agentColor("Warp"), enabled: true)
                ForEach(runtimeModel.customSources) { source in
                    editableCustomSourceTile(source: source)
                }
            }
        } trailing: {
            Button {
                TokenBarTelemetry.event("settings.custom_source.add.open", success: true)
                editingSource = nil
                showAddSource = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(SettingsButtonStyle(kind: .primary))
        }
    }

    private var retentionSection: some View {
        settingsSection(
            title: "Data & Retention",
            subtitle: "Aggregates are kept forever; sessions roll off based on retention."
        ) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Retention")
                        .sectionLabel()
                    HStack(spacing: 5) {
                        ForEach(["30d", "90d", "365d", "Forever"], id: \.self) { value in
                            pill(value, selected: runtimeModel.retentionWindow == value) {
                                runtimeModel.retentionWindow = value
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("DB Size")
                        .sectionLabel()
                    Text(databaseSizeLabel)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenBarStyle.foreground)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Oldest Record")
                        .sectionLabel()
                    Text(oldestRecordLabel)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.foreground)
                        .lineLimit(1)
                    Text(UsageDatabase.defaultDatabaseURL().path(percentEncoded: false))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }

                Spacer()

                // CL-P1-018: real export — events + summary + customSources
                // serialized as JSON via NSSavePanel.
                Button("Export JSON…") { exportJSON() }
                    .buttonStyle(SettingsButtonStyle())
                // CL-P1-019: full Reset All with two-stage confirm.
                Button(role: .destructive) { showResetAllConfirm = true } label: {
                    Text("Reset All…")
                }
                .buttonStyle(SettingsButtonStyle(kind: .danger))
                .alert("Reset all TokenBar data?",
                       isPresented: $showResetAllConfirm) {
                    TextField("Type RESET to confirm", text: $resetAck)
                    Button("Cancel", role: .cancel) { resetAck = "" }
                    Button("Reset", role: .destructive) {
                        guard resetAck == "RESET" else { return }
                        Task { await resetAll() }
                        resetAck = ""
                    }
                    .disabled(resetAck != "RESET")
                } message: {
                    Text("This wipes all events, prompts, custom sources, and pricing overrides. Type RESET to confirm.")
                }
            }
        }
    }

    private func settingsSection<Content: View, Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(TokenBarStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    trailing()
                }
                content()
            }
        }
    }

    private var databaseSizeLabel: String {
        let url = UsageDatabase.defaultDatabaseURL()
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let bytes = attributes[.size] as? NSNumber
        else {
            return "0 MB"
        }
        let mb = bytes.doubleValue / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    private var oldestRecordLabel: String {
        guard let oldest = runtimeModel.events.first?.timestamp else {
            return "no records"
        }
        return tokenbarRelativeTime(oldest)
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsSection(title: title, subtitle: subtitle, content: content) {
            EmptyView()
        }
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? TokenBarStyle.foreground : TokenBarStyle.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selected ? TokenBarStyle.accent.opacity(0.22) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .background(TokenBarStyle.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
    }

    /// CL-P1-017: editable variant of `customSourceTile` for user-added
    /// sources. Built-in tiles still use the static read-only flavor.
    private func editableCustomSourceTile(source: CustomSourceRecord) -> some View {
        HStack(spacing: 13) {
            Circle()
                .fill(source.enabled ? TokenBarStyle.accent : TokenBarStyle.faint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(source.engine.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(TokenBarStyle.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TokenBarStyle.surface.opacity(0.7), in: Capsule())
                }
                Text(source.globPattern.isEmpty || source.globPattern == "**/*.jsonl"
                     ? source.directory
                     : "\(source.directory)/\(source.globPattern)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted).lineLimit(1)
            }
            Spacer()
            Button {
                TokenBarTelemetry.event("settings.custom_source.edit.open", metadata: "name=\(source.name)", success: true)
                editingSource = source
                showAddSource = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit this source")
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in
                    TokenBarTelemetry.event("settings.custom_source.toggle.click", metadata: "name=\(source.name)", success: true)
                    Task { await runtimeModel.toggleCustomSource(source) }
                }
            ))
            .labelsHidden()
            .controlSize(.small)
            .help(source.enabled ? "Disable this source" : "Enable this source")
            Button(role: .destructive) {
                TokenBarTelemetry.event("settings.custom_source.remove.click", metadata: "name=\(source.name)", success: true)
                sourcePendingDelete = source
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this source")
        }
        .padding(13)
        .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func customSourceTile(name: String, path: String, color: Color, enabled: Bool) -> some View {
        HStack(spacing: 13) {
            Circle()
                .fill(enabled ? color : TokenBarStyle.faint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text("Built-In")
                .font(.caption2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(TokenBarStyle.faint)
                .background(TokenBarStyle.surface.opacity(0.5), in: Capsule())
        }
        .padding(13)
        .background(TokenBarStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func priceHead(_ text: String, width: CGFloat, align: Alignment = .leading) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TokenBarStyle.faint)
            .frame(width: width, alignment: align)
    }

    private func priceCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .monospaced))
            .monospacedDigit()
            .frame(width: width, alignment: .leading)
    }

}

private struct SettingsIndexingProgressStrip: View {
    let state: TokenBarIndexingState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ProgressView(value: state.progress)
                .progressViewStyle(.linear)
                .tint(TokenBarStyle.accent)
                .frame(width: 118)

            Text("\(Int((state.progress * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenBarStyle.faint)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(TokenBarStyle.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(TokenBarStyle.line.opacity(0.85), lineWidth: 1))
    }

    private var title: String {
        switch state.phase {
        case .completed:
            return "Index ready"
        case .failed:
            return "Index needs attention"
        case .paused:
            return "Indexing paused"
        default:
            return state.activeSourceName.map { "Indexing \($0)" } ?? "Indexing sources"
        }
    }

    private var summary: String {
        var parts = [
            "\(state.checkedFiles.formatted()) files",
            "\(state.eventsIndexed.formatted()) events",
        ]
        if let cpuBudgetPercent = state.cpuBudgetPercent {
            parts.append("~\(formatCPU(cpuBudgetPercent)) CPU")
        }
        if let message = state.message {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch state.phase {
        case .completed:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .paused:
            "pause.circle"
        default:
            "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch state.phase {
        case .completed:
            TokenBarStyle.cache
        case .failed:
            TokenBarStyle.error
        case .paused:
            TokenBarStyle.warn
        default:
            TokenBarStyle.accent
        }
    }

    private func formatCPU(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }
}

private struct ThemeChoiceGrid: View {
    @Binding var selection: String
    let options: [String]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(options, id: \.self) { option in
                ThemeChoiceTile(option: option, selected: selection == option) {
                    selection = option
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemeChoiceTile: View {
    let option: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ThemePreview(option: option)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 26, height: 26)
                                .background(TokenBarStyle.accent, in: Circle())
                                .padding(10)
                        }
                    }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenBarStyle.foreground)
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                            .lineLimit(1)
                    }
                    Spacer()
                    Circle()
                        .stroke(selected ? TokenBarStyle.accent : TokenBarStyle.line, lineWidth: selected ? 2 : 1.5)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selected {
                                Circle()
                                    .fill(TokenBarStyle.accent)
                                    .frame(width: 8, height: 8)
                            }
                        }
                }
            }
            .padding(10)
            .background(TokenBarStyle.surfaceRaised.opacity(selected ? 0.92 : 0.58),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? TokenBarStyle.accent.opacity(0.70) : TokenBarStyle.line, lineWidth: selected ? 1.6 : 1)
            )
            .shadow(color: selected ? TokenBarStyle.accent.opacity(0.14) : Color.clear, radius: 10)
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        switch option {
        case "Light":
            "paper · for daylight"
        default:
            "ink · the canonical look"
        }
    }
}

private struct ThemePreview: View {
    let option: String

    var body: some View {
        preview(mode: option == "Light" ? .light : .dark)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(TokenBarStyle.line.opacity(0.8), lineWidth: 1))
    }

    private enum Mode {
        case light
        case dark
    }

    private func preview(mode: Mode) -> some View {
        let isLight = mode == .light
        let background = isLight ? Color(red: 0.96, green: 0.97, blue: 0.98) : Color(red: 0.05, green: 0.10, blue: 0.12)
        let panel = isLight ? Color.white : Color(red: 0.07, green: 0.13, blue: 0.16)
        let line = isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.10)
        let muted = isLight ? Color.black.opacity(0.16) : Color.white.opacity(0.14)

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TokenBarBrandGlyph(size: 18)
                    .padding(.bottom, 6)
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index == 0 ? Color.black.opacity(isLight ? 0.28 : 0.30) : muted)
                        .frame(width: index == 0 ? 64 : 48, height: 5)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 58)
            .background(isLight ? Color.white : Color(red: 0.035, green: 0.075, blue: 0.09))
            .overlay(Rectangle().fill(line).frame(width: 1), alignment: .trailing)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isLight ? Color.black.opacity(0.68) : Color.white.opacity(0.70))
                    .frame(width: 86, height: 7)
                HStack(spacing: 5) {
                    previewMetric(color: TokenBarStyle.accent, panel: panel, line: line)
                    previewMetric(color: TokenBarStyle.output, panel: panel, line: line)
                    previewMetric(color: TokenBarStyle.cache, panel: panel, line: line)
                }
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(panel)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(line, lineWidth: 1))
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(0..<15, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(index == 9 ? TokenBarStyle.accent : muted.opacity(1.8))
                                .frame(maxWidth: .infinity)
                                .frame(height: previewBarHeight(index))
                        }
                    }
                    .padding(8)
                }
            }
            .padding(8)
            .background(background)
        }
    }

    private func previewMetric(color: Color, panel: Color, line: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(panel)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(line, lineWidth: 1))
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 44, height: 4)
            }
            .frame(height: 24)
    }

    private func previewBarHeight(_ index: Int) -> CGFloat {
        let heights: [CGFloat] = [24, 34, 18, 48, 29, 62, 40, 52, 25, 74, 36, 31, 22, 54, 34]
        return heights[index % heights.count]
    }
}

private struct AddCustomSourceOverlay: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Binding var isPresented: Bool
    let source: CustomSourceRecord?
    let onSaved: (String) -> Void
    @State private var name = ""
    @State private var displayAgent = ""
    @State private var pathGlob = ""
    @State private var engine: CustomSourceEngine = .claudeCode
    @State private var format: CustomSourceFormat = .auto
    @State private var mappingOpen = false
    @State private var inputField = "usage.input_tokens"
    @State private var outputField = "usage.output_tokens"
    @State private var cacheField = "usage.cache_read_tokens"
    @State private var modelField = "model"
    @State private var detectionState: SourceDetectionState = .idle
    @State private var isSaving = false
    @State private var saveError: String?
    nonisolated private static let detectionSampleLimit = 100

    init(
        isPresented: Binding<Bool>,
        source: CustomSourceRecord? = nil,
        onSaved: @escaping (String) -> Void = { _ in }
    ) {
        _isPresented = isPresented
        self.source = source
        self.onSaved = onSaved
        if let source {
            _name = State(initialValue: source.name)
            let initialPath = (source.globPattern.isEmpty || source.globPattern == "**/*.jsonl")
            ? source.directory
            : "\(source.directory)/\(source.globPattern)"
            _pathGlob = State(initialValue: initialPath.replacingOccurrences(of: "//", with: "/"))
            _displayAgent = State(initialValue: source.displayAgent)
            _engine = State(initialValue: source.engine)
            _format = State(initialValue: source.format)
            _mappingOpen = State(initialValue: source.fieldMapping != .default)
            _inputField = State(initialValue: source.fieldMapping.inputTokens)
            _outputField = State(initialValue: source.fieldMapping.outputTokens)
            _cacheField = State(initialValue: source.fieldMapping.cacheReadTokens)
            _modelField = State(initialValue: source.fieldMapping.model)
            _detectionState = State(initialValue: .success("Saved source. Run Detect again after changing the path or mapping."))
        } else {
            _name = State(initialValue: "")
            _displayAgent = State(initialValue: "")
            _pathGlob = State(initialValue: "")
            _engine = State(initialValue: .claudeCode)
            _format = State(initialValue: .auto)
            _mappingOpen = State(initialValue: false)
            _inputField = State(initialValue: CustomSourceFieldMapping.default.inputTokens)
            _outputField = State(initialValue: CustomSourceFieldMapping.default.outputTokens)
            _cacheField = State(initialValue: CustomSourceFieldMapping.default.cacheReadTokens)
            _modelField = State(initialValue: CustomSourceFieldMapping.default.model)
            _detectionState = State(initialValue: .idle)
        }
    }

    var body: some View {
        ZStack(alignment: .center) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            TokenBarCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source == nil ? "Add Custom Source" : "Edit Custom Source")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text("Point TokenBar at an agent log. Detect validates the path and schema before the source can be saved.")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TokenBarStyle.muted)
                    }
                    .padding(18)

                    Divider().overlay(TokenBarStyle.line)

                    VStack(alignment: .leading, spacing: 14) {
                        field("Name", text: $name, prompt: "e.g. Hermes Runs")
                        enginePicker
                        field("Path or glob", text: $pathGlob, prompt: pathPrompt, trailing: {
                            HStack(spacing: 7) {
                                Button("Browse...") {
                                    browsePath()
                                }
                                .buttonStyle(SettingsButtonStyle())
                                Button {
                                    detectSource()
                                } label: {
                                    if detectionState == .detecting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 48)
                                    } else {
                                        Text("Detect")
                                            .frame(width: 48)
                                    }
                                }
                                .buttonStyle(SettingsButtonStyle(kind: .primary))
                                .disabled(pathGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detectionState == .detecting)
                            }
                        })

                        detectionBlock
                        if let saveError {
                            Text(saveError)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(TokenBarStyle.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)

                    Divider().overlay(TokenBarStyle.line)

                    HStack {
                        Text("~/.tokenbar/sources.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                        Spacer()
                        Button("Cancel") { isPresented = false }
                            .buttonStyle(SettingsButtonStyle())
                        Button {
                            addSource()
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 78)
                            } else {
                                Text(source == nil ? "Add Source" : "Save Source")
                                    .frame(width: 78)
                            }
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .primary))
                        .disabled(!canSave || isSaving)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .shadow(color: TokenBarStyle.appBackground.opacity(0.22), radius: 22, x: 0, y: 14)
        }
        .onChange(of: pathGlob) { _, _ in resetDetectionAfterEdit() }
        .onChange(of: engine) { _, _ in resetDetectionAfterEdit() }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Engine")
                .sectionLabel()
            HStack(spacing: 8) {
                ForEach(CustomSourceEngine.allCases, id: \.self) { option in
                    Button {
                        engine = option
                    } label: {
                        Text(option.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(engine == option ? TokenBarStyle.input.opacity(0.20) : TokenBarStyle.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(engine == option ? TokenBarStyle.input.opacity(0.42) : TokenBarStyle.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(engine == option ? TokenBarStyle.foreground : TokenBarStyle.muted)
                }
            }
        }
    }

    private var pathPrompt: String {
        switch engine {
        case .claudeCode:
            "~/.claude/projects or **/*.jsonl"
        case .codex:
            "~/.codex/sessions or **/rollout-*.jsonl"
        case .hermes:
            "~/.hermes/state.db or ~/.hermes"
        case .gemini:
            "~/.gemini/tmp or **/chats/*.json"
        case .openCode:
            "~/.local/share/opencode/opencode.db or ~/.local/share/opencode"
        case .openclaw:
            "~/.openclaw/agents or **/sessions/*.jsonl"
        }
    }

    private var detectionBlock: some View {
        let style = detectionStyle
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.color)
                .frame(width: 18, height: 18)
                .background(style.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(style.title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(style.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(style.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(style.color.opacity(0.18), lineWidth: 1))
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !pathGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return detectionState.isSuccess
    }

    private var detectionStyle: (icon: String, color: Color, title: String, detail: String) {
        switch detectionState {
        case .idle:
            return (
                "scope",
                TokenBarStyle.faint,
                "Detection required",
                "Fill the source details, then run Detect to validate files and field mapping."
            )
        case .detecting:
            return (
                "ellipsis",
                TokenBarStyle.input,
                "Checking source",
                "Scanning the path with the selected engine."
            )
        case .success(let message):
            return (
                "checkmark",
                TokenBarStyle.cache,
                "Detection passed",
                message
            )
        case .failure(let message):
            return (
                "exclamationmark",
                TokenBarStyle.error,
                "Detection failed",
                message
            )
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String = "") -> some View {
        field(label, text: text, prompt: prompt) { EmptyView() }
    }

    private func field<Trailing: View>(
        _ label: String,
        text: Binding<String>,
        prompt: String = "",
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .sectionLabel()
            HStack(spacing: 8) {
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(TokenBarStyle.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                trailing()
            }
        }
    }

    private func resetDetectionAfterEdit() {
        if detectionState.isSuccess || detectionState.isFailure {
            detectionState = .idle
        }
        saveError = nil
    }

    private func detectSource() {
        let started = Date()
        let rawPath = pathGlob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            detectionState = .failure("Path is required.")
            TokenBarTelemetry.event(
                "custom_source.detect",
                metadata: "path=empty",
                success: false,
                elapsed: Date().timeIntervalSince(started),
                error: "Path is required."
            )
            return
        }
        detectionState = .detecting
        let mapping = normalizedFieldMapping()
        let selectedEngine = engine
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.detect(rawPathGlob: rawPath, engine: selectedEngine, fieldMapping: mapping)
            }.value
            await MainActor.run {
                switch result {
                case .success(let format, let message):
                    self.format = format
                    self.detectionState = .success(message)
                    TokenBarTelemetry.event(
                        "custom_source.detect",
                        metadata: "path=\(rawPath) engine=\(selectedEngine.rawValue) format=\(format.displayName)",
                        success: true,
                        elapsed: Date().timeIntervalSince(started)
                    )
                case .failure(let message):
                    self.detectionState = .failure(message)
                    TokenBarTelemetry.event(
                        "custom_source.detect",
                        metadata: "path=\(rawPath)",
                        success: false,
                        elapsed: Date().timeIntervalSince(started),
                        error: message
                    )
                }
            }
        }
    }

    private func addSource() {
        let started = Date()
        guard !isSaving else {
            TokenBarTelemetry.event(
                "custom_source.save.skip",
                metadata: "reason=already_saving name=\(name)",
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return
        }
        guard canSave else {
            TokenBarTelemetry.event(
                "custom_source.save",
                metadata: "name=\(name)",
                success: false,
                elapsed: Date().timeIntervalSince(started),
                error: "Detection has not passed."
            )
            return
        }
        isSaving = true
        saveError = nil
        let split = splitPathGlob(pathGlob, defaultGlob: engine.defaultGlobPattern)
        Task {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? "Custom Source" : trimmedName
            let fieldMapping = normalizedFieldMapping()
            let result: CustomSourceSaveResult
            if let source {
                result = await runtimeModel.updateCustomSource(
                    source,
                    name: finalName,
                    engine: engine,
                    directory: split.directory,
                    globPattern: split.glob,
                    format: format,
                    displayAgent: engine.displayName,
                    fieldMapping: fieldMapping
                )
            } else {
                result = await runtimeModel.addCustomSource(
                    name: finalName,
                    engine: engine,
                    directory: split.directory,
                    globPattern: split.glob,
                    format: format,
                    displayAgent: engine.displayName,
                    fieldMapping: fieldMapping
                )
            }
            await MainActor.run {
                isSaving = false
                switch result {
                case .saved(let savedName, let deduplicated):
                    TokenBarTelemetry.event(
                        "custom_source.save",
                        metadata: "name=\(savedName) mode=\(source == nil ? "add" : "edit") deduplicated=\(deduplicated)",
                        success: true,
                        elapsed: Date().timeIntervalSince(started)
                    )
                    onSaved(savedName)
                    isPresented = false
                case .failed(let message):
                    saveError = "Could not save source: \(message)"
                    TokenBarTelemetry.event(
                        "custom_source.save",
                        metadata: "name=\(finalName) mode=\(source == nil ? "add" : "edit")",
                        success: false,
                        elapsed: Date().timeIntervalSince(started),
                        error: message
                    )
                }
            }
        }
    }

    private func normalizedFieldMapping() -> CustomSourceFieldMapping {
        let defaults = CustomSourceFieldMapping.default
        return CustomSourceFieldMapping(
            inputTokens: inputField.nonEmptyMapping(defaults.inputTokens),
            outputTokens: outputField.nonEmptyMapping(defaults.outputTokens),
            cacheReadTokens: cacheField.nonEmptyMapping(defaults.cacheReadTokens),
            cacheCreationTokens: defaults.cacheCreationTokens,
            model: modelField.nonEmptyMapping(defaults.model)
        )
    }

    private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Path"
        if panel.runModal() == .OK, let url = panel.url {
            pathGlob = url.path(percentEncoded: false)
        }
    }

    private func splitPathGlob(_ raw: String, defaultGlob: String) -> (directory: String, glob: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("*") else {
            let expanded = CodexDataSource.expandHome(in: trimmed)
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return Self.splitConcreteFilePath(trimmed)
            }
            return (trimmed, defaultGlob)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let firstWildcard = parts.firstIndex(where: { $0.contains("*") }) else {
            return (trimmed, defaultGlob)
        }
        let dir = parts[..<firstWildcard].joined(separator: "/")
        let glob = parts[firstWildcard...].joined(separator: "/")
        return (dir.isEmpty ? "." : dir, glob.isEmpty ? defaultGlob : glob)
    }

    nonisolated private static func detect(
        rawPathGlob: String,
        engine: CustomSourceEngine,
        fieldMapping: CustomSourceFieldMapping
    ) -> SourceDetectionResult {
        let split = splitPathGlob(rawPathGlob, defaultGlob: engine.defaultGlobPattern)
        let files = discoverFiles(directory: split.directory, globPattern: split.glob, engine: engine)
        guard let sample = files.first else {
            return .failure("No readable files matched this path. Use ~/ for home directories, or browse to the folder.")
        }

        if engine == .hermes {
            do {
                _ = try HermesUsageParser.parse(databaseURL: sample)
                return .success(.auto, "Hermes state database · \(files.count) database(s) matched.")
            } catch {
                return .failure("Hermes database could not be read: \(error.localizedDescription)")
            }
        }

        let samples = Array(files.prefix(detectionSampleLimit))
        for sample in samples {
            let detected = SourceFormatDetector.detect(fileURL: sample)
            if engine == .claudeCode, detected == .claudeCodeJSONL {
                return .success(detected, "\(engine.displayName) JSONL · \(files.count) file(s) matched.")
            }
            if engine == .codex, detected == .codexJSONL {
                return .success(detected, "\(engine.displayName) rollout JSONL · \(files.count) file(s) matched.")
            }
        }

        if samples.contains(where: { mappedJSONLooksValid(fileURL: $0, mapping: fieldMapping) }) {
            return .failure("The sample is mapped JSONL, but only Claude Code, Codex, and Hermes engines are supported here.")
        }
        return .failure("Selected \(engine.displayName) engine did not match any of \(samples.count) sampled file(s).")
    }

    nonisolated private static func discoverFiles(directory: String, globPattern: String, engine: CustomSourceEngine) -> [URL] {
        let expanded = CodexDataSource.expandHome(in: directory)
        let root = URL(fileURLWithPath: expanded, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return []
        }
        if engine == .hermes {
            if !isDirectory.boolValue {
                return FileManager.default.isReadableFile(atPath: root.path(percentEncoded: false)) ? [root] : []
            }
            let stateDB = root.appendingPathComponent("state.db")
            return FileManager.default.isReadableFile(atPath: stateDB.path(percentEncoded: false)) ? [stateDB] : []
        }

        let recursive = globPattern.contains("**")
        let suffix = globPattern.split(separator: "*").last.map(String.init) ?? ".jsonl"
        let matcher: (URL) -> Bool = { url in
            let name = url.lastPathComponent
            if globPattern.contains("rollout-*.jsonl") {
                return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
            }
            if globPattern.contains("*.jsonl") || globPattern.contains("**") {
                return name.hasSuffix(".jsonl")
            }
            return name == globPattern || name.hasSuffix(suffix)
        }
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL else { return nil }
                guard matcher(url) else { return nil }
                return url
            }
            .sorted { $0.path < $1.path }
            .prefix(detectionSampleLimit)
            .map { $0 }
        }

        return ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { matcher($0) }
        .sorted { $0.path < $1.path }
        .prefix(detectionSampleLimit)
        .map { $0 }
    }

    nonisolated private static func mappedJSONLooksValid(fileURL: URL, mapping: CustomSourceFieldMapping) -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }
        for line in text.split(whereSeparator: \.isNewline).prefix(40) {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            if mappedIntValue(from: object, path: mapping.inputTokens) != nil,
               mappedIntValue(from: object, path: mapping.outputTokens) != nil,
               mappedIntValue(from: object, path: mapping.cacheReadTokens) != nil {
                return true
            }
        }
        return false
    }

    nonisolated private static func mappedIntValue(from object: [String: Any], path: String) -> Int? {
        let value = mappedValue(from: object, path: path)
        switch value {
        case let intValue as Int:
            return intValue
        case let intValue as Int64:
            return Int(intValue)
        case let doubleValue as Double:
            return Int(doubleValue)
        case let num as NSNumber:
            return num.intValue
        case let stringValue as String:
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    nonisolated private static func mappedValue(from object: [String: Any], path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var current: Any = object
        for part in parts {
            if let index = Int(part), let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
                continue
            }
            guard let dictionary = current as? [String: Any], let next = dictionary[part] else {
                return nil
            }
            current = next
        }
        return current
    }

    nonisolated private static func splitPathGlob(_ raw: String, defaultGlob: String) -> (directory: String, glob: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("*") else {
            let expanded = CodexDataSource.expandHome(in: trimmed)
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return splitConcreteFilePath(trimmed)
            }
            return (trimmed, defaultGlob)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let firstWildcard = parts.firstIndex(where: { $0.contains("*") }) else {
            return (trimmed, defaultGlob)
        }
        let dir = parts[..<firstWildcard].joined(separator: "/")
        let glob = parts[firstWildcard...].joined(separator: "/")
        return (dir.isEmpty ? "." : dir, glob.isEmpty ? defaultGlob : glob)
    }

    nonisolated private static func splitConcreteFilePath(_ raw: String) -> (directory: String, glob: String) {
        guard let slash = raw.lastIndex(of: "/") else {
            return (".", raw)
        }
        let directory = String(raw[..<slash])
        let fileName = String(raw[raw.index(after: slash)...])
        return (directory.isEmpty ? "/" : directory, fileName.isEmpty ? "**/*.jsonl" : fileName)
    }

    private enum SourceDetectionState: Equatable {
        case idle
        case detecting
        case success(String)
        case failure(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    private enum SourceDetectionResult: Sendable {
        case success(CustomSourceFormat, String)
        case failure(String)
    }
}

struct PricingRow: Identifiable {
    var id: String { model }
    let model: String
    let input: String
    let output: String
    let cacheRead: String
    let cacheCreation: String
    var source: String = "default"
}

struct PricingValues: Codable, Hashable {
    var input: String = "0"
    var output: String = "0"
    var cacheRead: String = "0"
    var cacheCreation: String = "0"

    var isValid: Bool {
        input.isValidPrice && output.isValidPrice && cacheRead.isValidPrice && cacheCreation.isValidPrice
    }

    var normalized: PricingValues {
        .init(
            input: input.trimmedPrice,
            output: output.trimmedPrice,
            cacheRead: cacheRead.trimmedPrice,
            cacheCreation: cacheCreation.trimmedPrice
        )
    }

    /// Backward-compat: when decoding old 3-field JSON (which has `cache` but
    /// not `cacheRead`/`cacheCreation`), map the legacy field gracefully.
    enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheCreation
        // Legacy key for old persisted overrides
        case cache
    }

    init(input: String = "0", output: String = "0", cacheRead: String = "0", cacheCreation: String = "0") {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(String.self, forKey: .input) ?? "0"
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? "0"
        if let cr = try container.decodeIfPresent(String.self, forKey: .cacheRead) {
            cacheRead = cr
            cacheCreation = try container.decodeIfPresent(String.self, forKey: .cacheCreation) ?? input
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .cache) {
            // Old format: single `cache` field becomes cacheRead; cacheCreation defaults to input rate
            cacheRead = legacy
            cacheCreation = try container.decodeIfPresent(String.self, forKey: .cacheCreation) ?? input
        } else {
            cacheRead = "0"
            cacheCreation = input
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(cacheRead, forKey: .cacheRead)
        try container.encode(cacheCreation, forKey: .cacheCreation)
    }
}

extension String {
    var isValidPrice: Bool {
        guard let v = Double(trimmedPrice) else { return false }
        return v >= 0
    }

    var trimmedPrice: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nonEmptyMapping(_ fallback: String) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case primary
        case danger
    }

    enum Size {
        case regular
        case small
    }

    var kind: Kind = .normal
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 11 : 12.5, weight: .medium))
            .padding(.horizontal, size == .small ? 9 : 13)
            .frame(height: size == .small ? 24 : 30)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous).stroke(stroke, lineWidth: 1))
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.75 : 1))
    }

    private var foreground: Color {
        guard isEnabled else { return TokenBarStyle.faint }
        switch kind {
        case .normal:
            return TokenBarStyle.foreground
        case .primary:
            return .white
        case .danger:
            return TokenBarStyle.error
        }
    }

    private var background: Color {
        guard isEnabled else { return TokenBarStyle.surfaceRaised.opacity(0.55) }
        switch kind {
        case .normal:
            return TokenBarStyle.surfaceRaised
        case .primary:
            return TokenBarStyle.accent
        case .danger:
            return TokenBarStyle.error.opacity(0.08)
        }
    }

    private var stroke: Color {
        guard isEnabled else { return TokenBarStyle.line.opacity(0.55) }
        switch kind {
        case .normal:
            return TokenBarStyle.line
        case .primary:
            return TokenBarStyle.accent.opacity(0.35)
        case .danger:
            return TokenBarStyle.error.opacity(0.30)
        }
    }
}

private extension Text {
    func sectionLabel() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(TokenBarStyle.faint)
            .textCase(.uppercase)
    }
}
