import SwiftUI
import TokenBarCore

/// Mascot animation view for app update download flow.
/// Displays different visual states based on download progress.
struct MascotDownloadView: View {
    let downloadState: AppUpdateDownloadState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationPhase: CGFloat = 0
    @State private var bounceScale: CGFloat = 1.0

    private enum MascotState {
        case idle
        case downloading(progress: Double)
        case completed
        case failed(message: String)

        init(from downloadState: AppUpdateDownloadState) {
            switch downloadState {
            case .idle:
                self = .idle
            case .downloading(let progress):
                self = .downloading(progress: progress)
            case .completed:
                self = .completed
            case .failed(let message):
                self = .failed(message: message)
            }
        }
    }

    private var mascotState: MascotState {
        MascotState(from: downloadState)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background circle for progress ring
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                    .frame(width: 120, height: 120)

                // Progress ring (only visible during download)
                if case .downloading(let progress) = mascotState {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }

                // Mascot image with animations
                mascotImage
                    .frame(width: 100, height: 100)
                    .offset(y: mascotOffset)
                    .rotationEffect(.degrees(mascotRotation))
                    .scaleEffect(bounceScale)

                // Status badge (success/failure icon)
                if case .completed = mascotState {
                    statusBadge(systemName: "checkmark.circle.fill", color: .green)
                } else if case .failed = mascotState {
                    statusBadge(systemName: "exclamationmark.triangle.fill", color: .red)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)

            // Progress percentage text
            if case .downloading(let progress) = mascotState {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }

            // Error message
            if case .failed(let message) = mascotState {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 120)
                    .transition(.opacity)
            }
        }
        .onChange(of: downloadState) { _, newState in
            handleStateChange(newState)
        }
        .onAppear {
            if case .downloading = mascotState, !reduceMotion {
                startDownloadAnimation()
            }
        }
    }

    // MARK: - Subviews

    private var mascotImage: some View {
        Image("mascot-wave")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private func statusBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 24))
            .foregroundColor(color)
            .background(
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 28, height: 28)
            )
            .offset(x: 40, y: -40)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Animation Properties

    private var mascotOffset: CGFloat {
        guard case .downloading = mascotState, !reduceMotion else { return 0 }
        return sin(animationPhase * .pi * 2) * 8
    }

    private var mascotRotation: Double {
        guard case .downloading = mascotState, !reduceMotion else { return 0 }
        return sin(animationPhase * .pi * 2) * 5
    }

    private var accessibilityLabel: String {
        switch mascotState {
        case .idle:
            return "Update mascot, idle"
        case .downloading(let progress):
            let percentage = Int(progress * 100)
            return "Downloading update, \(percentage) percent complete"
        case .completed:
            return "Update download completed"
        case .failed(let message):
            return "Update download failed: \(message)"
        }
    }

    // MARK: - Animation Logic

    private func startDownloadAnimation() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            animationPhase = 1.0
        }
    }

    private func stopDownloadAnimation() {
        withAnimation(.easeOut(duration: 0.3)) {
            animationPhase = 0
        }
    }

    private func handleStateChange(_ newState: AppUpdateDownloadState) {
        switch newState {
        case .idle:
            stopDownloadAnimation()
            resetBounce()

        case .downloading:
            if !reduceMotion {
                startDownloadAnimation()
            }

        case .completed:
            stopDownloadAnimation()
            if !reduceMotion {
                playBounceAnimation()
            }

        case .failed:
            stopDownloadAnimation()
            if !reduceMotion {
                playShakeAnimation()
            }
        }
    }

    private func playBounceAnimation() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            bounceScale = 1.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                bounceScale = 1.0
            }
        }
    }

    private func playShakeAnimation() {
        let shakeSequence: [CGFloat] = [0, -5, 5, -5, 5, 0]
        for (index, offset) in shakeSequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.easeOut(duration: 0.05)) {
                    animationPhase = offset / 100
                }
            }
        }
    }

    private func resetBounce() {
        withAnimation(.easeOut(duration: 0.2)) {
            bounceScale = 1.0
        }
    }
}

// MARK: - Preview

#Preview("Idle") {
    MascotDownloadView(downloadState: .idle)
        .padding()
        .frame(width: 200, height: 200)
}

#Preview("Downloading 30%") {
    MascotDownloadView(downloadState: .downloading(progress: 0.3))
        .padding()
        .frame(width: 200, height: 200)
}

#Preview("Downloading 75%") {
    MascotDownloadView(downloadState: .downloading(progress: 0.75))
        .padding()
        .frame(width: 200, height: 200)
}

#Preview("Completed") {
    MascotDownloadView(downloadState: .completed(localURL: URL(fileURLWithPath: "/tmp/test.dmg")))
        .padding()
        .frame(width: 200, height: 200)
}

#Preview("Failed") {
    MascotDownloadView(downloadState: .failed(message: "Network connection lost"))
        .padding()
        .frame(width: 200, height: 200)
}
