import Foundation

public enum TokenBarNumberFormatting {
    /// Staged compact format used wherever a token count is rendered.
    /// Stages follow PRD#EC-04 / CHECKLIST CL-P0-028:
    ///   value < 1_000           → "NNN"   (no suffix)
    ///   value < 1_000_000       → "N[.N]K"
    ///   value < 1_000_000_000   → "N[.N]M"
    ///   value < 999_500_000_000 → "N[.N]B"
    ///   value ≥ 999_500_000_000 → ">999B"
    /// Negative inputs are clamped to 0 (defense in depth — parsers already clamp
    /// at ingest, see CL-P0-029).
    public static func stagedTokens(_ value: Int) -> String {
        let clamped = max(0, value)
        let dValue = Double(clamped)
        switch clamped {
        case ..<1_000:
            return "\(clamped)"
        case ..<1_000_000:
            return compact(dValue / 1_000, suffix: "K")
        case ..<1_000_000_000:
            return compact(dValue / 1_000_000, suffix: "M")
        case ..<999_500_000_000:
            return compact(dValue / 1_000_000_000, suffix: "B")
        default:
            return ">999B"
        }
    }

    public static func compactTokens(_ value: Int, fractionDigits: Int = 2) -> String {
        let clamped = max(0, value)
        let dValue = Double(clamped)
        switch clamped {
        case ..<1_000:
            return "\(clamped)"
        case ..<1_000_000:
            return fixed(dValue / 1_000, suffix: "K", fractionDigits: fractionDigits)
        case ..<1_000_000_000:
            return fixed(dValue / 1_000_000, suffix: "M", fractionDigits: fractionDigits)
        case ..<999_500_000_000:
            return fixed(dValue / 1_000_000_000, suffix: "B", fractionDigits: fractionDigits)
        default:
            return ">999B"
        }
    }

    /// Clamp a parsed token integer to a non-negative value while signalling
    /// whether the original input was negative. Used by parsers so they can
    /// emit a warning when raw data is malformed (CL-P0-029).
    public static func clampNonNegative(_ value: Int) -> (value: Int, wasNegative: Bool) {
        if value < 0 {
            return (0, true)
        }
        return (value, false)
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        // Prefer one decimal when result rounds below 10 (e.g. 1.5K, 9.9K),
        // drop decimals once the number is double-digit or larger (15K, 100K).
        let rounded10 = (value * 10).rounded() / 10
        if rounded10 < 10 {
            let formatted = rounded10.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(rounded10))"
                : String(format: "%.1f", rounded10)
            return "\(formatted)\(suffix)"
        }
        return "\(Int(value.rounded()))\(suffix)"
    }

    private static func fixed(_ value: Double, suffix: String, fractionDigits: Int) -> String {
        let digits = max(0, min(fractionDigits, 3))
        return String(format: "%.\(digits)f%@", value, suffix)
    }
}
