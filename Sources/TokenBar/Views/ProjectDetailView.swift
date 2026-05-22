import SwiftUI
import TokenBarCore

struct ProjectDetailView: View {
    let detail: ProjectDetailSnapshot
    let projectPath: String?
    let allTimeSummary: UsageSummary
    let allTimeCost: UsageCostProjection
    let prompts: [PromptRecord]
    let events: [UsageEvent]
    let refreshState: RefreshState
    let switchState: ProjectSwitchState?
    let todayCost: Double
    let rangeCost: Double
    let todayTokens: Int
    let totalTokens: Int
    let todaySessions: Int
    let onRefresh: (() -> Void)?
    let onBack: () -> Void

    @State private var selectedRange = "30d"
    @State private var revealPrompts = false
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    // CL-P1-016: which session row is expanded into the detail drawer.
    @State private var expandedSession: String?
    // CL-P0-033: Reveal is gated by the global "Store prompt text in clear"
    // setting. When mask-only is configured, the button is disabled and
    // hovering it explains where to enable Full capture.
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel

    var body: some View {
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            staged(header, start: 0.02, end: 0.18)
            staged(kpiRow, start: 0.12, end: 0.34)
            staged(RangeBarsCard(
                days: rangeDays,
                title: tokenbarRangeTitle(selectedRange),
                subtitle: tokenbarRangeAvailabilityNote(selection: selectedRange, availableDays: detail.last30Days.count)
            ), start: 0.30, end: 0.54)
            HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                staged(agentShareCard, start: 0.42, end: 0.68)
                staged(recentSessionsCard, start: 0.48, end: 0.72)
            }
            staged(ModelBreakdownTable(
                title: "Model",
                subtitle: "Cost and token attribution used by \(detail.projectName).",
                totalCost: tokenbarCompactCurrency(projectRangeCost),
                rows: modelRows
            ), start: 0.62, end: 0.84)
            staged(promptHistoryCard, start: 0.76, end: 0.96)
        }
        .animation(.easeInOut(duration: 0.16), value: switchProgress)
        .animation(.easeOut(duration: 0.22), value: switchState?.phase)
    }

    private var switchProgress: Double {
        switchState?.progress ?? 1.0
    }

    private func reveal(_ start: Double, _ end: Double) -> Double {
        guard end > start else { return switchProgress >= end ? 1 : 0 }
        return min(max((switchProgress - start) / (end - start), 0), 1)
    }

    private func staged<Content: View>(_ content: Content, start: Double, end: Double) -> some View {
        let amount = reveal(start, end)
        return content
            .opacity(0.18 + 0.82 * amount)
            .offset(y: 14 * (1 - amount))
            .blur(radius: max(0, 1.6 * (1 - amount)))
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
                        todayCost: todayCost,
                        rangeCost: rangeCost,
                        todayTokens: todayTokens,
                        totalTokens: totalTokens,
                        todaySessions: todaySessions,
                        refreshState: refreshState,
                        onRefresh: onRefresh
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
            TokenBarKPI(title: "Total", value: tokenbarTokens(detail.summary.totalTokens), meta: "30d window", color: TokenBarStyle.muted)
            TokenBarKPI(title: "Input", value: tokenbarTokens(detail.summary.inputTokens), meta: "project input", color: TokenBarStyle.input)
            TokenBarKPI(title: "Output", value: tokenbarTokens(detail.summary.outputTokens), meta: "project output", color: TokenBarStyle.output)
            TokenBarKPI(title: "Cache", value: tokenbarTokens(detail.summary.cacheTokens), meta: "project cache", color: TokenBarStyle.cache)
        }
    }

    private var rangeDays: [UsageDay] {
        tokenbarRangeDays(detail.last30Days, selection: selectedRange)
    }

    private var modelRows: [TokenBarModelBreakdown] {
        tokenbarModelBreakdowns(
            events: events,
            projectName: detail.projectName,
            days: tokenbarDaysForRange(selectedRange)
        )
    }

    private var projectRangeCost: Double {
        tokenbarEstimatedCost(
            events: events,
            days: tokenbarDaysForRange(selectedRange)
        ) { $0.projectName == detail.projectName }
    }

    private var agentShareCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent Share")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 22) {
                    TokenBarDonut(slices: detail.agentShare)
                        .frame(width: 122, height: 122)
                    VStack(spacing: 8) {
                        if detail.agentShare.isEmpty {
                            Text("No agent share available in this project window.")
                                .font(.caption)
                                .foregroundStyle(TokenBarStyle.muted)
                        } else {
                            ForEach(detail.agentShare.prefix(5)) { slice in
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
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recentSessionsCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if detail.recentSessions.isEmpty {
                    Text("No sessions in the current project window.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    ForEach(detail.recentSessions.prefix(6)) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedSession = (expandedSession == session.sessionId) ? nil : session.sessionId
                                }
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

    private var promptHistoryCard: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prompt History")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("User-only prompts are local and masked by default.")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
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
                          : "Enable Prompt Capture in Settings → Prompts to allow Reveal")
                }

                if prompts.isEmpty {
                    Text("No local prompt captures for this project.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                } else {
                    VStack(spacing: 8) {
                        ForEach(prompts.prefix(10)) { prompt in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(prompt.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    Text(prompt.agent.displayName)
                                }
                                .font(.caption2)
                                .foregroundStyle(TokenBarStyle.faint)

                                // CL-P0-033: even if the local State toggle
                                // was set previously, treat the prompt as
                                // masked unless the Settings switch is on.
                                let allowReveal = revealPrompts && runtimeModel.storePromptTextInClearText
                                Text(allowReveal ? prompt.content : maskedPrompt(prompt.content))
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(allowReveal ? TokenBarStyle.foreground : TokenBarStyle.muted)
                                    .lineLimit(allowReveal ? 3 : 1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(TokenBarStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TokenBarStyle.line.opacity(0.7), lineWidth: 1))
                        }
                    }
                }
            }
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
