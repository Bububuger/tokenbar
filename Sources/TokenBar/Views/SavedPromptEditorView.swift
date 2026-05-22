import SwiftUI
import TokenBarCore

struct SavedPromptEditorView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.dismiss) private var dismiss

    let target: SavedPromptEditorTarget
    let onClose: () -> Void

    @State private var id: String = UUID().uuidString
    @State private var slug: String = ""
    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var sourcePromptId: String?
    @State private var createdAt: Date = Date()
    @State private var slugManuallyEdited = false
    @State private var previousSlug: String?
    @State private var inlineError: String?
    @State private var isSaving = false

    init(target: SavedPromptEditorTarget, onClose: @escaping () -> Void) {
        self.target = target
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headerTitle)
                .font(.system(size: 16, weight: .semibold))

            field(label: "Title") {
                TextField("e.g. Commit message generator", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: title) { _, newValue in
                        if !slugManuallyEdited {
                            slug = Self.deriveSlug(from: newValue)
                        }
                    }
            }

            field(label: "Slug") {
                TextField("commit-msg", text: $slug)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: slug) { _, _ in
                        slugManuallyEdited = true
                    }
                if !slug.isEmpty && !Self.isValidSlug(slug) {
                    Text("Slug must match ^[a-z0-9][a-z0-9_-]*$")
                        .font(.caption2)
                        .foregroundStyle(TokenBarStyle.cost)
                }
            }

            field(label: "Body") {
                TextEditor(text: $bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(TokenBarStyle.line, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Apply writes plaintext body to ~/.claude/commands/tb/\(slug.isEmpty ? "<slug>" : slug).md.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.muted)
                Text("To trigger as /tb:\(slug.isEmpty ? "<slug>" : slug) in Claude Code, start a new session after Apply.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.muted)
                Text("Variables: use $ARGUMENTS where the user-supplied context should be inserted.")
                    .font(.caption2)
                    .foregroundStyle(TokenBarStyle.faint)
            }

            if let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.cost)
            }

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
                        .background(canApply ? TokenBarStyle.accent.opacity(0.22) : TokenBarStyle.line.opacity(0.5), in: Capsule())
                        .overlay(Capsule().stroke(canApply ? TokenBarStyle.accent.opacity(0.55) : TokenBarStyle.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canApply || isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        .onAppear(perform: load)
    }

    private var headerTitle: String {
        switch target {
        case .new: return "New Prompt Template"
        case .edit: return "Edit Prompt Template"
        case .draft: return "Save as Prompt Template"
        }
    }

    private var canApply: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.isValidSlug(slug)
            && !bodyText.isEmpty
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenBarStyle.faint)
            content()
        }
    }

    private func load() {
        switch target {
        case .new:
            id = UUID().uuidString
            slug = ""
            title = ""
            bodyText = ""
            sourcePromptId = nil
            createdAt = Date()
            slugManuallyEdited = false
            previousSlug = nil
        case .edit(let prompt):
            id = prompt.id
            slug = prompt.slug
            title = prompt.title
            bodyText = prompt.body
            sourcePromptId = prompt.sourcePromptId
            createdAt = prompt.createdAt
            slugManuallyEdited = true
            previousSlug = prompt.slug
        case .draft(let prompt):
            id = prompt.id
            slug = prompt.slug
            title = prompt.title
            bodyText = prompt.body
            sourcePromptId = prompt.sourcePromptId
            createdAt = prompt.createdAt
            slugManuallyEdited = !prompt.slug.isEmpty
            previousSlug = nil
        }
    }

    private func apply() async {
        guard canApply else { return }
        isSaving = true
        defer { isSaving = false }
        inlineError = nil

        let now = Date()
        let prompt = SavedPrompt(
            id: id,
            slug: slug,
            title: title.trimmingCharacters(in: .whitespaces),
            body: bodyText,
            sourcePromptId: sourcePromptId,
            createdAt: createdAt,
            updatedAt: now
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
