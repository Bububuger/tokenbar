import SwiftUI

struct TokenBarIndexingStatusCard: View {
    let state: TokenBarIndexingState
    var compact = false
    var showActions = true
    var onPause: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?

    var body: some View {
        TokenBarCard(padding: compact ? 12 : TokenBarStyle.cardPadding) {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                header
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .tint(TokenBarStyle.accent)

                HStack(spacing: 10) {
                    Label(summaryText, systemImage: iconName)
                        .font(.caption)
                        .foregroundStyle(TokenBarStyle.muted)
                        .lineLimit(1)
                    Spacer()
                    if state.isPartial {
                        Text("partial")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TokenBarStyle.warn)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(TokenBarStyle.warn.opacity(0.12), in: Capsule())
                    }
                }

                VStack(spacing: 6) {
                    ForEach(state.sources) { source in
                        sourceRow(source)
                    }
                }

                if showActions {
                    actions
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                Text(subtitle)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(TokenBarStyle.muted)
                    .lineLimit(compact ? 1 : 2)
            }
            Spacer()
            Text("\(Int((state.progress * 100).rounded()))%")
                .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TokenBarStyle.faint)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if state.isActive {
                Button("Pause") {
                    onPause?()
                }
                .controlSize(.small)
            } else if state.phase == .paused || state.phase == .failed {
                Button("Retry") {
                    onRetry?()
                }
                .controlSize(.small)
            }

            Spacer()

            if let onOpenDiagnostics {
                Button("Open Diagnostics") {
                    onOpenDiagnostics()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sourceRow(_ source: TokenBarIndexingSourceState) -> some View {
        HStack(spacing: 9) {
            Image(systemName: sourceIcon(source.phase))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sourceColor(source.phase))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.sourceName)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                Text(source.rootPath)
                    .font(.system(size: compact ? 9.5 : 10.5, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(sourceStatusText(source))
                    .font(.system(size: compact ? 10 : 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(sourceColor(source.phase))
                    .lineLimit(1)
                if !compact, let message = source.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.faint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }

    private var title: String {
        switch state.phase {
        case .idle:
            "Local index"
        case .discovering, .indexing:
            "Building local index"
        case .paused:
            "Indexing paused"
        case .completed:
            "Local index ready"
        case .failed:
            "Indexing needs attention"
        }
    }

    private var subtitle: String {
        if let active = state.activeSourceName, state.isActive {
            return "Scanning \(active). Token totals are partial until indexing finishes."
        }
        switch state.phase {
        case .paused:
            return "Resume when you want TokenBar to continue reading local agent history."
        case .completed:
            return "Indexed \(state.eventsIndexed.formatted()) events from default local sources."
        case .failed:
            return state.message ?? "Some sources could not be read. Details are in Diagnostics."
        default:
            return "Codex, Claude Code, and Hermes are read locally on this Mac."
        }
    }

    private var summaryText: String {
        var parts = [
            "\(state.checkedFiles.formatted()) files checked",
            "\(state.sources.count) sources",
        ]
        if let cpuBudgetPercent = state.cpuBudgetPercent {
            parts.append("~\(formatCPU(cpuBudgetPercent)) CPU")
        }
        if let startedAt = state.startedAt {
            let ended = state.endedAt ?? Date()
            parts.append("\(formatElapsed(ended.timeIntervalSince(startedAt))) elapsed")
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
            "externaldrive.connected.to.line.below"
        }
    }

    private func sourceStatusText(_ source: TokenBarIndexingSourceState) -> String {
        switch source.phase {
        case .pending:
            "pending"
        case .scanning:
            source.discoveredFileCount > 0 ? "\(source.discoveredFileCount.formatted()) files" : "scanning"
        case .indexed:
            source.eventsIndexed > 0 ? "\(source.eventsIndexed.formatted()) events" : "indexed"
        case .skipped:
            "skipped"
        case .failed:
            "failed"
        }
    }

    private func sourceIcon(_ phase: TokenBarIndexingSourcePhase) -> String {
        switch phase {
        case .pending:
            "circle"
        case .scanning:
            "arrow.triangle.2.circlepath"
        case .indexed:
            "checkmark.circle"
        case .skipped:
            "minus.circle"
        case .failed:
            "xmark.circle"
        }
    }

    private func sourceColor(_ phase: TokenBarIndexingSourcePhase) -> Color {
        switch phase {
        case .pending:
            TokenBarStyle.faint
        case .scanning:
            TokenBarStyle.accent
        case .indexed:
            TokenBarStyle.cache
        case .skipped:
            TokenBarStyle.muted
        case .failed:
            TokenBarStyle.error
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "<1s"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private func formatCPU(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }
}
