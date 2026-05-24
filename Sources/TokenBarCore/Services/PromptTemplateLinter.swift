import Foundation

// MARK: - Public types

/// Categories of recognized substitutions inside a prompt-template body.
/// 7 kinds per the v2 acceptance doc — keep the count in sync with §2.1.
public enum PromptTokenKind: String, Sendable, Hashable, CaseIterable {
    case frontmatter
    case argumentsToken          // bare `$ARGUMENTS`
    case positionalToken         // `$0`, `$1`, … `$9`
    case indexedToken            // `$ARGUMENTS[N]`
    case envToken                // `${CLAUDE_SESSION_ID}` etc.
    case shellInlineToken        // `` !`cmd` ``
    case shellBlockToken         // ```!\n…\n```
}

public struct PromptToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: PromptTokenKind
    public let raw: String

    public init(range: NSRange, kind: PromptTokenKind, raw: String) {
        self.range = range
        self.kind = kind
        self.raw = raw
    }
}

public enum PromptDiagnosticSeverity: String, Sendable, Hashable {
    case error
    case warning
}

/// One lint finding tied to a span in the body. The 5 rule ids are listed in
/// §2.2 of the acceptance doc — the test suite asserts each one fires.
public struct PromptDiagnostic: Sendable, Hashable {
    public let range: NSRange
    public let severity: PromptDiagnosticSeverity
    public let ruleId: String
    public let message: String
    public let suggestion: String?

    public init(
        range: NSRange,
        severity: PromptDiagnosticSeverity,
        ruleId: String,
        message: String,
        suggestion: String? = nil
    ) {
        self.range = range
        self.severity = severity
        self.ruleId = ruleId
        self.message = message
        self.suggestion = suggestion
    }
}

public struct PromptLintResult: Sendable, Hashable {
    public let tokens: [PromptToken]
    public let diagnostics: [PromptDiagnostic]

    public var errorCount: Int { diagnostics.lazy.filter { $0.severity == .error }.count }
    public var warningCount: Int { diagnostics.lazy.filter { $0.severity == .warning }.count }
    public var isClean: Bool { diagnostics.isEmpty }

    public init(tokens: [PromptToken], diagnostics: [PromptDiagnostic]) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }
}

// MARK: - The linter

/// Pure-function linter for Claude Code slash-command body text. No I/O, no
/// state — every call returns a fresh [`PromptLintResult`]. The acceptance
/// criterion is < 100ms on a 10K-char body and ≥ 90% coverage.
public struct PromptTemplateLinter: Sendable {
    /// Environment variables Claude Code substitutes at invocation time.
    public static let knownEnvVars: Set<String> = [
        "CLAUDE_SESSION_ID",
        "CLAUDE_EFFORT",
        "CLAUDE_SKILL_DIR",
    ]

    public init() {}

    public func lint(_ body: String) -> PromptLintResult {
        var tokens: [PromptToken] = []
        var diagnostics: [PromptDiagnostic] = []
        let ns = body as NSString
        let total = ns.length

        // 1. Frontmatter token (must start at offset 0 to count).
        let frontmatterEnd = scanFrontmatter(ns: ns, total: total, tokens: &tokens)

        // The rest of the body — everything after the frontmatter — is the
        // "user content" zone where variables and shell substitutions live.
        let scanRange = NSRange(location: frontmatterEnd, length: total - frontmatterEnd)

        // 2. Shell tokens FIRST so their ranges win against `$` matchers
        //    accidentally hitting characters inside a `!\`cmd\`` payload.
        scanShellBlock(ns: ns, range: scanRange, tokens: &tokens)
        scanShellInline(ns: ns, range: scanRange, body: body, tokens: &tokens, diagnostics: &diagnostics)

        // 3. Variables — but skip ranges already inside a shell token.
        let shellRanges = tokens.filter {
            $0.kind == .shellInlineToken || $0.kind == .shellBlockToken
        }.map(\.range)
        scanVariables(
            body: body,
            ns: ns,
            range: scanRange,
            excluding: shellRanges,
            tokens: &tokens,
            diagnostics: &diagnostics
        )

        tokens.sort { $0.range.location < $1.range.location }
        diagnostics.sort { $0.range.location < $1.range.location }
        return PromptLintResult(tokens: tokens, diagnostics: diagnostics)
    }

    // MARK: - Frontmatter

    private func scanFrontmatter(ns: NSString, total: Int, tokens: inout [PromptToken]) -> Int {
        guard total >= 4 else { return 0 }
        // Frontmatter must start with `---\n` at offset 0.
        if ns.substring(with: NSRange(location: 0, length: 4)) != "---\n" { return 0 }
        // Find closing `\n---\n` or `\n---` at EOF.
        let searchStart = 4
        let searchRange = NSRange(location: searchStart, length: total - searchStart)
        let pattern = "\\n---(\\n|$)"
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: ns as String, range: searchRange)
        else {
            return 0
        }
        let end = match.range.location + match.range.length
        let frontmatterRange = NSRange(location: 0, length: end)
        let raw = ns.substring(with: frontmatterRange)
        tokens.append(PromptToken(range: frontmatterRange, kind: .frontmatter, raw: raw))
        return end
    }

    // MARK: - Shell

    /// Multi-line ```! …``` fenced block. Greedy across newlines.
    private func scanShellBlock(ns: NSString, range: NSRange, tokens: inout [PromptToken]) {
        let pattern = "```!\\s*\\n[\\s\\S]*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: ns as String, range: range) { match, _, _ in
            guard let match else { return }
            tokens.append(PromptToken(
                range: match.range,
                kind: .shellBlockToken,
                raw: ns.substring(with: match.range)
            ))
        }
    }

    /// Inline `!\`cmd\``. Backtick must be on the same line.
    /// If the opening `!\`` has no closing backtick before the line break,
    /// emit `unclosed-shell-backtick` diagnostic.
    private func scanShellInline(
        ns: NSString,
        range: NSRange,
        body: String,
        tokens: inout [PromptToken],
        diagnostics: inout [PromptDiagnostic]
    ) {
        // Step a: well-formed pairs `!\`...\``. Backtick can't be escaped.
        let okPattern = "(?<!\\\\)!`[^`\\n]*`"
        if let regex = try? NSRegularExpression(pattern: okPattern) {
            regex.enumerateMatches(in: ns as String, range: range) { match, _, _ in
                guard let match else { return }
                // Skip if range overlaps an existing shell-block token.
                if rangeOverlapsAny(match.range, tokens.map(\.range)) { return }
                tokens.append(PromptToken(
                    range: match.range,
                    kind: .shellInlineToken,
                    raw: ns.substring(with: match.range)
                ))
            }
        }

        // Step b: orphan `!\`` with no closing backtick on the line → error.
        let badPattern = "(?<!\\\\)!`[^`\\n]*(?:\\n|$)"
        if let regex = try? NSRegularExpression(pattern: badPattern) {
            regex.enumerateMatches(in: ns as String, range: range) { match, _, _ in
                guard let match else { return }
                if rangeOverlapsAny(match.range, tokens.map(\.range)) { return }
                // Trim trailing \n from the reported range so the squiggle
                // stops at the last character of the line.
                var r = match.range
                let last = ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1))
                if last == "\n" { r.length -= 1 }
                diagnostics.append(PromptDiagnostic(
                    range: r,
                    severity: .error,
                    ruleId: "unclosed-shell-backtick",
                    message: "Shell substitution `!\\`…\\`` is missing the closing backtick on this line.",
                    suggestion: "Add a matching backtick before the line break."
                ))
            }
        }
    }

    // MARK: - Variables

    private func scanVariables(
        body: String,
        ns: NSString,
        range: NSRange,
        excluding shellRanges: [NSRange],
        tokens: inout [PromptToken],
        diagnostics: inout [PromptDiagnostic]
    ) {
        // Single big regex with named alternatives covers every `$…` form we
        // care about. We post-classify each match by inspecting groups.
        //
        //   1. `$ARGUMENTS[N]`               → indexedToken
        //   2. `$ARGUMENTS`  (not followed by [ or word char)
        //                                      → argumentsToken
        //   3. `$<digit>`     (followed by word boundary)
        //                                      → positionalToken
        //   4. `${IDENT}`                     → envToken (lookup) or warnings
        //   5. `$ARGUMENT`    (singular, no S/digit/[ after)
        //                                      → diagnostic singular-argument
        //   6. `$IDENT`        (uppercase or mixed)
        //                                      → diagnostic unknown-variable
        let patterns: [(name: String, regex: String)] = [
            ("indexed",   #"(?<!\\)\$ARGUMENTS\[(\d+)\]"#),
            ("arguments", #"(?<!\\)\$ARGUMENTS(?![A-Za-z0-9_\[])"#),
            ("positional", #"(?<!\\)\$\d(?![A-Za-z0-9_])"#),
            ("env",       #"(?<!\\)\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#),
            ("singular",  #"(?<!\\)\$ARGUMENT(?![A-Za-z0-9_\[])"#),
            ("unknownU",  #"(?<!\\)\$[A-Z][A-Z0-9_]*(?![A-Za-z0-9_])"#),
        ]

        var seen = Set<Int>()  // start offsets we've already claimed

        for (name, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: body, range: range) { match, _, _ in
                guard let match else { return }
                let r = match.range
                if seen.contains(r.location) { return }
                if rangeOverlapsAny(r, shellRanges) { return }
                let raw = ns.substring(with: r)

                switch name {
                case "indexed":
                    seen.insert(r.location)
                    tokens.append(PromptToken(range: r, kind: .indexedToken, raw: raw))

                case "arguments":
                    seen.insert(r.location)
                    tokens.append(PromptToken(range: r, kind: .argumentsToken, raw: raw))

                case "positional":
                    seen.insert(r.location)
                    tokens.append(PromptToken(range: r, kind: .positionalToken, raw: raw))

                case "env":
                    seen.insert(r.location)
                    // Inner identifier is group 1.
                    let innerRange = match.range(at: 1)
                    let inner = ns.substring(with: innerRange)
                    if PromptTemplateLinter.knownEnvVars.contains(inner) {
                        tokens.append(PromptToken(range: r, kind: .envToken, raw: raw))
                    } else if inner.uppercased() == inner.lowercased() {
                        // No letters at all — treat as unknown.
                        diagnostics.append(.unknownVariable(range: r, raw: raw))
                    } else if inner != inner.uppercased() && inner.uppercased().hasPrefix("CLAUDE_") {
                        // Lowercase / mixed-case Claude env (e.g. `${claude_session_id}`)
                        // → fixable lowercase-env warning.
                        diagnostics.append(.lowercaseEnv(range: r, raw: raw, fix: inner.uppercased()))
                    } else {
                        diagnostics.append(.unknownVariable(range: r, raw: raw))
                    }

                case "singular":
                    seen.insert(r.location)
                    diagnostics.append(.singularArgument(range: r, raw: raw))

                case "unknownU":
                    // Avoid double-claiming for $ARGUMENTS already handled above.
                    if seen.contains(r.location) { return }
                    seen.insert(r.location)
                    diagnostics.append(.unknownVariable(range: r, raw: raw))

                default:
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private func rangeOverlapsAny(_ r: NSRange, _ others: [NSRange]) -> Bool {
        for o in others where NSIntersectionRange(r, o).length > 0 {
            return true
        }
        return false
    }
}

// MARK: - Diagnostic factories (centralized for stable wording)

extension PromptDiagnostic {
    static func singularArgument(range: NSRange, raw: String) -> PromptDiagnostic {
        PromptDiagnostic(
            range: range,
            severity: .error,
            ruleId: "singular-argument",
            message: "Use `$ARGUMENTS` (plural) — `$ARGUMENT` is not substituted by Claude Code.",
            suggestion: "$ARGUMENTS"
        )
    }

    static func unknownVariable(range: NSRange, raw: String) -> PromptDiagnostic {
        PromptDiagnostic(
            range: range,
            severity: .warning,
            ruleId: "unknown-variable",
            message: "`\(raw)` is not a recognized Claude Code substitution and will be passed through literally.",
            suggestion: nil
        )
    }

    static func lowercaseEnv(range: NSRange, raw: String, fix uppercased: String) -> PromptDiagnostic {
        PromptDiagnostic(
            range: range,
            severity: .warning,
            ruleId: "lowercase-env",
            message: "Environment variable names are case-sensitive — use `${\(uppercased)}` (uppercase).",
            suggestion: "${\(uppercased)}"
        )
    }
}
