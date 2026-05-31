import SwiftUI

/// The presentation stage of the About/version-updater popover. This is a
/// *UI* state machine distinct from the backend `AppUpdateDownloadState`:
/// `checking`, `restarting`, and `relaunched` are cosmetic transient states
/// the popover drives itself; the rest derive from the runtime model's
/// published update properties. Mirrors the design mockup's `STAGE_POSE`
/// (tmp/tokenbar-video/design/version-popover.jsx).
enum VersionUpdateStage: Equatable {
    case idle
    case checking
    case uptodate
    case available
    case downloading
    case ready
    case restarting
    case relaunched
    case failed

    /// Asset-catalog imageset name for the mascot pose shown at this stage.
    /// All poses ship as `mascot-*.imageset` rendered from the design's
    /// `window.Mascot` SVG component.
    var mascotAsset: String {
        switch self {
        case .idle, .relaunched: return "mascot-wave"
        case .checking, .failed: return "mascot-think"
        case .uptodate:          return "mascot-tongue"
        case .available:         return "mascot-spark"
        case .downloading:       return "mascot-run"
        case .ready:             return "mascot-excited"
        case .restarting:        return "mascot-fly"
        }
    }
}

/// Design-fixed palette for the About popover. The popover is always dark
/// (ink gradient) regardless of system appearance, so these are literal hex
/// values from the mockup rather than `TokenBarStyle`'s adaptive colors.
enum VersionPopoverPalette {
    static let inkTop = Color(red: 0x12 / 255, green: 0x24 / 255, blue: 0x33 / 255) // #122433
    static let inkBot = Color(red: 0x0D / 255, green: 0x1A / 255, blue: 0x24 / 255) // #0D1A24
    static let lime = Color(red: 0xD4 / 255, green: 0xF7 / 255, blue: 0x6A / 255)   // #D4F76A
    static let limeDeep = Color(red: 0xB6 / 255, green: 0xE0 / 255, blue: 0x41 / 255) // #B6E041
    static let teal = Color(red: 0x22 / 255, green: 0xC7 / 255, blue: 0xC6 / 255)   // #22C7C6
    static let tealText = Color(red: 0x9B / 255, green: 0xE6 / 255, blue: 0xE2 / 255) // #9BE6E2
    static let ok = Color(red: 0x6F / 255, green: 0xD6 / 255, blue: 0x8E / 255)     // #6FD68E
    static let error = Color(red: 0xF4 / 255, green: 0x55 / 255, blue: 0x5F / 255)  // #F4555F
    static let textHi = Color.white
    static let text2 = Color.white.opacity(0.72)
    static let text3 = Color.white.opacity(0.52)
    static let text4 = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.09)
    static let restartBg = Color(red: 0x05 / 255, green: 0x0B / 255, blue: 0x11 / 255) // #050B11
}
