import Foundation
import Testing
@testable import TokenBarCore

struct PromptTemplateLinterTests {
    // MARK: - Frontmatter

    @Test
    func frontmatterRecognizedAtOffsetZero() {
        let body = "---\ndescription: hi\n---\nbody"
        let result = PromptTemplateLinter().lint(body)
        let fm = result.tokens.first { $0.kind == .frontmatter }
        #expect(fm != nil)
        #expect(fm?.range.location == 0)
    }

    @Test
    func frontmatterNotRecognizedIfNotAtStart() {
        let body = "leading\n---\nx: y\n---\nbody"
        let result = PromptTemplateLinter().lint(body)
        #expect(result.tokens.contains { $0.kind == .frontmatter } == false)
    }

    @Test
    func noFrontmatterEmitsNoFrontmatterToken() {
        let result = PromptTemplateLinter().lint("just body $ARGUMENTS")
        #expect(result.tokens.contains { $0.kind == .frontmatter } == false)
    }

    // MARK: - argumentsToken (positive + negative)

    @Test
    func argumentsTokenIsRecognized() {
        let result = PromptTemplateLinter().lint("Review $ARGUMENTS for issues")
        #expect(result.tokens.contains { $0.kind == .argumentsToken } == true)
        #expect(result.errorCount == 0)
        #expect(result.warningCount == 0)
    }

    @Test
    func argumentsTokenNotRecognizedWhenFollowedByLetter() {
        // $ARGUMENTSx should NOT be argumentsToken (it's an unknown variable).
        let result = PromptTemplateLinter().lint("Hi $ARGUMENTSx")
        #expect(result.tokens.contains { $0.kind == .argumentsToken } == false)
    }

    @Test
    func argumentsTokenSkippedWhenEscaped() {
        let result = PromptTemplateLinter().lint("Literal \\$ARGUMENTS goes through")
        #expect(result.tokens.contains { $0.kind == .argumentsToken } == false)
        #expect(result.isClean)
    }

    @Test
    func argumentsTokenWorksInCJKContext() {
        let body = "看下这个需求：$ARGUMENTS，已经实现了"
        let result = PromptTemplateLinter().lint(body)
        let token = result.tokens.first { $0.kind == .argumentsToken }
        #expect(token != nil)
        // Range should be byte-accurate (NSRange honors UTF-16 units; the
        // substring at that range should be exactly "$ARGUMENTS").
        let ns = body as NSString
        if let token { #expect(ns.substring(with: token.range) == "$ARGUMENTS") }
    }

    // MARK: - indexedToken

    @Test
    func indexedTokenRecognized() {
        let r = PromptTemplateLinter().lint("$ARGUMENTS[0] then $ARGUMENTS[12]")
        let indexed = r.tokens.filter { $0.kind == .indexedToken }
        #expect(indexed.count == 2)
    }

    @Test
    func indexedTokenPrefersOverArguments() {
        let r = PromptTemplateLinter().lint("$ARGUMENTS[3]")
        // It should be classified as indexed, NOT arguments, NOT positional.
        #expect(r.tokens.contains { $0.kind == .indexedToken } == true)
        #expect(r.tokens.contains { $0.kind == .argumentsToken } == false)
    }

    // MARK: - positionalToken

    @Test
    func positionalTokenRecognizedDollarZero() {
        let r = PromptTemplateLinter().lint("Compare $0 vs $1")
        let pos = r.tokens.filter { $0.kind == .positionalToken }
        #expect(pos.count == 2)
    }

    @Test
    func positionalTokenNotMatchedWhenFollowedByDigit() {
        // $12 is not a positional placeholder ($1 followed by 2). We only
        // accept single-digit positional tokens.
        let r = PromptTemplateLinter().lint("Cost $12 USD")
        let pos = r.tokens.filter { $0.kind == .positionalToken }
        #expect(pos.isEmpty)
    }

    // MARK: - envToken

    @Test
    func envTokenSessionIdRecognized() {
        let r = PromptTemplateLinter().lint("Session: ${CLAUDE_SESSION_ID}")
        #expect(r.tokens.contains { $0.kind == .envToken } == true)
        #expect(r.diagnostics.isEmpty)
    }

    @Test
    func envTokenAllThreeKnownAccepted() {
        let body = "${CLAUDE_SESSION_ID} ${CLAUDE_EFFORT} ${CLAUDE_SKILL_DIR}"
        let r = PromptTemplateLinter().lint(body)
        #expect(r.tokens.filter { $0.kind == .envToken }.count == 3)
        #expect(r.diagnostics.isEmpty)
    }

    @Test
    func envTokenUnknownIsWarning() {
        let r = PromptTemplateLinter().lint("${WHATEVER_X}")
        #expect(r.tokens.contains { $0.kind == .envToken } == false)
        #expect(r.diagnostics.contains { $0.ruleId == "unknown-variable" })
    }

    // MARK: - shellInlineToken

    @Test
    func shellInlineMatchedAsToken() {
        let r = PromptTemplateLinter().lint("Branch is !`git rev-parse HEAD`")
        #expect(r.tokens.contains { $0.kind == .shellInlineToken } == true)
        #expect(r.diagnostics.isEmpty)
    }

    @Test
    func shellInlineDoesNotRequireOpeningSpace() {
        let r = PromptTemplateLinter().lint("foo!`ls`bar")
        #expect(r.tokens.contains { $0.kind == .shellInlineToken } == true)
    }

    @Test
    func shellInlineSkippedWhenEscaped() {
        let r = PromptTemplateLinter().lint("Literal \\!`uname` shows backtick")
        #expect(r.tokens.contains { $0.kind == .shellInlineToken } == false)
    }

    // MARK: - shellBlockToken

    @Test
    func shellBlockFenceRecognized() {
        let body = """
        Preamble.
        ```!
        git log -5 --oneline
        git diff
        ```
        Tail.
        """
        let r = PromptTemplateLinter().lint(body)
        #expect(r.tokens.contains { $0.kind == .shellBlockToken } == true)
    }

    // MARK: - Rule: singular-argument (ERROR)

    @Test
    func singularArgumentTriggersError() {
        let r = PromptTemplateLinter().lint("Hi $ARGUMENT, do it.")
        let d = r.diagnostics.first { $0.ruleId == "singular-argument" }
        #expect(d != nil)
        #expect(d?.severity == .error)
        #expect(d?.suggestion == "$ARGUMENTS")
    }

    @Test
    func singularArgumentDoesNotFireForPlural() {
        let r = PromptTemplateLinter().lint("Hi $ARGUMENTS, do it.")
        #expect(r.diagnostics.contains { $0.ruleId == "singular-argument" } == false)
    }

    @Test
    func singularArgumentDoesNotFireForIndexed() {
        let r = PromptTemplateLinter().lint("$ARGUMENTS[0]")
        #expect(r.diagnostics.contains { $0.ruleId == "singular-argument" } == false)
    }

    // MARK: - Rule: unknown-variable (WARNING)

    @Test
    func unknownVariableTriggersWarning() {
        let r = PromptTemplateLinter().lint("Hello $FOOBAR")
        let d = r.diagnostics.first { $0.ruleId == "unknown-variable" }
        #expect(d != nil)
        #expect(d?.severity == .warning)
    }

    @Test
    func unknownVariableDoesNotFireForArguments() {
        let r = PromptTemplateLinter().lint("Hello $ARGUMENTS")
        #expect(r.diagnostics.contains { $0.ruleId == "unknown-variable" } == false)
    }

    @Test
    func unknownVariableDoesNotFireForPositional() {
        let r = PromptTemplateLinter().lint("Try $5")
        #expect(r.diagnostics.contains { $0.ruleId == "unknown-variable" } == false)
    }

    // MARK: - Rule: lowercase-env (WARNING)

    @Test
    func lowercaseEnvTriggersWarning() {
        let r = PromptTemplateLinter().lint("oops ${claude_session_id}")
        let d = r.diagnostics.first { $0.ruleId == "lowercase-env" }
        #expect(d != nil)
        #expect(d?.severity == .warning)
        #expect(d?.suggestion == "${CLAUDE_SESSION_ID}")
    }

    @Test
    func lowercaseEnvDoesNotFireForUppercase() {
        let r = PromptTemplateLinter().lint("ok ${CLAUDE_SESSION_ID}")
        #expect(r.diagnostics.contains { $0.ruleId == "lowercase-env" } == false)
    }

    // MARK: - Rule: unclosed-shell-backtick (ERROR)

    @Test
    func unclosedShellBacktickTriggersError() {
        let r = PromptTemplateLinter().lint("oops !`git status\nnext line")
        let d = r.diagnostics.first { $0.ruleId == "unclosed-shell-backtick" }
        #expect(d != nil)
        #expect(d?.severity == .error)
    }

    @Test
    func closedShellBacktickDoesNotFire() {
        let r = PromptTemplateLinter().lint("ok !`git status`\nnext line")
        #expect(r.diagnostics.contains { $0.ruleId == "unclosed-shell-backtick" } == false)
    }

    // MARK: - Inside-shell variables are ignored

    @Test
    func variablesInsideShellInlineAreIgnored() {
        // The `$ARGUMENTS` text inside the backticked shell command should
        // NOT be picked up as a separate token (the shell binary handles it).
        let r = PromptTemplateLinter().lint("Run !`echo $ARGUMENTS`")
        #expect(r.tokens.contains { $0.kind == .shellInlineToken } == true)
        let argTokens = r.tokens.filter { $0.kind == .argumentsToken }
        #expect(argTokens.isEmpty)
    }

    @Test
    func variablesInsideShellBlockAreIgnored() {
        let body = """
        ```!
        echo $ARGUMENT  # would normally flag singular
        ```
        """
        let r = PromptTemplateLinter().lint(body)
        #expect(r.tokens.contains { $0.kind == .shellBlockToken } == true)
        #expect(r.diagnostics.contains { $0.ruleId == "singular-argument" } == false)
    }

    // MARK: - Counts & ordering

    @Test
    func errorAndWarningCountsAccurate() {
        let r = PromptTemplateLinter().lint("$ARGUMENT $FOOBAR ${claude_effort}")
        #expect(r.errorCount == 1)        // singular-argument
        #expect(r.warningCount == 2)      // unknown + lowercase-env
        #expect(r.isClean == false)
    }

    @Test
    func diagnosticsSortedByLocation() {
        let r = PromptTemplateLinter().lint("$FOO middle $BAR end $BAZ")
        let locs = r.diagnostics.map(\.range.location)
        #expect(locs == locs.sorted())
    }

    @Test
    func cleanBodyHasNoDiagnostics() {
        let body = "Review $ARGUMENTS for issues in $0 vs $1 with !`git diff`"
        let r = PromptTemplateLinter().lint(body)
        #expect(r.isClean)
    }

    // MARK: - Performance (acceptance §2.3)

    @Test
    func lintsTenKiloCharBodyUnderHundredMs() {
        // Build a 10K char body with variables sprinkled throughout.
        var pieces: [String] = []
        for i in 0..<200 {
            pieces.append("Line \(i): some normal text with $ARGUMENTS and $0 and ${CLAUDE_SESSION_ID}.")
        }
        let body = pieces.joined(separator: "\n")
        #expect(body.count >= 10_000)
        let start = Date()
        _ = PromptTemplateLinter().lint(body)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1, "Linter took \(elapsed)s on 10K body, must be < 100ms")
    }

    // MARK: - Token range fidelity (extra)

    @Test
    func tokenRangeSubstringIsExactLiteral() {
        let body = "Use $ARGUMENTS to capture"
        let r = PromptTemplateLinter().lint(body)
        let ns = body as NSString
        for t in r.tokens {
            #expect(ns.substring(with: t.range) == t.raw)
        }
    }

    @Test
    func multiplePositionalAndArgumentsInOneBody() {
        let r = PromptTemplateLinter().lint("$ARGUMENTS then $0 and $9 and $ARGUMENTS[5]")
        let kinds = r.tokens.map(\.kind)
        #expect(kinds.contains(.argumentsToken))
        #expect(kinds.filter { $0 == .positionalToken }.count == 2)
        #expect(kinds.contains(.indexedToken))
    }
}
