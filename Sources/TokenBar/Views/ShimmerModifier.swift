import SwiftUI

/// CL-P1-010: 1.4s shimmer mask applied to bootstrap placeholders so the UI
/// reads as "loading" rather than "stuck at zero". Respects Reduce Motion —
/// falls back to a static low-opacity skeleton.
struct TokenBarShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceMotion {
            content.opacity(0.45)
        } else {
            content
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.white.opacity(0.18), location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: UnitPoint(x: phase, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.5, y: 0.5)
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                )
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1.5
                    }
                }
        }
    }
}

extension View {
    /// Apply the TokenBar bootstrap shimmer effect.
    func tokenBarShimmer(active: Bool) -> some View {
        modifier(TokenBarShimmer(active: active))
    }
}
