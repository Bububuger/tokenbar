import AppKit
import SwiftUI
import TokenBarCore

/// Model drill-in (design §03c · model-detail.jsx). Scopes everything to a
/// single model: KPIs, range bars, a Project Share donut + a Token Breakdown
/// card (input/output/cache split + cache-hit badge), a Pricing card, and
/// recent sessions tagged with the source. All numbers come from real indexed
/// events for the model.
struct ModelDetailView: View {
    let modelName: String
    let events: [UsageEvent]
    let allTimeSummary: UsageSummary
    let allTimeCost: Double
    @Binding var selectedRange: String
    let refreshState: RefreshState
    let onRefresh: (() -> Void)?
    let onBack: () -> Void
    let onSelectProject: (String) -> Void

    @State private var metrics = ModelDetailRangeMetrics.empty
    @State private var isRangeLoading = false
    @State private var expandedSession: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LazyVStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
                header
                kpiRow
                RangeBarsCard(
                    days: metrics.days,
                    title: tokenbarRangeTitle(selectedRange),
                    subtitle: metrics.availabilityNote,
                    summary: metrics.rangeSummary
                )
                HStack(alignment: .top, spacing: TokenBarStyle.sectionSpacing) {
                    ShareDonutCard(
                        title: "Project Share",
                        slices: metrics.projectShare,
                        onSelect: onSelectProject
                    )
                    TokenBreakdownCard(summary: metrics.rangeSummary)
                }
                ModelPricingCard(modelName: modelName, sourceName: metrics.sourceName, pricing: metrics.pricingText)
                SourceModelSessionsCard(
                    sessions: metrics.recentSessions,
                    expandedSession: $expandedSession
                )
            }
            if isRangeLoading {
                TokenBarPageUpdatingOverlay(label: "updating \(tokenbarRangeShortLabel(selectedRange))")
            }
        }
        .animation(.easeOut(duration: 0.14), value: isRangeLoading)
        .task(id: metricsTaskID) {
            await rebuildMetrics()
        }
        .onChange(of: selectedRange) { _, _ in
            withAnimation(.easeOut(duration: 0.12)) { isRangeLoading = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoverableDetailBackButton(action: onBack)
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Model")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(TokenBarStyle.faint)
                        .textCase(.uppercase)
                    Text(modelName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(metrics.subtitleLine)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    TopRightCluster(
                        todayCost: metrics.todayCost,
                        rangeCost: metrics.rangeCost,
                        todayTokens: metrics.todaySummary.totalTokens,
                        totalTokens: metrics.rangeSummary.totalTokens,
                        todaySessions: metrics.todaySessionCount,
                        refreshState: refreshState,
                        onRefresh: onRefresh,
                        rangeLabel: tokenbarRangeShortLabel(selectedRange)
                    )
                    DateRangeControl(selection: $selectedRange)
                    HStack(spacing: 34) {
                        statBlock(label: "Est. cost", value: tokenbarCompactCurrency(allTimeCost), color: TokenBarStyle.cost)
                        statBlock(label: "All-time total", value: tokenbarCompactTokens(allTimeSummary.totalTokens), color: TokenBarStyle.foreground)
                    }
                }
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: TokenBarStyle.sectionSpacing) {
            TokenBarKPI(title: "Total", value: tokenbarTokens(metrics.rangeSummary.totalTokens), meta: tokenbarRangeShortLabel(selectedRange), color: TokenBarStyle.muted)
            TokenBarKPI(title: "Input", value: tokenbarTokens(metrics.rangeSummary.inputTokens), meta: "model input", color: TokenBarStyle.input)
            TokenBarKPI(title: "Output", value: tokenbarTokens(metrics.rangeSummary.outputTokens), meta: "model output", color: TokenBarStyle.output)
            TokenBarKPI(title: "Cache", value: tokenbarTokens(metrics.rangeSummary.cacheTokens), meta: "model cache", color: TokenBarStyle.cache)
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

    private var metricsTaskID: String {
        "\(modelName)|\(selectedRange)|\(events.count)|\(events.last?.id ?? "none")"
    }

    @MainActor
    private func rebuildMetrics() async {
        let modelName = modelName
        let selection = selectedRange
        let events = events
        guard !events.isEmpty else {
            metrics = .empty
            isRangeLoading = false
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            ModelDetailRangeMetrics.make(modelName: modelName, events: events, selection: selection)
        }.value
        guard !Task.isCancelled, self.selectedRange == selection else { return }
        metrics = computed
        withAnimation(.easeOut(duration: 0.14)) { isRangeLoading = false }
    }
}

// MARK: - Token Breakdown card (design §03c)

/// Input / Output / Cache split for the model, with a stacked bar and a
/// cache-hit-rate pill. Mirrors the `TokenBreakdownCard` in model-detail.jsx.
struct TokenBreakdownCard: View {
    let summary: UsageSummary

    private var total: Int { max(summary.totalTokens, 1) }
    private var inPct: Double { Double(summary.inputTokens) / Double(total) }
    private var outPct: Double { Double(summary.outputTokens) / Double(total) }
    private var cachePct: Double { Double(summary.cacheTokens) / Double(total) }
    private var cacheRatio: Double { summary.totalTokens > 0 ? Double(summary.cacheTokens) / Double(summary.totalTokens) : 0 }

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Token Breakdown")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(alignment: .top, spacing: 12) {
                    breakdownColumn("Input", value: summary.inputTokens, pct: inPct, color: TokenBarStyle.input)
                    breakdownColumn("Output", value: summary.outputTokens, pct: outPct, color: TokenBarStyle.output)
                    breakdownColumn("Cache", value: summary.cacheTokens, pct: cachePct, color: TokenBarStyle.cache)
                }
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(TokenBarStyle.input).frame(width: geo.size.width * inPct)
                        Rectangle().fill(TokenBarStyle.output).frame(width: geo.size.width * outPct)
                        Rectangle().fill(TokenBarStyle.cache).frame(width: geo.size.width * cachePct)
                        Rectangle().fill(TokenBarStyle.line)
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                HStack {
                    Spacer()
                    Text("\(Int((cacheRatio * 100).rounded()))% cache hit")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.cache)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(TokenBarStyle.cache.opacity(0.10), in: Capsule())
                        .overlay(Capsule().stroke(TokenBarStyle.cache.opacity(0.18), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 246, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 286)
    }

    private func breakdownColumn(_ label: String, value: Int, pct: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(TokenBarStyle.faint)
                    .textCase(.uppercase)
            }
            Text(tokenbarTokens(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tokenbarPercent(pct))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pricing card (design §03c). Shows the source badge and the per-1M pricing
/// string derived from the active pricing table / overrides.
struct ModelPricingCard: View {
    let modelName: String
    let sourceName: String
    let pricing: String

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pricing")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    Text("Source")
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(TokenBarStyle.faint)
                        .textCase(.uppercase)
                    Text(sourceName)
                        .font(.system(size: 11))
                        .foregroundStyle(TokenBarStyle.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(TokenBarStyle.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(TokenBarStyle.line, lineWidth: 1))
                }
                Text(pricing)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
                    .textSelection(.enabled)
                Text("per 1M tokens · cache read at discounted rate")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Metrics

struct ModelDetailRangeMetrics: Sendable, Hashable {
    let days: [UsageDay]
    let availabilityNote: String
    let sourceName: String
    let subtitleLine: String
    let pricingText: String
    let rangeSummary: UsageSummary
    let todaySummary: UsageSummary
    let rangeCost: Double
    let todayCost: Double
    let todaySessionCount: Int
    let projectShare: [AgentShareSlice]
    let recentSessions: [DetailSessionSummary]

    static let empty = ModelDetailRangeMetrics(
        days: [],
        availabilityNote: "Preparing range",
        sourceName: "—",
        subtitleLine: "",
        pricingText: "No pricing on record",
        rangeSummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        todaySummary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        rangeCost: 0,
        todayCost: 0,
        todaySessionCount: 0,
        projectShare: [],
        recentSessions: []
    )

    static func make(
        modelName: String,
        events: [UsageEvent],
        selection: String,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> ModelDetailRangeMetrics {
        let modelEvents = events.filter { event in
            let resolved = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
            return resolved == modelName
        }
        let rangeEvents = tokenbarRangeEvents(events: modelEvents, selection: selection, referenceDate: referenceDate, calendar: calendar)
        let todayEvents = tokenbarEventsInLastDays(events: modelEvents, referenceDate: referenceDate, calendar: calendar)
        let days = tokenbarUsageDays(events: modelEvents, selection: selection, referenceDate: referenceDate, calendar: calendar)

        // Source = the agent that produced the most tokens for this model.
        let sourceName = Dictionary(grouping: modelEvents, by: { $0.agent.displayName })
            .max { lhs, rhs in
                let lt = tokenbarSummary(lhs.value).totalTokens
                let rt = tokenbarSummary(rhs.value).totalTokens
                if lt == rt { return lhs.key > rhs.key }
                return lt < rt
            }?.key ?? "Local"

        return ModelDetailRangeMetrics(
            days: days,
            availabilityNote: tokenbarRangeAvailabilityNote(selection: selection, days: days, events: modelEvents, referenceDate: referenceDate, calendar: calendar),
            sourceName: sourceName,
            subtitleLine: "\(sourceName) · \(modelPricingSummary(modelName))",
            pricingText: modelPricingDetail(modelName),
            rangeSummary: tokenbarSummary(rangeEvents),
            todaySummary: tokenbarSummary(todayEvents),
            rangeCost: tokenbarEstimatedCost(events: rangeEvents),
            todayCost: tokenbarEstimatedCost(events: todayEvents),
            todaySessionCount: tokenbarSessionCount(modelEvents, referenceDate: referenceDate),
            projectShare: tokenbarProjectShare(events: rangeEvents),
            recentSessions: DetailSessionSummary.make(events: rangeEvents, tag: .source, limit: 6)
        )
    }
}

/// Compact pricing summary for the model subtitle (e.g. "$3 / $15 per 1M").
private func modelPricingSummary(_ modelName: String) -> String {
    let pricing = TokenBarPricingLookup()
    guard let values = pricing.values(for: modelName) else {
        return "pricing n/a"
    }
    return "$\(trimPrice(values.input)) / $\(trimPrice(values.output)) per 1M"
}

/// Full pricing line for the Pricing card.
private func modelPricingDetail(_ modelName: String) -> String {
    let pricing = TokenBarPricingLookup()
    guard let values = pricing.values(for: modelName) else {
        return "No pricing on record · estimated by source default rate"
    }
    return "$\(trimPrice(values.input)) input · $\(trimPrice(values.output)) output · $\(trimPrice(values.cacheRead)) cache read"
}

/// Pricing fields are decimal strings (price per 1M tokens). Drop a trailing
/// ".00" so "$3.00" renders as "$3" while keeping fractional rates intact.
private func trimPrice(_ value: String) -> String {
    guard let number = Double(value) else { return value }
    if number == number.rounded() {
        return String(Int(number))
    }
    return value
}
