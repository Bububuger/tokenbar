import Foundation

/// Renders a prompt-template body with placeholder substitutions for the
/// preview pane. Frontmatter is stripped (Claude Code strips it before
/// forwarding the body to the model, so the user sees the same thing).
///
/// Shell substitutions are **opt-in** — when `shellRunner` is nil the engine
/// inserts a visible `[shell: !\`cmd\`]` placeholder rather than running
/// arbitrary commands on every keystroke (acceptance §6.3).
public struct PromptTemplatePreview: Sendable {
    /// Mock values for env vars — preview never reads the real environment.
    public static let mockEnvValues: [String: String] = [
        "CLAUDE_SESSION_ID": "[session: preview-stub]",
        "CLAUDE_EFFORT": "[effort: medium]",
        "CLAUDE_SKILL_DIR": "[skill-dir: ~/.claude/skills/preview]",
    ]

    public init() {}

    public func render(
        body: String,
        testArgs: String,
        shellRunner: (@Sendable (String) -> ShellOutcome)? = nil
    ) -> PromptTemplatePreviewResult {
        // 1. Lint the body — gives us the canonical token list.
        let lintResult = PromptTemplateLinter().lint(body)
        let tokens = lintResult.tokens
        let args = Self.tokenize(testArgs)

        var diagnostics: [PromptDiagnostic] = []
        var replacements: [PromptTemplatePreviewResult.Replacement] = []

        // 2. Walk tokens in reverse so each splice keeps earlier ranges valid.
        let ns = body as NSString
        var output = body
        for token in tokens.sorted(by: { $0.range.location > $1.range.location }) {
            switch token.kind {
            case .frontmatter:
                output = Self.replace(in: output, original: ns, range: token.range, with: "")
                replacements.append(.frontmatterStripped(originalRange: token.range))

            case .argumentsToken:
                let value = testArgs
                output = Self.replace(in: output, original: ns, range: token.range, with: value)
                replacements.append(.init(
                    originalRange: token.range,
                    sourceKind: .argumentsToken,
                    value: value
                ))

            case .positionalToken:
                let raw = token.raw  // "$0", "$1", ...
                let index = Self.parseDigit(after: raw.first { $0.isNumber } ?? "0")
                if index < args.count {
                    let value = args[index]
                    output = Self.replace(in: output, original: ns, range: token.range, with: value)
                    replacements.append(.init(
                        originalRange: token.range,
                        sourceKind: .positionalToken,
                        value: value
                    ))
                } else {
                    // Leave the literal in place AND emit a preview-time
                    // diagnostic so the UI can render an inline ⚠ marker.
                    diagnostics.append(PromptDiagnostic(
                        range: token.range,
                        severity: .warning,
                        ruleId: "positional-out-of-range",
                        message: "`\(raw)` needs ≥ \(index + 1) test arg(s); got \(args.count).",
                        suggestion: nil
                    ))
                }

            case .indexedToken:
                // `$ARGUMENTS[N]` — same logic as positional but parse N from inside [].
                guard
                    let lb = token.raw.firstIndex(of: "["),
                    let rb = token.raw.firstIndex(of: "]"),
                    lb < rb,
                    let idx = Int(token.raw[token.raw.index(after: lb)..<rb])
                else { continue }
                if idx < args.count {
                    let value = args[idx]
                    output = Self.replace(in: output, original: ns, range: token.range, with: value)
                    replacements.append(.init(
                        originalRange: token.range,
                        sourceKind: .indexedToken,
                        value: value
                    ))
                } else {
                    diagnostics.append(PromptDiagnostic(
                        range: token.range,
                        severity: .warning,
                        ruleId: "positional-out-of-range",
                        message: "`\(token.raw)` needs ≥ \(idx + 1) test arg(s); got \(args.count).",
                        suggestion: nil
                    ))
                }

            case .envToken:
                // Inner identifier between `${` and `}`.
                let inner = token.raw.dropFirst(2).dropLast()
                let value = Self.mockEnvValues[String(inner)] ?? "[env: \(inner)]"
                output = Self.replace(in: output, original: ns, range: token.range, with: value)
                replacements.append(.init(
                    originalRange: token.range,
                    sourceKind: .envToken,
                    value: value
                ))

            case .shellInlineToken:
                // Extract command between the two backticks.
                let raw = token.raw
                guard
                    let firstTick = raw.firstIndex(of: "`"),
                    let lastTick = raw.lastIndex(of: "`"),
                    firstTick < lastTick
                else { continue }
                let cmd = String(raw[raw.index(after: firstTick)..<lastTick])

                let replacement: String
                if let runner = shellRunner {
                    let outcome = runner(cmd)
                    switch outcome {
                    case .success(let stdout):
                        replacement = stdout.trimmingCharacters(in: .newlines)
                    case .failure(let stderr):
                        replacement = "[shell err: \(stderr.split(separator: "\n").first ?? "")]"
                    case .timeout:
                        replacement = "[shell timeout]"
                    }
                } else {
                    replacement = "[shell: !`\(cmd)`]"
                }
                output = Self.replace(in: output, original: ns, range: token.range, with: replacement)
                replacements.append(.init(
                    originalRange: token.range,
                    sourceKind: .shellInlineToken,
                    value: replacement
                ))

            case .shellBlockToken:
                // For preview we treat block similarly — runner or stub.
                let raw = token.raw
                // Strip the ```! ... ``` fence to get the command body.
                let stripped = raw
                    .replacingOccurrences(of: "```!", with: "", options: [], range: raw.range(of: "```!"))
                    .replacingOccurrences(of: "```", with: "", options: [.backwards])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let replacement: String
                if let runner = shellRunner {
                    let outcome = runner(stripped)
                    switch outcome {
                    case .success(let stdout):
                        replacement = stdout.trimmingCharacters(in: .newlines)
                    case .failure(let stderr):
                        replacement = "[shell err: \(stderr.split(separator: "\n").first ?? "")]"
                    case .timeout:
                        replacement = "[shell timeout]"
                    }
                } else {
                    replacement = "[shell block: \(stripped.count) char(s)]"
                }
                output = Self.replace(in: output, original: ns, range: token.range, with: replacement)
                replacements.append(.init(
                    originalRange: token.range,
                    sourceKind: .shellBlockToken,
                    value: replacement
                ))
            }
        }

        // Replacements list ordered ascending by original location for downstream
        // consumers that want to draw them top-to-bottom.
        replacements.sort { $0.originalRange.location < $1.originalRange.location }
        diagnostics.sort { $0.range.location < $1.range.location }
        return PromptTemplatePreviewResult(
            substituted: output,
            replacements: replacements,
            diagnostics: diagnostics
        )
    }

    // MARK: - Tokenize args (whitespace + simple quote support)

    static func tokenize(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        for c in s {
            if c == "\"" && !inSingle { inDouble.toggle(); continue }
            if c == "'" && !inDouble { inSingle.toggle(); continue }
            if c.isWhitespace && !inDouble && !inSingle {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func parseDigit(after first: Character) -> Int {
        Int(String(first)) ?? 0
    }

    private static func replace(in output: String, original ns: NSString, range: NSRange, with value: String) -> String {
        // Locate the slice in the current `output` by content (offsets shift
        // after each splice). NSRange refers to original positions, so we
        // re-extract the original substring and find/replace once.
        let target = ns.substring(with: range)
        if let r = output.range(of: target) {
            return output.replacingCharacters(in: r, with: value)
        }
        return output
    }
}

// MARK: - Result types

public struct PromptTemplatePreviewResult: Sendable, Hashable {
    public let substituted: String
    public let replacements: [Replacement]
    public let diagnostics: [PromptDiagnostic]

    public init(substituted: String, replacements: [Replacement], diagnostics: [PromptDiagnostic]) {
        self.substituted = substituted
        self.replacements = replacements
        self.diagnostics = diagnostics
    }

    public struct Replacement: Sendable, Hashable {
        public let originalRange: NSRange
        public let sourceKind: PromptTokenKind
        public let value: String

        public init(originalRange: NSRange, sourceKind: PromptTokenKind, value: String) {
            self.originalRange = originalRange
            self.sourceKind = sourceKind
            self.value = value
        }

        static func frontmatterStripped(originalRange: NSRange) -> Replacement {
            Replacement(originalRange: originalRange, sourceKind: .frontmatter, value: "")
        }
    }
}

// MARK: - Shell runner outcome

public enum ShellOutcome: Sendable, Hashable {
    case success(stdout: String)
    case failure(stderr: String)
    case timeout
}
