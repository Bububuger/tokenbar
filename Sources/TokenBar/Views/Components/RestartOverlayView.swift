import SwiftUI

/// Full-bleed "restart theater" overlay (design §00e RestartOverlay). Mounted
/// at the ContentView root so it covers the whole window. Purely cosmetic: a
/// 5-step checklist ticks while the mascot flies off carrying the new-version
/// parcel, then flies back waving. The real install action (open the DMG)
/// already fired when the user clicked Restart — this is just personality.
struct RestartOverlayView: View {
    let version: String
    /// Called once the theater finishes; the host clears `isRestartTheaterActive`.
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0          // 0…4 install steps
    @State private var flyingAway = false
    @State private var welcomeBack = false

    private let steps = [
        "Installing v",
        "Verifying signature",
        "Sealing app bundle",
        "Closing the current instance",
        "Reopening window",
    ]

    var body: some View {
        ZStack {
            background
            VStack(spacing: 28) {
                mascotFlight
                headline
                if !welcomeBack { stepList }
            }
            .frame(maxWidth: 560)
            .padding(40)
        }
        .task { await runTheater() }
    }

    // MARK: - Sequence

    private func runTheater() async {
        if reduceMotion {
            // No flight; just tick the steps faster, then finish.
            for i in 0..<steps.count {
                withAnimation(.easeInOut(duration: 0.2)) { phase = i }
                try? await Task.sleep(for: .milliseconds(450))
            }
            withAnimation { welcomeBack = true }
            try? await Task.sleep(for: .milliseconds(900))
            finish()
            return
        }

        withAnimation(.easeIn(duration: 2.4)) { flyingAway = true }
        for i in 0..<steps.count {
            withAnimation(.easeInOut(duration: 0.3)) { phase = i }
            try? await Task.sleep(for: .milliseconds(600))
        }
        // Welcome-back: mascot flies in from the left, waving.
        withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
            welcomeBack = true
            flyingAway = false
        }
        try? await Task.sleep(for: .milliseconds(1100))
        finish()
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.25)) { onDone() }
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            VersionPopoverPalette.restartBg
            RadialGradient(colors: [VersionPopoverPalette.teal.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [VersionPopoverPalette.lime.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.5, y: 0.85), startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    private var mascotFlight: some View {
        ZStack {
            // speed streaks trailing the mascot during flight
            if flyingAway && !reduceMotion {
                StreakTrail()
                    .frame(width: 200, height: 80)
                    .offset(x: -120)
            }
            ZStack(alignment: .topTrailing) {
                MascotStageImage(stage: welcomeBack ? .relaunched : .restarting, size: 130)
                if !welcomeBack {
                    parcel.offset(x: 14, y: 8)
                }
            }
        }
        .frame(width: 200, height: 200)
        .offset(x: flightOffsetX, y: flyingAway ? -40 : 0)
        .rotationEffect(.degrees(flyingAway ? 8 : 0))
        .opacity(flyingAway ? 0 : 1)
    }

    private var flightOffsetX: CGFloat {
        if flyingAway { return 720 }
        if welcomeBack { return 0 }
        return 0
    }

    private var parcel: some View {
        VStack(spacing: 0) {
            Text("v\(version)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(VersionPopoverPalette.lime)
        }
        .frame(width: 40, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(red: 0x2A/255, green: 0x18/255, blue: 0x10/255),
                                              Color(red: 0x1A/255, green: 0x0F/255, blue: 0x09/255)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
        )
        .rotationEffect(.degrees(-8))
    }

    private var headline: some View {
        VStack(spacing: 8) {
            if welcomeBack {
                Text("welcome back")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("tokenbar · now on v\(version)")
                    .font(.system(size: 13))
                    .foregroundStyle(VersionPopoverPalette.text3)
            } else {
                Text(currentStepLabel + "…")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("don't worry — your window will reopen automatically")
                    .font(.system(size: 13))
                    .foregroundStyle(VersionPopoverPalette.text3)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var currentStepLabel: String {
        let raw = steps[min(phase, steps.count - 1)]
        return raw == "Installing v" ? "Installing v\(version)" : raw
    }

    private var stepList: some View {
        VStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, raw in
                let label = raw == "Installing v" ? "Installing v\(version)" : raw
                let state: StepState = i < phase ? .done : (i == phase ? .active : .wait)
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(numFill(state)).frame(width: 18, height: 18)
                        Text("\(i + 1)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(numText(state))
                    }
                    Text(label)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(rowText(state))
                    Spacer()
                    stepStateIcon(state)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(rowFill(state))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(rowStroke(state), lineWidth: 1))
                )
            }
        }
        .frame(maxWidth: 380)
    }

    private enum StepState { case done, active, wait }

    @ViewBuilder
    private func stepStateIcon(_ s: StepState) -> some View {
        switch s {
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(VersionPopoverPalette.teal)
        case .active:
            SmallSpinner(color: VersionPopoverPalette.lime).frame(width: 11, height: 11)
        case .wait:
            Circle().fill(Color.white.opacity(0.18)).frame(width: 5, height: 5)
        }
    }

    private func numFill(_ s: StepState) -> Color {
        switch s {
        case .done: return VersionPopoverPalette.teal.opacity(0.18)
        case .active: return VersionPopoverPalette.lime.opacity(0.20)
        case .wait: return Color.white.opacity(0.04)
        }
    }
    private func numText(_ s: StepState) -> Color {
        switch s {
        case .done: return VersionPopoverPalette.teal
        case .active: return VersionPopoverPalette.lime
        case .wait: return VersionPopoverPalette.text4
        }
    }
    private func rowText(_ s: StepState) -> Color {
        switch s {
        case .done: return VersionPopoverPalette.tealText
        case .active: return .white
        case .wait: return VersionPopoverPalette.text3
        }
    }
    private func rowFill(_ s: StepState) -> Color {
        switch s {
        case .done: return VersionPopoverPalette.teal.opacity(0.06)
        case .active: return VersionPopoverPalette.lime.opacity(0.08)
        case .wait: return Color.white.opacity(0.025)
        }
    }
    private func rowStroke(_ s: StepState) -> Color {
        switch s {
        case .done: return VersionPopoverPalette.teal.opacity(0.20)
        case .active: return VersionPopoverPalette.lime.opacity(0.30)
        case .wait: return Color.white.opacity(0.04)
        }
    }
}

/// Horizontal speed streaks behind the flying mascot.
private struct StreakTrail: View {
    @State private var slide = false
    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [.clear, VersionPopoverPalette.teal.opacity(0.65)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 60, height: 2)
                    .offset(x: slide ? -180 : 0, y: CGFloat(i) * 14 - 28)
                    .opacity(slide ? 0 : 1)
                    .animation(.linear(duration: 0.6).repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.05), value: slide)
            }
        }
        .onAppear { slide = true }
    }
}

private struct SmallSpinner: View {
    let color: Color
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) { spin = true } }
    }
}
