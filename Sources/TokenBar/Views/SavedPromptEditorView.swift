import SwiftUI
import TokenBarCore

/// v2 — Variables-First editor for prompt-template bodies. Acceptance doc:
/// docs/refactor-2026-05-24-prompt-editor-v2.md
struct SavedPromptEditorView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.dismiss) private var dismiss

    let target: SavedPromptEditorTarget
    let onClose: () -> Void

    // MARK: - Persisted fields

    @State private var id: String = UUID().uuidString
    @State private var slug: String = ""
    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var argumentHint: String = ""
    @State private var allowedTools: Set<String> = ["Read", "Bash"]
    @State private var sourcePromptId: String?
    @State private var createdAt: Date = Date()

    // MARK: - UI state

    @State private var slugManuallyEdited = false
    @State private var previousSlug: String?
    @State private var inlineError: String?
    @State private var isSaving = false
    @State private var debouncedBody: String = ""
    @State private var lintTask: Task<Void, Never>?
    @State private var cachedLint: PromptLintResult = .init(tokens: [], diagnostics: [])
    @State private var testArgs: String = ""
    @State private var showExamples = false
    @State private var pendingExample: PromptExample?

    private static let allTools = ["Read", "Bash", "Write", "Edit", "Grep"]

    init(target: SavedPromptEditorTarget, onClose: @escaping () -> Void) {
        self.target = target
        self.onClose = onClose
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headerTitle).font(.system(size: 16, weight: .semibold))

            frontmatterFields

            HStack(alignment: .top, spacing: 12) {
                editorColumn
                PromptTemplatePreviewPane(
                    bodyText: bodyText,
                    testArgs: $testArgs
                )
                .frame(maxWidth: .infinity)
            }

            statusBar

            if let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.cost)
            }

            footer
        }
        .padding(20)
        .frame(minWidth: 940, minHeight: 620)
        .onAppear(perform: load)
        .onChange(of: bodyText) { _, newValue in
            scheduleLint(for: newValue)
        }
        .sheet(isPresented: $showExamples) {
            examplesSheet
        }
        .alert(
            "Replace current body?",
            isPresented: Binding(
                get: { pendingExample != nil },
                set: { if !$0 { pendingExample = nil } }
            ),
            presenting: pendingExample
        ) { ex in
            Button("Cancel", role: .cancel) { pendingExample = nil }
            Button("Replace", role: .destructive) {
                bodyText = ex.bodyPreview
                pendingExample = nil
                showExamples = false
            }
        } message: { _ in
            Text("This will overwrite the body you currently have in the editor.")
        }
    }

    // MARK: - Frontmatter fields row

    private var frontmatterFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                fieldColumn(label: "Title", width: nil) {
                    TextField("e.g. Commit message generator", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: title) { _, newValue in
                            if !slugManuallyEdited {
                                slug = Self.deriveSlug(from: newValue)
                            }
                        }
                }
                fieldColumn(label: "Slug", width: 220) {
                    TextField("commit-msg", text: $slug)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: slug) { _, _ in
                            slugManuallyEdited = true
                        }
                    if !slug.isEmpty && !Self.isValidSlug(slug) {
                        Text("must match ^[a-z0-9][a-z0-9_-]*$")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.cost)
                    } else if !slug.isEmpty {
                        Text("→ /tbar:\(slug)")
                            .font(.caption2)
                            .foregroundStyle(TokenBarStyle.muted)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                fieldColumn(label: "Hint (argument-hint)", width: nil) {
                    TextField("<file or diff>", text: $argumentHint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                fieldColumn(label: "Allowed tools", width: 380) {
                    HStack(spacing: 8) {
                        ForEach(Self.allTools, id: \.self) { tool in
                            Toggle(tool, isOn: Binding(
                                get: { allowedTools.contains(tool) },
                                set: { include in
                                    if include { allowedTools.insert(tool) }
                                    else { allowedTools.remove(tool) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Editor column (left 60%)

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BODY")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)

            PromptBodyEditor(
                text: $bodyText,
                lintResult: cachedLint,
                ghostText: bodyText.isEmpty ? "Try: \"Review $ARGUMENTS for security issues\"" : ""
            )
            .frame(minHeight: 280)
            .padding(2)
            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))

            HStack(spacing: 8) {
                PromptVariablePicker(onInsert: insertAtCaret(_:))
                Button {
                    showExamples = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lightbulb")
                        Text("Examples")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(TokenBarStyle.line, lineWidth: 1))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Writes to ~/.claude/commands/tbar/\(slug.isEmpty ? "<slug>" : slug).md.")
                    .font(.caption2).foregroundStyle(TokenBarStyle.muted)
                Text("Slash trigger: /tbar:\(slug.isEmpty ? "<slug>" : slug) (start a new Claude Code session after Apply).")
                    .font(.caption2).foregroundStyle(TokenBarStyle.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        let errs = cachedLint.errorCount
        let warns = cachedLint.warningCount
        let isClean = errs == 0 && warns == 0
        return HStack(spacing: 8) {
            if isClean {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("\(errs) error\(errs == 1 ? "" : "s") · \(warns) warning\(warns == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(errs > 0 ? TokenBarStyle.cost : TokenBarStyle.muted)
            }
            Spacer()
        }
    }

    // MARK: - Footer (Cancel / Apply)

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(TokenBarStyle.muted)
            Spacer()
            Button {
                Task { await apply() }
            } label: {
                Text(isSaving ? "Applying…" : "Apply")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        canApply ? TokenBarStyle.accent.opacity(0.22) : TokenBarStyle.line.opacity(0.5),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(canApply ? TokenBarStyle.accent.opacity(0.55) : TokenBarStyle.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canApply || isSaving)
            .help(applyTooltip)
        }
    }

    private var applyTooltip: String {
        if let first = cachedLint.diagnostics.first(where: { $0.severity == .error }) {
            return first.message
        }
        if cachedLint.warningCount > 0 {
            return "\(cachedLint.warningCount) warning(s) — Apply will ask for confirmation."
        }
        return "Save and sync to ~/.claude/commands/tbar/\(slug).md"
    }

    // MARK: - Examples drawer

    private var examplesSheet: some View {
        let examples = PromptExamplesLoader.load()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Examples").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { showExamples = false }.buttonStyle(.plain)
            }
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(examples) { ex in
                        Button {
                            if bodyText.isEmpty {
                                bodyText = ex.bodyPreview
                                showExamples = false
                            } else {
                                pendingExample = ex
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ex.title).font(.system(size: 13, weight: .semibold))
                                Text(ex.description).font(.caption).foregroundStyle(.secondary)
                                Text(ex.bodyPreview)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(3)
                                    .foregroundStyle(TokenBarStyle.muted)
                                    .padding(.top, 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    // MARK: - Layout helper

    private func fieldColumn<Content: View>(label: String, width: CGFloat?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
            content()
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Derived state

    private var canApply: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.isValidSlug(slug)
            && !bodyText.isEmpty
            && cachedLint.errorCount == 0
    }

    private var headerTitle: String {
        switch target {
        case .new: return "New Prompt Template"
        case .edit: return "Edit Prompt Template"
        case .draft: return "Save as Prompt Template"
        }
    }

    // MARK: - Behaviour

    private func insertAtCaret(_ snippet: String) {
        // Best-effort caret-aware insertion: in SwiftUI we don't have the
        // current selection, so append to end. (NSTextView delegate can
        // override this later — keep behavior visible for now.)
        bodyText.append(snippet)
    }

    private func scheduleLint(for body: String) {
        lintTask?.cancel()
        lintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            if Task.isCancelled { return }
            cachedLint = PromptTemplateLinter().lint(body)
        }
    }

    private func load() {
        switch target {
        case .new:
            id = UUID().uuidString
            slug = ""
            title = ""
            bodyText = ""
            argumentHint = ""
            allowedTools = ["Read", "Bash"]
            sourcePromptId = nil
            createdAt = Date()
            slugManuallyEdited = false
            previousSlug = nil
        case .edit(let prompt):
            apply(prompt: prompt, manualSlug: true, previousSlug: prompt.slug)
        case .draft(let prompt):
            apply(prompt: prompt, manualSlug: !prompt.slug.isEmpty, previousSlug: nil)
        }
        cachedLint = PromptTemplateLinter().lint(bodyText)
    }

    private func apply(prompt: SavedPrompt, manualSlug: Bool, previousSlug: String?) {
        id = prompt.id
        slug = prompt.slug
        title = prompt.title
        bodyText = prompt.body
        argumentHint = prompt.argumentHint ?? ""
        allowedTools = Set(prompt.allowedTools.isEmpty ? ["Read", "Bash"] : prompt.allowedTools)
        sourcePromptId = prompt.sourcePromptId
        createdAt = prompt.createdAt
        slugManuallyEdited = manualSlug
        self.previousSlug = previousSlug
    }

    private func apply() async {
        guard canApply else { return }
        // Warning gate: 1+ warnings → confirm before writing.
        if cachedLint.warningCount > 0 {
            let alert = NSAlert()
            alert.messageText = "\(cachedLint.warningCount) warning(s)."
            alert.informativeText = "Apply anyway?"
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        isSaving = true
        defer { isSaving = false }
        inlineError = nil

        let now = Date()
        // Preserve declared tool order for the round-trip test.
        let toolsList = Self.allTools.filter { allowedTools.contains($0) }
        let prompt = SavedPrompt(
            id: id,
            slug: slug,
            title: title.trimmingCharacters(in: .whitespaces),
            body: bodyText,
            sourcePromptId: sourcePromptId,
            createdAt: createdAt,
            updatedAt: now,
            argumentHint: argumentHint.isEmpty ? nil : argumentHint,
            allowedTools: toolsList
        )
        do {
            try await runtimeModel.applySavedPrompt(prompt, previousSlug: previousSlug)
            dismiss()
            onClose()
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("unique") || message.contains("constraint") {
                inlineError = "Slug \"\(slug)\" is already used by another saved prompt."
            } else {
                inlineError = error.localizedDescription
            }
        }
    }

    // MARK: - Slug helpers (unchanged from v1)

    static func deriveSlug(from title: String) -> String {
        let lowered = title.lowercased()
        let normalized = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(normalized)
            .split(whereSeparator: { $0 == "-" })
            .joined(separator: "-")
        return collapsed
    }

    static func isValidSlug(_ slug: String) -> Bool {
        guard let first = slug.first else { return false }
        let firstScalars = first.unicodeScalars
        let startsValid = firstScalars.allSatisfy { scalar in
            CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
        guard startsValid else { return false }
        let body = slug.dropFirst()
        return body.unicodeScalars.allSatisfy { scalar in
            CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "-"
                || scalar == "_"
        }
    }
}
