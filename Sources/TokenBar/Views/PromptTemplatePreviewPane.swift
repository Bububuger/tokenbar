import SwiftUI
import TokenBarCore

/// Right-hand 40% pane in the editor — takes the current body + a test
/// argument string and renders what Claude Code would actually receive.
/// Shell substitution is opt-in (acceptance §6.3).
struct PromptTemplatePreviewPane: View {
    let bodyText: String
    @Binding var testArgs: String
    @Binding var shellRunEnabled: Bool

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
                let result = preview.render(
                    body: bodyText,
                    testArgs: testArgs,
                    shellRunner: shellRunEnabled ? Self.makeShellRunner() : nil
                )
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

            Toggle(isOn: $shellRunEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: shellRunEnabled ? "play.fill" : "play")
                    Text("Run shell in preview")
                        .font(.caption)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(10)
        .background(TokenBarStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(TokenBarStyle.line, lineWidth: 1)
        )
    }

    /// Foreground shell runner with a 5-second timeout. Lives in this view so
    /// it never executes unless the user has explicitly toggled the switch.
    static func makeShellRunner() -> (@Sendable (String) -> ShellOutcome) {
        return { cmd in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", cmd]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
                let deadline = DispatchTime.now() + 5
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.leave()
                }
                if group.wait(timeout: deadline) == .timedOut {
                    process.terminate()
                    return .timeout
                }
                let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    return .success(stdout: String(data: stdoutData, encoding: .utf8) ?? "")
                } else {
                    return .failure(stderr: String(data: stderrData, encoding: .utf8) ?? "(no stderr)")
                }
            } catch {
                return .failure(stderr: error.localizedDescription)
            }
        }
    }
}
