import SwiftUI
import TokenBarCore

/// The About / version-updater popover (design §00e). Anchored to the "?"
/// button in the sidebar footer. Walks a staged update flow (idle → checking
/// → up-to-date / available → downloading → ready → restarting → relaunched)
/// with a mascot that changes pose per stage, link rows, and a footer.
///
/// The presentation `stage` is derived from the runtime model's published
/// update properties, with a few cosmetic transient states (`checking`,
/// `restarting`, `relaunched`) held locally — they have no backend meaning.
struct AboutVersionPopover: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.openURL) private var openURL

    var onClose: () -> Void

    /// Transient, view-local stages that aren't represented in the model.
    @State private var transient: VersionUpdateStage?
    @State private var didCheckThisSession = false
    @State private var copied = false

    private let repoURL = "https://github.com/Bububuger/tokenbar"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusBanner
            linkRows
            footer
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 318)
        .background(background)
        .preferredColorScheme(.dark)
        .onChange(of: runtimeModel.updateDownloadState) { _, _ in
            // A real download outcome clears the "checking" transient.
            if transient == .checking { transient = nil }
        }
        .onChange(of: runtimeModel.isRestartTheaterActive) { _, active in
            // Theater finished → briefly show "welcome back", then resolve.
            if !active && transient == .restarting {
                transient = .relaunched
                runtimeModel.resetUpdateDownloadState()
                didCheckThisSession = true
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    transient = nil
                }
            }
        }
    }

    // MARK: - Derived stage

    private var stage: VersionUpdateStage {
        if let transient { return transient }
        switch runtimeModel.updateDownloadState {
        case .downloading: return .downloading
        case .completed:   return .ready
        case .failed:      return .failed
        case .idle:
            if runtimeModel.availableUpdate != nil { return .available }
            return didCheckThisSession ? .uptodate : .idle
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var latestVersion: String {
        runtimeModel.availableUpdate?.latestVersion ?? currentVersion
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MascotStageImage(stage: stage, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenBar")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VersionPopoverPalette.textHi)
                HStack(spacing: 6) {
                    Text("v\(currentVersion)")
                        .foregroundStyle(VersionPopoverPalette.lime)
                        .fontWeight(.semibold)
                    Text("·").foregroundStyle(VersionPopoverPalette.text4)
                    Text("build \(buildNumber)")
                        .foregroundStyle(VersionPopoverPalette.text4)
                }
                .font(.system(size: 11.5, design: .monospaced))
                Text("macOS 13+ · Apple Silicon & Intel")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VersionPopoverPalette.text4)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VersionPopoverPalette.text4)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // Debug-only: right-click the header to force the update flow.
        .contextMenu {
            #if DEBUG
            Button("Debug · Force update available") { runtimeModel.debugForceAvailableUpdate() }
            Button("Debug · Simulate download") { runtimeModel.debugSimulateDownload() }
            #endif
        }
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        Group {
            switch stage {
            case .idle:
                bannerRow {
                    indicator(.green)
                    bannerText("You're on the latest version",
                               "Last checked \(tokenbarRelativeTime(runtimeModel.lastUpdateCheckAt))")
                    Spacer(minLength: 8)
                    ghostButton("Check now", systemImage: "arrow.clockwise", action: startCheck)
                }
            case .checking:
                bannerRow {
                    indicator(.spinner)
                    bannerText("Checking for updates…",
                               "Reaching out to github.com/Bububuger/tokenbar")
                }
            case .uptodate:
                bannerRow {
                    indicator(.green)
                    bannerText("You're up to date",
                               "v\(currentVersion) is the newest available · checked just now")
                }
            case .available:
                bannerRow {
                    indicator(.limePulse)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text("Update available")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VersionPopoverPalette.textHi)
                            pill("v\(latestVersion)")
                        }
                        HStack(spacing: 4) {
                            Text(sizeSubtitle)
                            Text("·").foregroundStyle(VersionPopoverPalette.text4)
                            Text("View release notes")
                                .foregroundStyle(VersionPopoverPalette.tealText)
                                .onTapGesture { openURL(runtimeModel.availableUpdate?.releaseURL ?? releasesURL) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(VersionPopoverPalette.text3)
                    }
                    Spacer(minLength: 8)
                    primaryButton("Update", systemImage: "arrow.down") {
                        runtimeModel.downloadAvailableUpdate()
                    }
                }
            case .downloading:
                downloadBlock
            case .ready:
                bannerRow {
                    indicator(.limePulse)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text("Ready to install")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VersionPopoverPalette.textHi)
                            pill("v\(latestVersion)")
                        }
                        Text("TokenBar will quit, install the update, and reopen.")
                            .font(.system(size: 11))
                            .foregroundStyle(VersionPopoverPalette.text3)
                    }
                    Spacer(minLength: 8)
                    primaryButton("Restart", systemImage: "power", action: beginRestart)
                }
            case .restarting:
                bannerRow {
                    indicator(.spinner)
                    bannerText("Restarting TokenBar…",
                               "Closing the current instance. Window will reopen automatically.")
                }
            case .relaunched:
                bannerRow {
                    indicator(.green)
                    bannerText("Welcome back · now on v\(latestVersion)",
                               "See what changed →")
                }
            case .failed:
                bannerRow {
                    indicator(.error)
                    bannerText("Update failed", failureMessage)
                    Spacer(minLength: 8)
                    ghostButton("Retry", systemImage: "arrow.clockwise") {
                        runtimeModel.downloadAvailableUpdate()
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func bannerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
    }

    private var downloadBlock: some View {
        let progress = currentProgress
        let metrics = runtimeModel.downloadMetrics
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                HStack(spacing: 8) {
                    spinnerView(size: 11)
                    Text("Downloading v\(latestVersion)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VersionPopoverPalette.textHi)
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VersionPopoverPalette.tealText)
            }
            progressBar(progress)
            HStack(spacing: 6) {
                if let m = metrics {
                    Text("\(fmtMB(m.bytesDone)) / \(fmtMB(m.bytesTotal)) MB")
                    Text("·").foregroundStyle(VersionPopoverPalette.text4)
                    Text("\(fmtSpeed(m.bytesPerSec)) MB/s")
                    Text("·").foregroundStyle(VersionPopoverPalette.text4)
                    Text("\(fmtETA(m.secondsRemaining)) remaining")
                } else {
                    Text("starting…")
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(VersionPopoverPalette.text3)
        }
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(
                        colors: [VersionPopoverPalette.teal, VersionPopoverPalette.lime],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * progress))
                    .shadow(color: VersionPopoverPalette.lime.opacity(0.35), radius: 4)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Link rows

    private var linkRows: some View {
        VStack(spacing: 1) {
            linkRow(systemImage: "chevron.left.forwardslash.chevron.right",
                    label: "GitHub repository") {
                openURL(URL(string: repoURL)!)
            }
            linkRow(systemImage: "book", label: "Documentation") {
                openURL(URL(string: "\(repoURL)#readme")!)
            }
            linkRow(systemImage: "sparkles", label: "What's new") {
                openURL(releasesURL)
            }
            linkRow(systemImage: "exclamationmark.bubble", label: "Report an issue") {
                openURL(URL(string: "\(repoURL)/issues")!)
            }
        }
    }

    private func linkRow(systemImage: String, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(VersionPopoverPalette.text3)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(VersionPopoverPalette.text2)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(VersionPopoverPalette.text4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("MIT · free for personal use")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(VersionPopoverPalette.text4)
            Spacer()
            Button(action: copyBuild) {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(copied ? "copied" : buildNumber)
                        .font(.system(size: 10.5, design: .monospaced))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(copied ? VersionPopoverPalette.lime : VersionPopoverPalette.text3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(VersionPopoverPalette.hairline, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    // MARK: - Indicators / buttons

    private enum IndicatorKind { case green, limePulse, spinner, error }

    @ViewBuilder
    private func indicator(_ kind: IndicatorKind) -> some View {
        switch kind {
        case .green:
            statusDot(VersionPopoverPalette.ok, pulse: false)
        case .limePulse:
            statusDot(VersionPopoverPalette.lime, pulse: true)
        case .error:
            statusDot(VersionPopoverPalette.error, pulse: false)
        case .spinner:
            spinnerView(size: 14)
        }
    }

    private func statusDot(_ color: Color, pulse: Bool) -> some View {
        StatusDot(color: color, pulse: pulse).frame(width: 22, height: 22)
    }

    private func spinnerView(size: CGFloat) -> some View {
        SpinnerRing(color: VersionPopoverPalette.teal).frame(width: size, height: size)
    }

    private func bannerText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VersionPopoverPalette.textHi)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(VersionPopoverPalette.text3)
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(VersionPopoverPalette.lime)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(VersionPopoverPalette.lime.opacity(0.18))
                    .overlay(Capsule().stroke(VersionPopoverPalette.lime.opacity(0.40), lineWidth: 1))
            )
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(Color(red: 0x0E / 255, green: 0x18 / 255, blue: 0x20 / 255))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [VersionPopoverPalette.lime, VersionPopoverPalette.limeDeep],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: VersionPopoverPalette.lime.opacity(0.25), radius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 11.5, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(VersionPopoverPalette.text2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Backgrounds

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [VersionPopoverPalette.inkTop, VersionPopoverPalette.inkBot],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VersionPopoverPalette.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var bannerBackground: some View {
        switch stage {
        case .available, .ready:
            RoundedRectangle(cornerRadius: 10)
                .fill(VersionPopoverPalette.lime.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VersionPopoverPalette.lime.opacity(0.28), lineWidth: 1))
        case .downloading:
            RoundedRectangle(cornerRadius: 10)
                .fill(VersionPopoverPalette.teal.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VersionPopoverPalette.teal.opacity(0.22), lineWidth: 1))
        default:
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.025))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    // MARK: - Actions

    private func startCheck() {
        transient = .checking
        Task {
            async let check = runtimeModel.checkForUpdatesNow()
            try? await Task.sleep(for: .milliseconds(1200))
            let succeeded = await check
            if succeeded {
                didCheckThisSession = true
            }
            transient = nil
        }
    }

    private func beginRestart() {
        runtimeModel.restartTargetVersion = latestVersion
        transient = .restarting
        withAnimation { runtimeModel.isRestartTheaterActive = true }
        runtimeModel.performInstallAndRelaunch()
    }

    private func copyBuild() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("v\(currentVersion) (\(buildNumber))", forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    // MARK: - Formatting helpers

    private var currentProgress: Double {
        if case .downloading(let p) = runtimeModel.updateDownloadState { return p }
        return 0
    }

    private var sizeSubtitle: String {
        if let bytes = runtimeModel.availableUpdate?.dmgSizeBytes {
            return "\(fmtMB(bytes)) MB · released recently"
        }
        return "released recently"
    }

    private var failureMessage: String {
        if case .failed(let m) = runtimeModel.updateDownloadState { return m }
        return "Something went wrong."
    }

    private var releasesURL: URL { URL(string: "\(repoURL)/releases/latest")! }

    private func fmtMB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
    private func fmtSpeed(_ bytesPerSec: Double) -> String {
        String(format: "%.1f", bytesPerSec / 1_048_576)
    }
    private func fmtETA(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite else { return "—" }
        if s < 1 { return "< 1s" }
        return "\(Int(s.rounded()))s"
    }
}

// MARK: - Small reusable subviews

/// A status dot with an optional slow pulse (mirrors `.ind .d.pulse`).
private struct StatusDot: View {
    let color: Color
    let pulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 5)
            .scaleEffect(pulse && on && !reduceMotion ? 1.35 : 1)
            .opacity(pulse && on && !reduceMotion ? 0.6 : 1)
            .onAppear {
                guard pulse && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// A spinning ring (mirrors `.ind.spin .ring`).
private struct SpinnerRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// Link-row hover highlight (replaces CSS `:hover` background).
private struct HoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hovering || configuration.isPressed ? 0.05 : 0))
            )
            .onHover { hovering = $0 }
    }
}
