import SwiftUI
import TokenBarCore

/// Right-hand 40% pane in the editor — takes the current body + a test
/// argument string and renders what Claude Code would actually receive.
/// Shell substitutions are rendered as a visible `[shell: !\`cmd\`]` stub —
/// the preview never executes real commands.
struct PromptTemplatePreviewPane: View {
    let bodyText: String
    @Binding var testArgs: String

    private let preview = PromptTemplatePreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Test args").font(.caption.bold()).foregroundStyle(.secondary)
                TextField("Type a sample argument…", text: $testArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Divider().opacity(0.4)

            ScrollView {
                let result = preview.render(body: bodyText, testArgs: testArgs)
                Text(result.substituted.isEmpty ? "(empty)" : result.substituted)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if !result.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.diagnostics, id: \.range) { d in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(d.message).font(.caption)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(TokenBarStyle.line, lineWidth: 1)
        )
    }
}
