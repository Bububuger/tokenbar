import Foundation

public enum PluginExecutableRunner {
    // ISO8601DateFormatter is thread-safe on macOS 10.15+; share one instance.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func run(
        config: PluginExecutableSource,
        pluginDir: URL,
        timestampFormat: PluginTimestampFormat = .iso8601,
        since: Date? = nil
    ) async throws -> UsageSourceLoadResult {
        var events: [UsageEvent] = []
        var warnings: [UsageSourceWarning] = []
        let sourceName = "plugin-executable"
        let sourcePath = pluginDir.path

        var arguments: [String] = []
        if let script = config.script {
            let scriptPath = pluginDir.appendingPathComponent(script).path
            arguments.append(scriptPath)
        }
        if let args = config.args {
            arguments.append(contentsOf: args)
        }
        if let flag = config.incrementalFlag, let since {
            arguments.append(flag)
            arguments.append(iso8601.string(from: since))
        }

        let stateDir = pluginDir.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["TOKENBAR_PLUGIN_STATE_DIR": stateDir.path],
            uniquingKeysWith: { _, new in new }
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timeout = config.effectiveTimeout

        do {
            try process.run()
        } catch {
            warnings.append(UsageSourceWarning(
                sourceName: sourceName,
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "failed to launch: \(error.localizedDescription)"
            ))
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()

        if let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stderrText.isEmpty {
            for line in stderrText.split(separator: "\n").prefix(10) {
                warnings.append(UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: sourcePath,
                    lineNumber: nil,
                    message: String(line)
                ))
            }
        }

        guard process.terminationStatus == 0 else {
            warnings.append(UsageSourceWarning(
                sourceName: sourceName,
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "exited with code \(process.terminationStatus)"
            ))
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        guard let stdoutText = String(data: stdoutData, encoding: .utf8) else {
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        for (lineIndex, line) in stdoutText.split(separator: "\n").enumerated() {
            let lineStr = String(line)
            guard let data = lineStr.data(using: .utf8) else { continue }

            let object: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    warnings.append(UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: sourcePath,
                        lineNumber: lineIndex + 1,
                        message: "line is not a JSON object"
                    ))
                    continue
                }
                object = parsed
            } catch {
                warnings.append(UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: sourcePath,
                    lineNumber: lineIndex + 1,
                    message: "malformed JSON"
                ))
                continue
            }

            let eventId = (object["id"] as? String) ?? "\(sourcePath)#exec#\(lineIndex)"
            let inputTokens = intFromAny(object["input_tokens"]) ?? 0
            let outputTokens = intFromAny(object["output_tokens"]) ?? 0
            let cacheRead = intFromAny(object["cache_read_tokens"]) ?? 0
            let cacheCreation = intFromAny(object["cache_creation_tokens"]) ?? 0
            let reasoning = intFromAny(object["reasoning_tokens"]) ?? 0
            let model = object["model"] as? String
            let sessionId = (object["session_id"] as? String) ?? "unknown"
            let project = (object["project"] as? String) ?? pluginDir.lastPathComponent

            let timestamp: Date
            if let tsValue = object["timestamp"] {
                timestamp = timestampFormat.parse(tsValue) ?? Date()
            } else {
                timestamp = Date()
            }

            events.append(UsageEvent(
                id: eventId,
                agent: .custom,
                projectPath: nil,
                projectName: project,
                sessionId: sessionId,
                timestamp: timestamp,
                inputTokens: max(inputTokens, 0),
                outputTokens: max(outputTokens, 0),
                cacheReadTokens: max(cacheRead, 0),
                cacheCreationTokens: max(cacheCreation, 0),
                reasoningTokens: reasoning > 0 ? reasoning : nil,
                modelName: model,
                sourcePath: sourcePath,
                parser: .custom,
                confidence: 1.0
            ))
        }

        let nextWatermark = SourceWatermark(
            sourcePath: sourcePath,
            agent: .custom,
            lastMtime: events.last?.timestamp ?? since ?? Date(),
            lastByteOffset: 0,
            lastEventId: events.last?.id,
            lastInode: nil,
            updatedAt: Date()
        )

        return UsageSourceLoadResult(
            events: events,
            nextWatermarks: events.isEmpty ? [] : [nextWatermark],
            warnings: warnings
        )
    }

    private static func intFromAny(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as Int64: Int(n)
        case let n as Double: Int(n)
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }
}
