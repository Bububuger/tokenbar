import AppKit
import SwiftUI
import TokenBarCore

enum TokenBarStyle {
    static let pagePadding: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let sidebarWidth: CGFloat = 248

    // MARK: - Semantic foreground / structure (CL-P0-007 / DESIGN§5.1)
    //
    // All non-brand colors are sourced from Apple's dynamic system catalog so
    // they adapt to light/dark, Increase Contrast, and Reduce Transparency
    // automatically. The `Color(nsColor: .xxx)` wrappers keep the old call
    // sites compiling (TokenBarStyle.foreground / .muted / etc.).
    static let foreground = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let line = Color(nsColor: .separatorColor)

    // MARK: - Token category colors (CL-P0-010 / DESIGN§3.B.2)
    //
    // Input / Output / Cache must remain visually distinct under deuteranopia,
    // so we use Apple's `systemBlue / .systemOrange / .systemGreen`. They are
    // semantically locked to "Input / Output / Cache" — agents reuse a separate
    // palette below (see `agentColor`).
    static let input = Color(nsColor: .systemBlue)
    static let output = Color(nsColor: .systemOrange)
    static let cache = Color(nsColor: .systemGreen)

    // Cost retains its warm-orange identity from the design, but adapts to
    // light/dark via a NSColor dynamic provider (CL-P0-009 substitute for
    // Asset Catalog `Cost` color set — same effective behavior).
    static let cost = Color(nsColor: NSColor(name: "TokenBarCost") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.94, green: 0.64, blue: 0.24, alpha: 1)
            : NSColor(red: 0.77, green: 0.47, blue: 0.10, alpha: 1)
    })

    // Brand accent (DESIGN§3.B.1) — teal kept as the one custom brand color.
    static let accent = Color(nsColor: NSColor(name: "TokenBarAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.06, green: 0.71, blue: 0.65, alpha: 1)
            : NSColor(red: 0.04, green: 0.58, blue: 0.54, alpha: 1)
    })

    // MARK: - Status colors (DESIGN§3.C)
    //
    // Lime is retained for the live-blink mid bar in the menubar glyph because
    // it must read as "healthy" against an arbitrary wallpaper-tinted bar; it
    // is otherwise unused. Warn/Error come from system semantic warnings so
    // they participate in Increase Contrast automatically.
    static let lime = Color(nsColor: NSColor(name: "TokenBarLime") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.72, green: 0.90, blue: 0.29, alpha: 1)
            : NSColor(red: 0.45, green: 0.65, blue: 0.10, alpha: 1)
    })
    static let warn = Color(nsColor: .systemYellow)
    static let error = Color(nsColor: .systemRed)

    /// Agent attribution palette (CL-P0-011 / DESIGN§3.B.2).
    /// Codex anchors to brand accent (teal) so it no longer collides with the
    /// Input token color (which is system blue). All others are pulled from
    /// Apple's accessible system palette.
    static func agentColor(_ name: String) -> Color {
        switch name {
        case "Codex":
            return accent
        case "Claude", "Claude Code":
            return Color(nsColor: .systemOrange)
        case "Gemini", "Gemini CLI":
            return Color(nsColor: .systemPurple)
        case "Hermes":
            return Color(nsColor: .systemPink)
        default:
            return muted
        }
    }

    static func statusColor(for refreshState: RefreshState) -> Color {
        switch refreshState {
        case .idle:
            cache
        case .refreshing:
            accent
        case .stale:
            warn
        case .failed:
            error
        }
    }
}

/// CL-P1-001 / DESIGN§3.C.1: 4-step usage status scale used by KPI numbers,
/// heatmap accents, and any future "you are X above 30d P50" badge. L0 = below
/// average, L4 = critical (exclamation icon). The mapping is alpha-stable so
/// the scale survives deuteranopia simulation.
enum TokenBarUsageStatus: Int {
    case nominal = 0      // L0
    case elevated         // L1
    case high             // L2
    case warning          // L3
    case critical         // L4

    /// Compute the bucket from today's value vs the 30-day P50 baseline.
    static func compute(today: Int, baseline30d: Int) -> TokenBarUsageStatus {
        guard baseline30d > 0 else { return .nominal }
        let ratio = Double(today) / Double(baseline30d)
        switch ratio {
        case ..<1.0:  return .nominal
        case ..<1.5:  return .elevated
        case ..<2.0:  return .high
        case ..<3.0:  return .warning
        default:      return .critical
        }
    }

    var color: Color {
        switch self {
        case .nominal, .elevated:
            return Color(nsColor: .labelColor) // CL-P1-003: stays neutral when safe
        case .high:
            return Color(nsColor: .systemYellow)
        case .warning:
            return Color(nsColor: .systemOrange)
        case .critical:
            return Color(nsColor: .systemRed)
        }
    }

    var symbol: String? {
        self == .critical ? "exclamationmark.triangle.fill" : nil
    }
}

enum MenuBarMirrorMode: String, CaseIterable, Identifiable {
    case tokens
    case cost
    case sessions
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens:
            "Tokens"
        case .cost:
            "Cost"
        case .sessions:
            "Sessions"
        case .off:
            "Off"
        }
    }
}

struct TokenBarModelBreakdown: Identifiable, Hashable {
    let name: String
    let agentName: String
    let summary: UsageSummary
    let cost: Double
    let percentage: Double

    var id: String { name }

    var attribution: String {
        "\(agentName) · \(tokenbarPercent(percentage)) of tokens"
    }

    var cacheRatio: Double {
        guard summary.totalTokens > 0 else { return 0 }
        return Double(summary.cacheTokens) / Double(summary.totalTokens)
    }
}

func tokenbarTokens(_ value: Int) -> String {
    TokenBarNumberFormatting.stagedTokens(value)
}

/// CL-P1-004: split a staged token string ("1.5M") into ("1.5", "M") so the
/// Hero can render the unit suffix in a smaller, faint font. Returns
/// (number, suffix) where suffix may be empty.
func tokenbarSplitStagedTokens(_ value: Int) -> (number: String, suffix: String) {
    let s = TokenBarNumberFormatting.stagedTokens(value)
    if let last = s.last, "KMB".contains(last) {
        return (String(s.dropLast()), String(last))
    }
    if s.hasPrefix(">") { return (s, "") }
    return (s, "")
}

func tokenbarCurrency(_ value: Double, maximumFractionDigits: Int = 2) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.currencySymbol = "$"
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = value >= 10 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
}

func tokenbarPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func tokenbarRelativeTime(_ date: Date?) -> String {
    guard let date else { return "never" }
    let delta = Date().timeIntervalSince(date)
    // CL-P1-035: when the system clock has been moved backwards the recorded
    // timestamp is now "in the future". Treat that as `just now` rather than
    // surfacing a confusing `in 30m`.
    if delta < 75 { return "now" }
    if delta < 3600 { return "\(Int(delta / 60))m ago" }
    if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

func tokenbarDaysForRange(_ selection: String) -> Int {
    switch selection {
    case "7d":
        7
    case "90d":
        90
    case "1y":
        365
    case "Custom":
        30
    default:
        30
    }
}

func tokenbarRangeTitle(_ selection: String) -> String {
    switch selection {
    case "7d":
        "Last 7 days"
    case "90d":
        "Last 90 days"
    case "1y":
        "Last 1 year"
    case "Custom":
        "Custom range"
    default:
        "Last 30 days"
    }
}

func tokenbarRangeDays(_ days: [UsageDay], selection: String) -> [UsageDay] {
    let requested = tokenbarDaysForRange(selection)
    guard !days.isEmpty else {
        return UsageDay.placeholder(count: min(requested, 30))
    }
    return Array(days.suffix(min(days.count, requested)))
}

func tokenbarRangeAvailabilityNote(selection: String, availableDays: Int) -> String {
    let requested = tokenbarDaysForRange(selection)
    if selection == "Custom" {
        return "Custom uses the available local-index window until persisted custom windows are added."
    }
    if requested > availableDays {
        return "Requested \(tokenbarRangeTitle(selection).lowercased()); showing \(availableDays)d available in the local index."
    }
    return "Input / output / cache stacked bars from indexed local events."
}

func tokenbarSessionCount(_ events: [UsageEvent], days: Int = 1, referenceDate: Date = Date()) -> Int {
    let calendar = Calendar(identifier: .gregorian)
    let todayStart = calendar.startOfDay(for: referenceDate)
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
    return Set(events.filter { $0.timestamp >= start && $0.timestamp < end }.map(\.sessionId)).count
}

func tokenbarIdleHourRanges(_ hours: [UsageHourOfDay]) -> String {
    let totalsByHour = hours.reduce(into: [Int: Int]()) { totals, hour in
        totals[hour.hourOfDay, default: 0] += hour.summary.totalTokens
    }
    let idleHours = (0..<24).filter { (totalsByHour[$0] ?? 0) == 0 }
    guard !idleHours.isEmpty else { return "no idle hours" }
    if idleHours.count == 24 { return "idle all day" }

    var ranges: [String] = []
    var start = idleHours[0]
    var previous = idleHours[0]
    for hour in idleHours.dropFirst() {
        if hour == previous + 1 {
            previous = hour
        } else {
            ranges.append(formatIdleRange(start: start, end: previous))
            start = hour
            previous = hour
        }
    }
    ranges.append(formatIdleRange(start: start, end: previous))
    return "idle " + ranges.prefix(3).joined(separator: " · ")
}

private func formatIdleRange(start: Int, end: Int) -> String {
    if start == end {
        return String(format: "%02d", start)
    }
    return String(format: "%02d-%02d", start, end)
}

func tokenbarModelBreakdowns(
    events: [UsageEvent],
    projectName: String? = nil,
    days: Int = 30,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
) -> [TokenBarModelBreakdown] {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate

    let filtered = events.filter { event in
        if event.timestamp < windowStart || event.timestamp >= windowEnd {
            return false
        }
        if let projectName, event.projectName != projectName {
            return false
        }
        return true
    }

    struct Accumulator {
        var inputTokens = 0
        var outputTokens = 0
        var cacheTokens = 0
        var cost = 0.0
        var agentTokens: [String: Int] = [:]
    }

    var grouped: [String: Accumulator] = [:]
    for event in filtered {
        let modelName = event.modelName?.isEmpty == false ? event.modelName! : event.agent.displayName
        var current = grouped[modelName] ?? Accumulator()
        let eventTokens = event.inputTokens + event.outputTokens + event.cacheTokens
        current.inputTokens += event.inputTokens
        current.outputTokens += event.outputTokens
        current.cacheTokens += event.cacheTokens
        current.cost += Double(eventTokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
        current.agentTokens[event.agent.displayName, default: 0] += eventTokens
        grouped[modelName] = current
    }

    let totalTokens = grouped.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheTokens }

    return grouped.map { name, accumulator in
        let summary = UsageSummary(
            inputTokens: accumulator.inputTokens,
            outputTokens: accumulator.outputTokens,
            cacheTokens: accumulator.cacheTokens
        )
        let agentName = accumulator.agentTokens.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key ?? "Local"
        let percentage = totalTokens > 0 ? Double(summary.totalTokens) / Double(totalTokens) : 0
        return TokenBarModelBreakdown(
            name: name,
            agentName: agentName,
            summary: summary,
            cost: accumulator.cost,
            percentage: percentage
        )
    }
    .sorted { lhs, rhs in
        if lhs.summary.totalTokens == rhs.summary.totalTokens {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.summary.totalTokens > rhs.summary.totalTokens
    }
}

/// CL-P0-014: lightweight hover tooltip used everywhere a mono number is
/// rendered. Uses SwiftUI's `.help(_:)` which sits on top of NSToolTip — same
/// fade-in delay as system tooltips, free `Esc`-to-dismiss, free A11y.
extension View {
    func tbNumberTooltip(precise value: Int, window: String) -> some View {
        let pretty = value.formatted(.number)
        return self.help("\(pretty) tokens · \(window)")
    }

    func tbNumberTooltip(precise cost: Double, window: String) -> some View {
        let pretty = cost.formatted(.currency(code: "USD").precision(.fractionLength(0...4)))
        return self.help("\(pretty) · \(window)")
    }

    func tbTooltip(_ text: String) -> some View {
        self.help(text)
    }
}

enum TokenBarRankingKind {
    case project
    case agent
}

/// Row payload used by RankingCard. CL-P0-015 introduces `subtitle` (per-row
/// agent or project breakdown) and CL-P0-016 introduces `cost`. Both fill
/// gaps that previously rendered as the hard-coded "local indexed usage"
/// string with no cost column.
struct TokenBarRankingRow: Identifiable, Hashable {
    let name: String
    let totalTokens: Int
    let subtitle: String
    let cost: Double

    var id: String { name }
}

/// Build display-ready ranking rows for projects or agents.
///
/// For project rows the subtitle lists the top agents *participating* in that
/// project; for agent rows it lists the top projects driven by that agent —
/// matching how the menubar Popover already renders attribution.
func tokenbarRankingRows(
    rows: [UsageBreakdown],
    events: [UsageEvent],
    kind: TokenBarRankingKind,
    days: Int = 30,
    referenceDate: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    maxSubtitle: Int = 3
) -> [TokenBarRankingRow] {
    let todayStart = calendar.startOfDay(for: referenceDate)
    let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
    let filtered = events.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }

    return rows.map { row in
        let rowEvents = filtered.filter { event in
            switch kind {
            case .project: return event.projectName == row.name
            case .agent:   return event.agent.displayName == row.name
            }
        }
        let cost = rowEvents.reduce(0.0) { partial, event in
            let tokens = event.inputTokens + event.outputTokens + event.cacheTokens
            return partial + Double(tokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
        }
        let subtitle = rankingSubtitle(events: rowEvents, kind: kind, max: maxSubtitle)
        return TokenBarRankingRow(
            name: row.name,
            totalTokens: row.summary.totalTokens,
            subtitle: subtitle,
            cost: cost
        )
    }
}

private func rankingSubtitle(events: [UsageEvent], kind: TokenBarRankingKind, max: Int) -> String {
    let totalsByKey: [String: Int]
    switch kind {
    case .project:
        totalsByKey = events.reduce(into: [String: Int]()) { acc, e in
            acc[e.agent.displayName, default: 0] += e.inputTokens + e.outputTokens + e.cacheTokens
        }
    case .agent:
        totalsByKey = events.reduce(into: [String: Int]()) { acc, e in
            acc[e.projectName, default: 0] += e.inputTokens + e.outputTokens + e.cacheTokens
        }
    }
    let top = totalsByKey
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .prefix(max)
        .map(\.key)
    if top.isEmpty {
        return kind == .project ? "no agents yet" : "no projects yet"
    }
    return top.joined(separator: " · ")
}

func tokenbarMirrorValue(
    mode: MenuBarMirrorMode,
    todayTokens: Int,
    todayCost: Double,
    todaySessions: Int
) -> String {
    switch mode {
    case .tokens:
        tokenbarTokens(todayTokens)
    case .cost:
        tokenbarCurrency(todayCost, maximumFractionDigits: 2)
    case .sessions:
        "\(todaySessions)"
    case .off:
        ""
    }
}


/// Popover / Settings popover background.
///
/// CL-P0-006: replaces the previous custom dark gradient with `.regularMaterial`
/// so the surface picks up wallpaper tint behind the menubar popover (the
/// SwiftUI analogue of NSWindow.hudWindow material). Reduce Transparency falls
/// back to `controlBackgroundColor` so the surface stays legible without vibrancy.
struct TokenBarGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .ignoresSafeArea()
    }
}

/// Sidebar background (CL-P0-008). `.bar` material renders a SwiftUI surface
/// equivalent to NSVisualEffectView with `.sidebar` material; falls back to a
/// flat semantic color when transparency is reduced.
struct TokenBarSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Rectangle().fill(.bar)
            }
        }
        .ignoresSafeArea()
    }
}

struct TokenBarCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = TokenBarStyle.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .foregroundStyle(TokenBarStyle.foreground)
            // CL-P0-007: card uses `controlBackgroundColor` so it sits cleanly
            // on both light and dark variants without a custom gradient or the
            // heavy 18pt shadow (NSPopover already adds its own shadow).
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
                    .stroke(TokenBarStyle.line, lineWidth: 1)
            )
    }
}

typealias TokenBarGlassCard = TokenBarCard

struct TokenBarBrandGlyph: View {
    var size: CGFloat = 30
    var boxed = true

    var body: some View {
        VStack(spacing: size * 0.10) {
            // CL-P0-007 / CL-P0-010: bars use brand accent + lime + a deeper
            // accent shade so they stay distinct from system semantic colors.
            glyphBar(width: size * 0.42, color: TokenBarStyle.accent)
            glyphBar(width: size * 0.66, color: TokenBarStyle.lime)
            glyphBar(width: size * 0.50, color: TokenBarStyle.accent.opacity(0.55))
        }
        .frame(width: size, height: size)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .stroke(TokenBarStyle.line, lineWidth: 1)
                    )
            }
        }
    }

    private func glyphBar(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: max(1, size * 0.04), style: .continuous)
            .fill(color)
            .frame(width: width, height: max(2, size * 0.12))
    }
}

struct TokenBarStatusGlyph: View {
    let state: RefreshState
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var liveOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 1.6) {
            bar(width: 10.5, color: TokenBarStyle.muted)
            // CL-P0-002: middle bar breathes 0.6↔1.0 over 1.05s while idle
            // (Reduce Motion holds it at full opacity).
            bar(width: 14, color: middleColor)
                .opacity(state == .idle && !reduceMotion ? liveOpacity : 1.0)
                .onAppear { startLiveAnimationIfNeeded() }
                .onChange(of: state) { _, _ in startLiveAnimationIfNeeded() }
        bar(width: 9, color: TokenBarStyle.accent.opacity(0.95))
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .topTrailing) {
            // CL-P0-005: failed → 4×4 red dot with 1.5px menubar-tinted stroke.
            // Stale → 4×4 amber dot (CL-P1-024 hardens the stroke separately).
            if state == .failed || state == .stale {
                Circle()
                    .fill(state == .failed ? TokenBarStyle.error : TokenBarStyle.warn)
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .offset(x: 2, y: -1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // CL-P0-003: paused indicator moved from a center capsule overlay
            // to two thin vertical lines at bottom-right (the design-canvas
            // "❘❘" mark). Tinted with `warn` so it reads clearly on both light
            // and dark menubars.
            if paused {
                HStack(spacing: 1) {
                    Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                    Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                }
                .offset(x: 2, y: 1)
            }
        }
    }

    private var middleColor: Color {
        switch state {
        case .idle:
            TokenBarStyle.lime
        case .refreshing:
            TokenBarStyle.accent
        case .stale:
            TokenBarStyle.warn
        case .failed:
            TokenBarStyle.error
        }
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.1, style: .continuous)
            .fill(color)
            .frame(width: width, height: 2.1)
    }

    private func startLiveAnimationIfNeeded() {
        guard state == .idle, !reduceMotion else {
            liveOpacity = 1.0
            return
        }
        liveOpacity = 1.0
        withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
            liveOpacity = 0.6
        }
    }
}

/// CL-P0-001: programmatic NSStatusBar template image. Pure-black 3-bar glyph
/// flagged `isTemplate = true` so macOS auto-tints it for the active menubar
/// appearance (works under wallpaper-tinted, dark, Reduce Transparency, and
/// Increase Contrast environments without per-state PDFs from design).
enum TokenBarMenuBarGlyphImage {
    static func template(size: CGFloat = 16) -> NSImage {
        let pixelSize = NSSize(width: size, height: size)
        let image = NSImage(size: pixelSize, flipped: false) { rect in
            NSColor.black.setFill()
            let widths: [CGFloat] = [10.5, 14, 9]
            let barHeight: CGFloat = 2.1
            let spacing: CGFloat = 1.6
            let total = barHeight * 3 + spacing * 2
            let startY = (rect.height - total) / 2
            for (idx, w) in widths.enumerated() {
                let y = startY + CGFloat(2 - idx) * (barHeight + spacing)
                let x = (rect.width - w) / 2
                let path = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: w, height: barHeight),
                    xRadius: 1.1,
                    yRadius: 1.1
                )
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct TokenBarStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
    }
}

struct TokenBarKPI: View {
    let title: String
    let value: String
    let meta: String
    let color: Color
    /// CL-P0-012: optional tap handler. When non-nil, the entire card becomes
    /// a button and a chevron hints at the expansion affordance. Acceptance
    /// notes "再次点击 / Esc / 卡外点击关闭" — callers control state externally.
    var onTap: (() -> Void)? = nil
    var isExpanded: Bool = false
    var preciseValue: Int? = nil
    /// CL-P1-003: when caller passes a status, the big number is tinted only
    /// for L3/L4. Below those thresholds the number stays `labelColor` so the
    /// surface doesn't scream when usage is nominal.
    var status: TokenBarUsageStatus? = nil

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { body(showsChevron: true) }
                    .buttonStyle(.plain)
                    .help("Click to toggle 24h detail")
            } else {
                body(showsChevron: false)
            }
        }
    }

    private func body(showsChevron: Bool) -> some View {
        TokenBarCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TokenBarStyle.muted)
                    Spacer()
                    if showsChevron {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TokenBarStyle.faint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if let preciseValue {
                            Text(value).tbNumberTooltip(precise: preciseValue, window: meta)
                        } else {
                            Text(value)
                        }
                    }
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(status?.color ?? Color(nsColor: .labelColor))
                    if let symbol = status?.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(status?.color ?? TokenBarStyle.warn)
                    }
                }
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: TokenBarStyle.cardCornerRadius, style: .continuous)
                    .stroke(TokenBarStyle.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

/// CL-P0-012 / CL-P0-013: thin "drawer" that slides under a clicked KPI to
/// show today · yesterday · 7d-avg comparisons. Kept dependency-light so it
/// can render under either the Overview KPI row or the Popover PopKPI row.
struct TokenBarKPIDetailDrawer: View {
    let title: String
    let today: Int
    let yesterday: Int
    let sevenDayAverage: Int
    let cost: Double?
    var onClose: (() -> Void)? = nil

    var body: some View {
        TokenBarCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(title) detail")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(5)
                                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    detailColumn(label: "Today", value: today, accent: TokenBarStyle.accent)
                    detailColumn(label: "Yesterday", value: yesterday, accent: TokenBarStyle.muted)
                    detailColumn(label: "7d avg", value: sevenDayAverage, accent: TokenBarStyle.cache)
                    if let cost {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cost (today)")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(TokenBarStyle.faint)
                            Text(tokenbarCurrency(cost, maximumFractionDigits: 3))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(TokenBarStyle.cost)
                        }
                    }
                    Spacer()
                }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func detailColumn(label: String, value: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(TokenBarStyle.faint)
            Text(tokenbarTokens(value))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .tbNumberTooltip(precise: value, window: label.lowercased())
        }
    }
}

struct InputOutputCacheBar: View {
    let summary: UsageSummary
    var height: CGFloat = 6

    var body: some View {
        Group {
            if summary.totalTokens <= 0 {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(TokenBarStyle.line)
            } else {
                GeometryReader { proxy in
                    let total = summary.totalTokens
                    HStack(spacing: 1) {
                        Rectangle()
                            .fill(TokenBarStyle.input)
                            .frame(width: proxy.size.width * CGFloat(summary.inputTokens) / CGFloat(total))
                        Rectangle()
                            .fill(TokenBarStyle.output)
                            .frame(width: proxy.size.width * CGFloat(summary.outputTokens) / CGFloat(total))
                        Rectangle()
                            .fill(TokenBarStyle.cache)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            }
        }
        .frame(height: height)
        .background(TokenBarStyle.line, in: RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }
}

struct UsageStackedBarChart: View {
    let days: [UsageDay]
    var height: CGFloat = 118
    /// CL-P1-008: optional click handler. When non-nil, every bar becomes
    /// clickable and a hover tooltip shows MM-DD · tokens · cost.
    var onSelect: ((UsageDay) -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(displayDays) { day in
                let total = max(day.summary.totalTokens, 1)
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(TokenBarStyle.output.opacity(0.85))
                        .frame(height: segmentHeight(day.summary.outputTokens, total: total))
                    Rectangle()
                        .fill(TokenBarStyle.input.opacity(0.85))
                        .frame(height: segmentHeight(day.summary.inputTokens, total: total))
                    Rectangle()
                        .fill(TokenBarStyle.cache.opacity(0.90))
                        .frame(height: segmentHeight(day.summary.cacheTokens, total: total))
                }
                .frame(maxWidth: .infinity)
                .frame(height: max(6, height * max(0.06, day.intensity)))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(day.summary.totalTokens > 0 ? 1 : 0.30)
                .help("\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(tokenbarTokens(day.summary.totalTokens))")
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(day) }
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }

    private func segmentHeight(_ tokens: Int, total: Int) -> CGFloat {
        max(1, CGFloat(tokens) / CGFloat(total) * height)
    }
}

struct UsageHeatmapStripView: View {
    let days: [UsageDay]
    let leadingLabel: String
    let trailingLabel: String
    @State private var hoveredDay: UsageDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(leadingLabel)
                Spacer()
                Text(hoverLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.caption2)
            .foregroundStyle(TokenBarStyle.muted)

            HStack(spacing: 4) {
                ForEach(displayDays) { day in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(heatColor(day.intensity))
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredDay = isHovering ? day : nil
                        }
                }
            }
        }
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }

    private var hoverLabel: String {
        guard let hoveredDay else { return "low · high" }
        return "\(hoveredDay.date.formatted(.dateTime.month(.abbreviated).day())) · \(tokenbarTokens(hoveredDay.summary.totalTokens))"
    }
}

struct HourlyHeatmapView: View {
    let hours: [UsageHourOfDay]
    var showAxis = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let item = normalizedHour(hour)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatColor(item?.intensity ?? 0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 15)
                        .overlay {
                            if Calendar.current.component(.hour, from: Date()) == hour {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(TokenBarStyle.input.opacity(0.95), lineWidth: 1)
                            }
                        }
                        .help("\(String(format: "%02d:00", hour)) · \(tokenbarTokens(item?.summary.totalTokens ?? 0))")
                }
            }
            if showAxis {
                HStack {
                    Text("00")
                    Spacer()
                    Text("06")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("18")
                    Spacer()
                    Text("23")
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            }
        }
    }

    private func normalizedHour(_ hour: Int) -> UsageHourOfDay? {
        hours.first { $0.hourOfDay == hour }
    }
}

struct DateRangeControl: View {
    let options: [String] = ["7d", "30d", "90d", "1y", "Custom"]
    @Binding var selection: String
    @State private var showCustomMenu = false
    // CL-P1-011: persist the user's last custom window so reopening the menu
    // shows the previously chosen dates.
    @AppStorage("tokenbar.customRange.from") private var customFrom = "2026-04-15"
    @AppStorage("tokenbar.customRange.to") private var customTo = "2026-05-14"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    if option == "Custom" {
                        showCustomMenu = true
                    } else {
                        selection = option
                        showCustomMenu = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(option == "Custom" ? TokenBarStyle.faint : (selection == option ? Color.white : TokenBarStyle.muted))
                .padding(.horizontal, option == "Custom" ? 9 : 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selection == option ? TokenBarStyle.input.opacity(0.20) : Color.clear)
                )
                .overlay {
                    if selection == option {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(TokenBarStyle.input.opacity(0.25), lineWidth: 1)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        .popover(isPresented: $showCustomMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Range")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Enter ISO dates (yyyy-MM-dd). The aggregator currently honors the implied day count.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    customField("From", text: $customFrom)
                    customField("To", text: $customTo)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showCustomMenu = false }
                        .controlSize(.small)
                    Button("Apply") {
                        selection = "Custom"
                        showCustomMenu = false
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidDateRange)
                }
            }
            .padding(14)
            .frame(width: 240)
            .background(TokenBarGlassBackground())
        }
    }

    private var isValidDateRange: Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let f = formatter.date(from: customFrom),
              let t = formatter.date(from: customTo) else { return false }
        return f <= t
    }

    private func customField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
        }
    }
}

struct RangeBarsCard: View {
    let days: [UsageDay]
    let title: String
    let subtitle: String

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    HeatLegend()
                }
                UsageStackedBarChart(days: days)
                HStack {
                    Text(displayDays.first?.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) ?? "")
                    Spacer()
                    Text("available local buckets")
                    Spacer()
                    Text(displayDays.last?.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) ?? "")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(TokenBarStyle.faint)
            }
        }
    }

    private var displayDays: [UsageDay] {
        if days.isEmpty { return UsageDay.placeholder(count: 30) }
        return days
    }
}

struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("less")
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatColor(Double(level) / 4.0))
                        .frame(width: 11, height: 11)
                }
            }
            Text("more")
        }
        .font(.caption2)
        .foregroundStyle(TokenBarStyle.muted)
    }
}

struct ModelBreakdownTable: View {
    let title: String
    let subtitle: String
    let totalCost: String
    let rows: [TokenBarModelBreakdown]

    var body: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Estimated cost")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(TokenBarStyle.faint)
                        Text(totalCost)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(TokenBarStyle.cost)
                            .monospacedDigit()
                    }
                }

                tableHeader
                if rows.isEmpty {
                    Text("No model attribution available from the current local index.")
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rows.prefix(8)) { row in
                        ModelBreakdownRow(row: row)
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Input · Output · Cache")
                Text("Cache %")
                Text("Tokens")
                Text("Cost").gridColumnAlignment(.trailing)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(TokenBarStyle.faint)
        .padding(.bottom, 6)
        .overlay(Divider().overlay(TokenBarStyle.line), alignment: .bottom)
    }
}

private struct ModelBreakdownRow: View {
    let row: TokenBarModelBreakdown

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                HStack(spacing: 9) {
                    Circle()
                        .fill(TokenBarStyle.agentColor(row.agentName))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Text(row.attribution)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(TokenBarStyle.faint)
                            .lineLimit(1)
                    }
                }
                InputOutputCacheBar(summary: row.summary, height: 8)
                    .frame(minWidth: 180)
                Text(tokenbarPercent(row.cacheRatio))
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.cache)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(TokenBarStyle.cache.opacity(0.10), in: Capsule())
                Text(tokenbarTokens(row.summary.totalTokens))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(TokenBarStyle.foreground)
                Text(tokenbarCurrency(row.cost))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(TokenBarStyle.foreground)
                    .gridColumnAlignment(.trailing)
            }
            .padding(.vertical, 10)
        }
        .overlay(Divider().overlay(TokenBarStyle.line.opacity(0.7)), alignment: .bottom)
    }
}

struct TokenBarDonut: View {
    let slices: [AgentShareSlice]
    // CL-P1-015: when a segment is hovered the other segments fade to 0.6 and
    // a tooltip shows agent + pct. Plain SwiftUI hit-testing on a Circle's
    // stroked arc is coarse, so we attach `.help` to a transparent overlay
    // per slice — a fine compromise without a custom Canvas drawing layer.
    @State private var hoveredAgent: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(TokenBarStyle.line, lineWidth: 14)
            ForEach(Array(slices.prefix(5).enumerated()), id: \.element.id) { index, slice in
                Circle()
                    .trim(from: trimStart(index), to: trimEnd(index))
                    .stroke(TokenBarStyle.agentColor(slice.name),
                            style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(hoveredAgent == nil || hoveredAgent == slice.name ? 1.0 : 0.6)
                    .onHover { isHovering in
                        hoveredAgent = isHovering ? slice.name : (hoveredAgent == slice.name ? nil : hoveredAgent)
                    }
                    .help("\(slice.name) · \(tokenbarPercent(slice.percentage))")
            }
            VStack(spacing: 1) {
                Text(tokenbarTokens(slices.reduce(0) { $0 + $1.totalTokens }))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(hoveredAgent ?? "tokens")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
        }
    }

    private var total: Double {
        max(Double(slices.reduce(0) { $0 + $1.totalTokens }), 1)
    }

    private func trimStart(_ index: Int) -> Double {
        slices.prefix(index).reduce(0) { $0 + Double($1.totalTokens) / total }
    }

    private func trimEnd(_ index: Int) -> Double {
        slices.prefix(index + 1).reduce(0) { $0 + Double($1.totalTokens) / total }
    }
}

// CL-P1-002: replace the bespoke 5-step gradient with alpha-tinted
// systemGreen. Empty cells use `quaternaryLabelColor` so they read as
// "no signal" instead of a faint green.
private func heatColor(_ intensity: Double) -> Color {
    switch intensity {
    case ..<0.08:
        Color(nsColor: .quaternaryLabelColor)
    case ..<0.28:
        Color(nsColor: .systemGreen).opacity(0.30)
    case ..<0.55:
        Color(nsColor: .systemGreen).opacity(0.55)
    case ..<0.82:
        Color(nsColor: .systemGreen).opacity(0.75)
    default:
        Color(nsColor: .systemGreen).opacity(0.95)
    }
}

private extension UsageDay {
    static func placeholder(count: Int) -> [UsageDay] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else { return nil }
            return UsageDay(date: date, summary: UsageSummary(inputTokens: 0, outputTokens: 0, cacheTokens: 0), intensity: 0)
        }
    }
}
