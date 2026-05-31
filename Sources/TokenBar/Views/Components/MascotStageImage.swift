import SwiftUI

/// The mascot in the About popover header: a pose image on a radial glow pad
/// that shifts color/shape per stage. Mirrors `.tb-about-pop .mascot-pad`
/// and its `.mascot-bg.pose-*` variants from the design CSS.
struct MascotStageImage: View {
    let stage: VersionUpdateStage
    var size: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    var body: some View {
        ZStack {
            glow
            Image(stage.mascotAsset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .offset(y: bobbing ? -3 : 0)
                .shadow(color: .black.opacity(0.4), radius: 5, y: 4)
        }
        .frame(width: size + 12, height: size * 1.2 + 12)
        .onAppear {
            guard bobbing else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }

    /// Only the resting/idle-ish stages get the gentle bob; transient
    /// action stages carry their own motion energy from the pose itself.
    private var bobbing: Bool {
        !reduceMotion && (stage == .idle || stage == .uptodate || stage == .relaunched)
    }

    @ViewBuilder
    private var glow: some View {
        let pad = size + 12
        switch stage {
        case .available, .ready:
            // brighter lime burst — "something new"
            RadialGradient(
                colors: [VersionPopoverPalette.lime.opacity(0.40), .clear],
                center: .bottom, startRadius: 0, endRadius: pad * 0.9
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .restarting:
            // teal streak pushed to the right — flight energy
            RadialGradient(
                colors: [VersionPopoverPalette.teal.opacity(0.35), .clear],
                center: .trailing, startRadius: 0, endRadius: pad * 0.8
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        default:
            RadialGradient(
                colors: [VersionPopoverPalette.lime.opacity(0.22), .clear],
                center: .bottom, startRadius: 0, endRadius: pad * 0.7
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
