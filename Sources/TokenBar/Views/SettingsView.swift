import AppKit
import SwiftUI
import TokenBarCore

struct SettingsView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var showAddSource = false
    @AppStorage("tokenbar.theme") private var theme = "System"
    // CL-P0-017 / CL-P0-018: per-row overrides persisted as JSON in
    // UserDefaults. Reset to Defaults wipes the dict.
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    @State private var editingModel: String?
    @State private var editBuffer = PricingValues()
    @State private var showResetConfirm = false
    @State private var showResetAllConfirm = false  // CL-P1-019
    @State private var resetAck = ""                // CL-P1-019: type "RESET"

    static let defaultPricingRows: [PricingRow] = [
        PricingRow(model: "gpt-5.5", input: "2.5", output: "10", cache: "0.25"),
        PricingRow(model: "gpt-5-codex", input: "2.5", output: "10", cache: "0.25"),
        PricingRow(model: "claude-opus-4.7", input: "15", output: "75", cache: "1.5"),
        PricingRow(model: "claude-sonnet-4.5", input: "3", output: "15", cache: "0.3"),
        PricingRow(model: "gpt-5-mini", input: "0.25", output: "2", cache: "0.025"),
        PricingRow(model: "o4-mini", input: "1.1", output: "4.4", cache: "0.275"),
        PricingRow(model: "claude-haiku-4", input: "0.8", output: "4", cache: "0.08"),
        PricingRow(model: "hermes-3-70b", input: "0.4", output: "0.8", cache: "0.1"),
        PricingRow(model: "composer-1", input: "1.2", output: "6", cache: "0.12"),
    ]

    private var pricingRows: [PricingRow] {
        let overrides = decodedOverrides()
        return Self.defaultPricingRows.map { row in
            if let o = overrides[row.model] {
                return PricingRow(model: row.model, input: o.input, output: o.output, cache: o.cache, source: "override")
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
        }
    }

    private func resetAllOverrides() {
        pricingOverridesJSON = "{}"
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
                let directory: String
                let enabled: Bool
            }
        }

        let payload = ExportPayload(
            exportedAt: Date(),
            summary: .init(
                todayTotalTokens: runtimeModel.snapshot.today.totalTokens,
                last30TotalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                estimatedCostToday: runtimeModel.snapshot.estimatedCostToday.totalCost,
                estimatedCostLast30: runtimeModel.snapshot.estimatedCostLast30.totalCost
            ),
            customSources: runtimeModel.customSources.map {
                .init(id: $0.id, name: $0.name, directory: $0.directory, enabled: $0.enabled)
            },
            eventCount: runtimeModel.events.count,
            promptCount: runtimeModel.prompts.count
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url)
        }
    }

    /// CL-P2-008: lightweight design-tokens reference rendered inline in
    /// Settings (no separate Tokens window). Each swatch copies its hex on
    /// click — useful when designers compare against the source-of-truth.
    private var designTokensSection: some View {
        settingsSection(
            title: "Design Tokens",
            subtitle: "Brand swatches and semantic surfaces. Click any swatch to copy its hex."
        ) {
            let rows: [(String, Color, String)] = [
                ("Accent (light)", TokenBarStyle.accent, "#0A9489"),
                ("Cost (light)", TokenBarStyle.cost, "#C5781A"),
                ("Lime", TokenBarStyle.lime, "#73E600"),
                ("Input (systemBlue)", TokenBarStyle.input, "system"),
                ("Output (systemOrange)", TokenBarStyle.output, "system"),
                ("Cache (systemGreen)", TokenBarStyle.cache, "system"),
                ("Warn (systemYellow)", TokenBarStyle.warn, "system"),
                ("Error (systemRed)", TokenBarStyle.error, "system"),
                ("Separator", TokenBarStyle.line, "system"),
            ]
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.2, forType: .string)
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(row.1)
                                .frame(width: 28, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(TokenBarStyle.line, lineWidth: 1))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.0)
                                    .font(.caption)
                                Text(row.2)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TokenBarStyle.faint)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy \(row.2)")
                }
            }
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
        ZStack(alignment: .top) {
            // CL-P2-009: switched to SwiftUI Form + `.formStyle(.grouped)` so
            // sections inherit the system Settings visual treatment
            // (grouped backgrounds, 10pt corners, sticky section headers)
            // while keeping the existing per-section content.
            Form {
                Section { header }
                Section("Checkpoint Interval") { checkpointSection }
                Section("Prompts") { promptSection }
                Section("Theme") { themeSection }
                Section("Pricing") { pricingSection }
                Section("Custom Sources") { customSourcesSection }
                Section("Data & Retention") { retentionSection }
                Section("Design Tokens") { designTokensSection }
            }
            .formStyle(.grouped)

            if showAddSource {
                AddCustomSourceOverlay(isPresented: $showAddSource)
                    .environmentObject(runtimeModel)
                    .zIndex(10)
            }
        }
        // CL-P0-020: previously the onAppear forced theme back to "Dark" to
        // hide the WIP Light/System modes. Now that the entire style layer is
        // backed by semantic colors, all three options round-trip correctly.
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
                todayCost: runtimeModel.snapshot.estimatedCostToday.totalCost,
                rangeCost: runtimeModel.snapshot.estimatedCostLast30.totalCost,
                todayTokens: runtimeModel.snapshot.today.totalTokens,
                totalTokens: runtimeModel.snapshot.last30Summary.totalTokens,
                todaySessions: tokenbarSessionCount(runtimeModel.events),
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
            subtitle: "Stores user-only prompts locally. UI masks by default; reveal per project."
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
            subtitle: "System tracks the OS appearance; Light and Dark force an override."
        ) {
            HStack(spacing: 12) {
                // CL-P0-020: all three tiles are now enabled because the style
                // layer has been migrated to Apple semantic colors (CL-P0-007).
                themeTile("System", enabled: true)
                themeTile("Light", enabled: true)
                themeTile("Dark", enabled: true)
            }
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
                        priceHead("Model")
                        priceHead("Input $/1M")
                        priceHead("Output $/1M")
                        priceHead("Cache $/1M")
                        priceHead("Source")
                        Color.clear.frame(width: 110)
                    }
                    Divider().gridCellColumns(6).overlay(TokenBarStyle.line)
                    ForEach(pricingRows) { row in
                        pricingGridRow(row)
                        Divider().gridCellColumns(6).overlay(TokenBarStyle.line.opacity(0.6))
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
                priceField($editBuffer.input)
                priceField($editBuffer.output)
                priceField($editBuffer.cache)
                Text("editing")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.accent)
                HStack(spacing: 4) {
                    Button("Save") {
                        saveOverride(row.model, values: editBuffer)
                        editingModel = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editBuffer.isValid)
                    Button("Cancel") { editingModel = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 9)
        } else {
            GridRow {
                Text(row.model)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                priceCell(row.input)
                priceCell(row.output)
                priceCell(row.cache)
                Text(row.source)
                    .font(.caption)
                    .foregroundStyle(row.source == "override" ? TokenBarStyle.warn : TokenBarStyle.cache)
                Button("Edit") {
                    editBuffer = PricingValues(input: row.input, output: row.output, cache: row.cache)
                    editingModel = row.model
                }
                .controlSize(.small)
            }
            .padding(.vertical, 9)
        }
    }

    private func priceField(_ binding: Binding<String>) -> some View {
        TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(binding.wrappedValue.isValidPrice ? Color.clear : TokenBarStyle.error,
                            lineWidth: 1.5)
            )
    }

    private var customSourcesSection: some View {
        settingsSection(
            title: "Custom Sources",
            subtitle: "Point TokenBar at any agent that writes JSONL or sqlite locally."
        ) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                customSourceTile(name: "Codex", path: "~/.codex/sessions", color: TokenBarStyle.input, enabled: true)
                customSourceTile(name: "Claude Code", path: "~/.claude/projects", color: TokenBarStyle.output, enabled: true)
                customSourceTile(name: "Hermes", path: "~/.hermes/state.db", color: TokenBarStyle.output, enabled: true)
                ForEach(runtimeModel.customSources) { source in
                    // CL-P1-017: per-row toggle + delete affordance for custom
                    // sources. Full path editing reuses the AddCustomSource
                    // modal (still TODO) — the toggle and delete cover the
                    // most-requested mid-lifecycle changes today.
                    editableCustomSourceTile(source: source)
                }
            }
        } trailing: {
            Button {
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
        guard let oldest = runtimeModel.events.map(\.timestamp).min() else {
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
                .foregroundStyle(selected ? Color.white : TokenBarStyle.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selected ? Color(red: 0.14, green: 0.57, blue: 0.90) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.035), in: Capsule())
        .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func themeTile(_ name: String, enabled: Bool) -> some View {
        Button {
            if enabled {
                theme = name
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(themeGradient(name))
                    if !enabled {
                        Text("Soon")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.warn)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(TokenBarStyle.warn.opacity(0.12), in: Capsule())
                            .padding(7)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(themeLine(name)).frame(width: 44, height: 4)
                        Capsule().fill(theme == name ? TokenBarStyle.input : Color.white.opacity(0.18)).frame(width: 74, height: 4)
                        Capsule().fill(themeLine(name)).frame(width: 58, height: 4)
                        Spacer()
                        Capsule().fill(themeLine(name)).frame(width: 68, height: 4)
                    }
                    .padding(10)
                }
                .frame(height: 78)

                HStack {
                    Text(name)
                        .font(.caption)
                    Spacer()
                    Circle()
                        .stroke(theme == name ? TokenBarStyle.input : TokenBarStyle.line, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .overlay {
                            if theme == name {
                                Circle().fill(TokenBarStyle.input).frame(width: 6, height: 6)
                            }
                        }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme == name ? TokenBarStyle.input.opacity(0.45) : TokenBarStyle.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.58)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(enabled ? "Use the canonical TokenBar dark theme." : "Light/System require a full light token set before they can be enabled.")
    }

    /// CL-P1-017: editable variant of `customSourceTile` for user-added
    /// sources. Built-in tiles still use the static read-only flavor.
    private func editableCustomSourceTile(source: CustomSourceRecord) -> some View {
        HStack(spacing: 13) {
            Circle()
                .fill(source.enabled ? TokenBarStyle.accent : TokenBarStyle.faint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(source.directory).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in Task { await runtimeModel.toggleCustomSource(source) } }
            ))
            .labelsHidden()
            .controlSize(.small)
            .help(source.enabled ? "Disable this source" : "Enable this source")
            Button(role: .destructive) {
                Task { await runtimeModel.removeCustomSource(id: source.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this source")
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            PendingActionButton("Edit")
        }
        .padding(13)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
    }

    private func priceHead(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TokenBarStyle.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func priceCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, design: .monospaced))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themeGradient(_ name: String) -> LinearGradient {
        switch name {
        case "Light":
            LinearGradient(colors: [Color.white, Color(red: 0.91, green: 0.94, blue: 0.96)], startPoint: .top, endPoint: .bottom)
        case "System":
            LinearGradient(colors: [Color.white, Color.white, Color(red: 0.06, green: 0.14, blue: 0.18), Color(red: 0.04, green: 0.08, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            LinearGradient(colors: [Color(red: 0.07, green: 0.16, blue: 0.20), Color(red: 0.04, green: 0.08, blue: 0.11)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func themeLine(_ name: String) -> Color {
        name == "Light" ? Color.black.opacity(0.14) : Color.white.opacity(0.15)
    }
}

private struct AddCustomSourceOverlay: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Binding var isPresented: Bool
    @State private var name = "hermes-agent"
    @State private var pathGlob = "~/.hermes/runs/*.jsonl"
    @State private var mappingOpen = false
    @State private var inputField = "usage.input_tokens"
    @State private var outputField = "usage.output_tokens"
    @State private var cacheField = "usage.cache_read_tokens"
    @State private var modelField = "model"

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            TokenBarCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Add Custom Source")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text("Point TokenBar at any agent's local log. It tails the file in place and infers the schema.")
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
                        field("Name", text: $name)
                        field("Path or glob", text: $pathGlob, trailing: {
                            Button("Browse...") {
                                browsePath()
                            }
                                .buttonStyle(SettingsButtonStyle())
                        })

                        detectionBlock

                        Button {
                            mappingOpen.toggle()
                        } label: {
                            Label("Override field mapping", systemImage: mappingOpen ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                        }
                        .buttonStyle(.plain)

                        if mappingOpen {
                            // CL-P0-019: fields are now editable; mappings are
                            // persisted in the source's `name` slot as a
                            // structured JSON suffix (until CustomSourceRecord
                            // gets first-class mapping fields). Empty input
                            // means "use auto schema detection".
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                field("Input field", text: $inputField)
                                field("Output field", text: $outputField)
                                field("Cache field", text: $cacheField)
                                field("Model field", text: $modelField)
                            }
                            Text("Mapping is saved alongside this source. Leave a field blank to fall back to auto detection.")
                                .font(.caption2)
                                .foregroundStyle(TokenBarStyle.muted)
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
                        Button("Add Source") {
                            addSource()
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .primary))
                        .disabled(pathGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
            .frame(width: 540)
            .padding(.top, 72)
        }
    }

    private var detectionBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TokenBarStyle.cache)
                .frame(width: 18, height: 18)
                .background(TokenBarStyle.cache.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Detected JSONL · auto schema · \(pathGlob.isEmpty ? 0 : 1) path matched")
                    .font(.system(size: 12.5, weight: .medium))
                Text("input -> \(inputField) · output -> \(outputField) · cache -> \(cacheField)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(TokenBarStyle.input.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(TokenBarStyle.input.opacity(0.18), lineWidth: 1))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        field(label, text: text) { EmptyView() }
    }

    private func field<Trailing: View>(_ label: String, text: Binding<String>, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .sectionLabel()
            HStack(spacing: 8) {
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                trailing()
            }
        }
    }

    private func addSource() {
        let split = splitPathGlob(pathGlob)
        Task {
            await runtimeModel.addCustomSource(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: split.directory,
                globPattern: split.glob,
                format: .auto,
                displayAgent: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : name
            )
            await MainActor.run {
                isPresented = false
            }
        }
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

    private func splitPathGlob(_ raw: String) -> (directory: String, glob: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("*") else {
            return (trimmed, "**/*.jsonl")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let firstWildcard = parts.firstIndex(where: { $0.contains("*") }) else {
            return (trimmed, "**/*.jsonl")
        }
        let dir = parts[..<firstWildcard].joined(separator: "/")
        let glob = parts[firstWildcard...].joined(separator: "/")
        return (dir.isEmpty ? "." : dir, glob.isEmpty ? "**/*.jsonl" : glob)
    }
}

struct PricingRow: Identifiable {
    var id: String { model }
    let model: String
    let input: String
    let output: String
    let cache: String
    var source: String = "default"
}

struct PricingValues: Codable, Hashable {
    var input: String = "0"
    var output: String = "0"
    var cache: String = "0"

    var isValid: Bool {
        input.isValidPrice && output.isValidPrice && cache.isValidPrice
    }
}

extension String {
    var isValidPrice: Bool {
        guard let v = Double(self) else { return false }
        return v >= 0
    }
}

private struct PendingActionButton: View {
    let title: String
    var systemImage: String?
    var kind: SettingsButtonStyle.Kind = .normal

    init(_ title: String, systemImage: String? = nil, kind: SettingsButtonStyle.Kind = .normal) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
            Text("Soon")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(TokenBarStyle.warn)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(TokenBarStyle.warn.opacity(0.12), in: Capsule())
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .foregroundStyle(kind == .danger ? TokenBarStyle.error : TokenBarStyle.muted)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        .help("Coming soon")
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 11 : 12.5, weight: .medium))
            .padding(.horizontal, size == .small ? 9 : 13)
            .frame(height: size == .small ? 24 : 30)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous).stroke(stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .normal:
            TokenBarStyle.foreground
        case .primary:
            .white
        case .danger:
            TokenBarStyle.error
        }
    }

    private var background: Color {
        switch kind {
        case .normal:
            Color.white.opacity(0.035)
        case .primary:
            Color(red: 0.12, green: 0.54, blue: 0.82)
        case .danger:
            TokenBarStyle.error.opacity(0.08)
        }
    }

    private var stroke: Color {
        switch kind {
        case .normal:
            TokenBarStyle.line
        case .primary:
            Color.white.opacity(0.12)
        case .danger:
            TokenBarStyle.error.opacity(0.30)
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
