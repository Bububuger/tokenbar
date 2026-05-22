import SwiftUI
import TokenBarCore

struct SavedPromptsListView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var editorTarget: SavedPromptEditorTarget?
    @State private var deletionError: String?
    @State private var showDeletionError = false

    var body: some View {
        // CL-SAVED-1: this route is rendered in ContentView outside the
        // shared ScrollView+LazyVStack chassis (see ContentView.swift).
        // Body stays flat — no Group wrapper, no .id juggling.
        VStack(alignment: .leading, spacing: TokenBarStyle.sectionSpacing) {
            header
            if runtimeModel.savedPrompts.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runtimeModel.savedPrompts) { prompt in
                        row(prompt)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: $editorTarget) { target in
            SavedPromptEditorView(target: target) {
                editorTarget = nil
            }
            .environmentObject(runtimeModel)
        }
        .alert("Couldn't delete prompt template", isPresented: $showDeletionError) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .onChange(of: deletionError) { _, newValue in
            showDeletionError = newValue != nil
        }
        .onAppear {
            TokenBarTelemetry.event(
                "saved_prompts.list.appear",
                metadata: "count=\(runtimeModel.savedPrompts.count)",
                success: true
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt Templates")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Reusable prompt templates exported to ~/.claude/commands/tb/<slug>.md and accessible via `tb prompt get <slug>`.")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            Spacer()
            Button {
                editorTarget = .new
            } label: {
                Label("New", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(TokenBarStyle.accent.opacity(0.18), in: Capsule())
                    .overlay(Capsule().stroke(TokenBarStyle.accent.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No prompt templates yet")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open a project, find a useful prompt in Prompt History, and use \"Save as template\" to promote it. Or click + New to write one from scratch.")
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ prompt: SavedPrompt) -> some View {
        TokenBarCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(prompt.title.isEmpty ? prompt.slug : prompt.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("/tb:\(prompt.slug)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.muted)
                }
                Text(bodyPreview(prompt.body))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TokenBarStyle.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text("Updated \(prompt.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(TokenBarStyle.faint)
                    Spacer()
                    Button("Edit") {
                        editorTarget = .edit(prompt)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.muted)
                    Button("Delete") {
                        Task { await delete(prompt) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(TokenBarStyle.cost)
                }
            }
        }
    }

    private func bodyPreview(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty body)" }
        return trimmed
    }

    private func delete(_ prompt: SavedPrompt) async {
        do {
            try await runtimeModel.deleteSavedPrompt(prompt)
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

enum SavedPromptEditorTarget: Identifiable {
    case new
    case edit(SavedPrompt)
    case draft(SavedPrompt)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let prompt): return "edit-\(prompt.id)"
        case .draft(let prompt): return "draft-\(prompt.id)"
        }
    }

    static func new(from prompt: PromptRecord) -> SavedPromptEditorTarget {
        let now = Date()
        return .draft(SavedPrompt(
            id: UUID().uuidString,
            slug: "",
            title: "",
            body: prompt.content,
            sourcePromptId: prompt.id,
            createdAt: now,
            updatedAt: now
        ))
    }
}
