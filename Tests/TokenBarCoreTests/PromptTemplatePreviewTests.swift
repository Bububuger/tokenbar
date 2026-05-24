import Foundation
import Testing
@testable import TokenBarCore

struct PromptTemplatePreviewTests {
    @Test
    func argumentsReplacedWithTestArgs() {
        let r = PromptTemplatePreview().render(
            body: "Review $ARGUMENTS for issues",
            testArgs: "my-file.py"
        )
        #expect(r.substituted == "Review my-file.py for issues")
        #expect(r.replacements.contains { $0.sourceKind == .argumentsToken && $0.value == "my-file.py" })
    }

    @Test
    func positionalSplitsOnWhitespace() {
        let r = PromptTemplatePreview().render(
            body: "Compare $0 vs $1",
            testArgs: "alice bob"
        )
        #expect(r.substituted == "Compare alice vs bob")
    }

    @Test
    func positionalQuotedArgPreservesSpaces() {
        let r = PromptTemplatePreview().render(
            body: "Open $0 with $1",
            testArgs: "\"my file.py\" vim"
        )
        #expect(r.substituted == "Open my file.py with vim")
    }

    @Test
    func indexedAndPositionalRenderSameValue() {
        let a = PromptTemplatePreview().render(body: "$1", testArgs: "a b c")
        let b = PromptTemplatePreview().render(body: "$ARGUMENTS[1]", testArgs: "a b c")
        #expect(a.substituted == b.substituted)
        #expect(a.substituted == "b")
    }

    @Test
    func positionalOutOfRangeEmitsDiagnostic() {
        let r = PromptTemplatePreview().render(body: "$1", testArgs: "only-one")
        #expect(r.diagnostics.contains { $0.ruleId == "positional-out-of-range" })
        // Token is preserved literally when out of range.
        #expect(r.substituted == "$1")
    }

    @Test
    func envVarsReplacedWithMockValues() {
        let r = PromptTemplatePreview().render(
            body: "Session: ${CLAUDE_SESSION_ID}, Effort: ${CLAUDE_EFFORT}",
            testArgs: ""
        )
        #expect(r.substituted.contains("[session: preview-stub]"))
        #expect(r.substituted.contains("[effort: medium]"))
    }

    @Test
    func shellInlineStubbedWhenNoRunner() {
        let r = PromptTemplatePreview().render(
            body: "Branch: !`git rev-parse HEAD`",
            testArgs: ""
        )
        #expect(r.substituted.contains("[shell: !`git rev-parse HEAD`]"))
    }

    @Test
    func shellInlineUsesRunnerWhenProvided() {
        let r = PromptTemplatePreview().render(
            body: "Branch: !`git rev-parse HEAD`",
            testArgs: "",
            shellRunner: { _ in .success(stdout: "feat/test-branch") }
        )
        #expect(r.substituted == "Branch: feat/test-branch")
    }

    @Test
    func shellInlineFailureMessage() {
        let r = PromptTemplatePreview().render(
            body: "Out: !`bad-cmd`",
            testArgs: "",
            shellRunner: { _ in .failure(stderr: "command not found\nline2") }
        )
        #expect(r.substituted.contains("[shell err: command not found]"))
    }

    @Test
    func shellInlineTimeout() {
        let r = PromptTemplatePreview().render(
            body: "Out: !`sleep 10`",
            testArgs: "",
            shellRunner: { _ in .timeout }
        )
        #expect(r.substituted.contains("[shell timeout]"))
    }

    @Test
    func escapedArgumentsIsLiteral() {
        let r = PromptTemplatePreview().render(
            body: "Keep \\$ARGUMENTS literal",
            testArgs: "should-not-replace"
        )
        #expect(r.substituted.contains("\\$ARGUMENTS"))
        #expect(r.substituted.contains("should-not-replace") == false)
    }

    @Test
    func frontmatterStrippedFromOutput() {
        let body = "---\ndescription: hi\n---\nHello $ARGUMENTS"
        let r = PromptTemplatePreview().render(body: body, testArgs: "world")
        #expect(r.substituted.contains("description") == false)
        #expect(r.substituted.contains("Hello world"))
    }

    @Test
    func emptyArgsLeavesPositionalsAsWarnings() {
        let r = PromptTemplatePreview().render(body: "$0 $1 $2", testArgs: "")
        let outOf = r.diagnostics.filter { $0.ruleId == "positional-out-of-range" }
        #expect(outOf.count == 3)
    }

    @Test
    func tokenizeRespectsSingleQuotes() {
        let tokens = PromptTemplatePreview.tokenize("'with space' bare")
        #expect(tokens == ["with space", "bare"])
    }
}
