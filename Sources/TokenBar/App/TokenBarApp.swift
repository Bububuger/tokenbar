import AppKit
import SwiftUI
import TokenBarCore

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtimeModel = TokenBarRuntimeModel.live()
    @AppStorage("tokenbar.theme") private var theme = "Dark"

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(runtimeModel)
                .tokenBarAppAppearance()
                .preferredColorScheme(preferredColorScheme)
                // CL-P2-013: TokenBar's number-heavy layout is built around
                // LTR. Pin the layout direction so RTL locales degrade
                // gracefully instead of mirroring numbers + chart axes.
                .environment(\.layoutDirection, .leftToRight)
        } label: {
            TokenBarStatusItem(runtimeModel: runtimeModel)
        }
        .menuBarExtraStyle(.window)

        // CL-P1-031: allow resizing up to 1600×1200 (and beyond) without
        // breaking the grid; .windowResizability(.contentMinSize) honors the
        // ContentView's minWidth/minHeight as a floor only.
        // CL-P1-032: SwiftUI `Window` with a stable `id` already collapses
        // repeated openWindow(id:"main") calls into a single window.
        Window("TokenBar", id: "main") {
            ContentView()
                .environmentObject(runtimeModel)
                .tokenBarAppAppearance()
                .preferredColorScheme(preferredColorScheme)
                .environment(\.layoutDirection, .leftToRight) // CL-P2-013
                .task { await runtimeModel.bootstrapIfNeeded() }
        }
        .defaultSize(width: 1280, height: 1040)
        .windowResizability(.contentMinSize)
    }

    // Settings.theme drives `preferredColorScheme`. Dark is the default and
    // catch-all for legacy "System" values stored in AppStorage.
    private var preferredColorScheme: ColorScheme? {
        switch theme {
        case "Light":
            return .light
        default:
            return .dark
        }
    }
}

private struct TokenBarAppAppearanceModifier: ViewModifier {
    @AppStorage("tokenbar.theme") private var theme = "Dark"

    func body(content: Content) -> some View {
        content
            .onAppear {
                if theme != "Light" && theme != "Dark" {
                    theme = "Dark"
                }
                apply(theme)
            }
            .onChange(of: theme) { _, newValue in
                apply(newValue)
            }
    }

    private func apply(_ value: String) {
        switch value {
        case "Light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private extension View {
    func tokenBarAppAppearance() -> some View {
        modifier(TokenBarAppAppearanceModifier())
    }
}

private struct TokenBarStatusItem: View {
    @Environment(\.openWindow) private var openWindowAction
    @State private var didHandleLaunchOpen = false
    @AppStorage("tokenbar.menuBarMirrorMode") private var mirrorModeRaw = MenuBarMirrorMode.off.rawValue
    @AppStorage("tokenbar.menuBarPaused") private var isPaused = false
    @AppStorage("tokenbar.pricingOverrides") private var pricingOverridesJSON = "{}"
    @ObservedObject var runtimeModel: TokenBarRuntimeModel
    // CL-P0-025: when the user pauses tracking from the TopRight flyout, the
    // menubar mirror text must freeze at the value visible at the moment of
    // pause and stay there until the user resumes — even if `runtimeModel`
    // keeps producing snapshots in the background.
    @State private var frozenMirror: String?

    var body: some View {
        HStack(spacing: 4) {
            // CL-P0-001: bars cascade-fill bottom → middle → top as today's
            // tokens grow relative to the 30-day peak day. Template image
            // gets auto-tinted by macOS for the active menubar appearance.
            Image(nsImage: TokenBarMenuBarGlyphImage.template(progress: todayFillProgress))
                .renderingMode(.template)
                .overlay(alignment: .topTrailing) {
                    // Priority: failed > stale > update-available. Refresh
                    // problems win the dot because they imply data may lie.
                    if runtimeModel.refreshState == .failed || runtimeModel.refreshState == .stale {
                        Circle()
                            .fill(runtimeModel.refreshState == .failed ? TokenBarStyle.error : TokenBarStyle.warn)
                            .frame(width: 4, height: 4)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    } else if runtimeModel.availableUpdate != nil {
                        Circle()
                            .fill(TokenBarStyle.accent)
                            .frame(width: 4, height: 4)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPaused {
                        HStack(spacing: 1) {
                            Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                            Capsule().fill(TokenBarStyle.warn).frame(width: 1.5, height: 5)
                        }
                        .offset(x: 1, y: 1)
                    }
                }
                .frame(width: TokenBarMenuBarGlyphImage.canvasSize.width, height: TokenBarMenuBarGlyphImage.canvasSize.height)
                .accessibilityLabel(accessibilityStatus)
            // CL-P1-034: when the mirrored value would exceed the menubar
            // budget (~14 mono chars), collapse to glyph-only rather than let
            // macOS truncate mid-number. Glyph remains so users still see
            // status colour.
            if mirrorMode != .off, displayedMirror.count <= 14 {
                // CL-P1-033: design canvas spec is 12.5pt mono (not 11pt).
                Text(displayedMirror)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, mirrorMode == .off ? 1 : 3)
        .task {
            await openMainWindowForLocalVerificationIfNeeded()
        }
        .onAppear { syncFrozenMirror() }
        .onChange(of: isPaused) { _, paused in
            // Capture the value at the moment of pause; clear on resume so we
            // immediately flow back to live snapshots.
            frozenMirror = paused ? liveMirror : nil
        }
        .onChange(of: mirrorModeRaw) { _, _ in
            if isPaused {
                frozenMirror = liveMirror
            }
        }
    }

    private var mirrorMode: MenuBarMirrorMode {
        MenuBarMirrorMode(rawValue: mirrorModeRaw) ?? .off
    }

    /// Today's tokens ÷ the user's 30-day peak day, clamped 0…1. Peak (not
    /// average) keeps the icon expressive for heavy users — full only on a
    /// record day. Today is excluded so a busy "today so far" can't shrink
    /// its own reference. 50K floor prevents instant-full for fresh installs.
    private var todayFillProgress: Double {
        let today = Double(runtimeModel.snapshot.today.totalTokens)
        let prior = runtimeModel.snapshot.last30Days.dropLast()
        let peak = prior.map(\.summary.totalTokens).max() ?? 0
        let baseline = max(Double(peak), 50_000)
        return min(1.0, today / baseline)
    }

    private var displayedMirror: String {
        if isPaused, let frozen = frozenMirror {
            return frozen
        }
        return liveMirror
    }

    private var liveMirror: String {
        tokenbarMirrorValue(
            mode: mirrorMode,
            todayTokens: runtimeModel.snapshot.today.totalTokens,
            todayCost: runtimeModel.popoverSnapshot.todayCost,
            todaySessions: runtimeModel.popoverSnapshot.todaySessionCount
        )
    }

    private func syncFrozenMirror() {
        if isPaused && frozenMirror == nil {
            frozenMirror = liveMirror
        }
    }

    /// CL-P1-025: VoiceOver reads e.g. "TokenBar, today 631K tokens, status: live".
    private var accessibilityStatus: String {
        let tokens = tokenbarTokens(runtimeModel.snapshot.today.totalTokens)
        let stateText: String
        switch runtimeModel.refreshState {
        case .idle:       stateText = "live"
        case .refreshing: stateText = "refreshing"
        case .stale:      stateText = "stale"
        case .failed:     stateText = "failed"
        }
        let pausedSuffix = isPaused ? ", paused" : ""
        return "TokenBar, today \(tokens) tokens, status \(stateText)\(pausedSuffix)"
    }

    private func openMainWindowForLocalVerificationIfNeeded() async {
        guard !didHandleLaunchOpen else { return }
        didHandleLaunchOpen = true

        let environment = ProcessInfo.processInfo.environment
        let requestedWindowID = environment["TOKENBAR_OPEN_WINDOW_ON_LAUNCH"]
            ?? (environment["TOKENBAR_OPEN_MAIN_ON_LAUNCH"] == "1" ? "main" : nil)

        guard let requestedWindowID else {
            return
        }

        switch requestedWindowID {
        case "diagnostics":
            runtimeModel.navigate(to: .diagnostics, source: "launch.environment")
        case "settings":
            runtimeModel.navigate(to: .settings, source: "launch.environment")
        case let value where value.hasPrefix("project:"):
            let projectName = String(value.dropFirst("project:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if projectName.isEmpty {
                runtimeModel.navigate(to: .today, source: "launch.environment")
            } else {
                runtimeModel.openProject(named: projectName, source: "launch.environment")
            }
        default:
            runtimeModel.navigate(to: .today, source: "launch.environment")
        }

        try? await Task.sleep(for: .milliseconds(450))
        openWindowAction(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
