import Foundation

/// Deterministic sample usage events for first-launch / preview / demo when
/// no real local agent logs are discoverable. Returns roughly one week of
/// synthetic activity across a handful of agents, projects, and models.
/// Output is fully deterministic given the same `referenceDate` so SwiftUI
/// previews and snapshot tests stay stable.
public enum SampleUsageProvider {
    public static func events(referenceDate: Date) -> [UsageEvent] {
        var events: [UsageEvent] = []
        let calendar = Calendar(identifier: .gregorian)

        // (agent, parser, modelName). Picked to cover the main agent flavours
        // the rest of the app special-cases.
        let agents: [(AgentKind, ParserKind, String)] = [
            (.claudeCode, .claudeCode, "claude-opus-4-7"),
            (.codex,      .codex,      "gpt-5.5"),
            (.geminiCLI,  .gemini,     "gemini-2.5-pro"),
        ]

        let projects: [(name: String, path: String)] = [
            ("tokenbar",   "/Users/sample/projects/tokenbar"),
            ("my-cli-tool", "/Users/sample/projects/my-cli-tool"),
            ("side-project",    "/Users/sample/projects/side-project"),
        ]

        // 7 days × 4 hours-of-day × 3 agents = 84 sample events.
        let hoursOfDay = [9, 12, 15, 21]

        for dayOffset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: referenceDate) else { continue }
            for hour in hoursOfDay {
                let minute = (hour * 13) % 60
                guard let timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                for (agentIdx, agentInfo) in agents.enumerated() {
                    let (agent, parser, model) = agentInfo
                    let projIdx = (dayOffset + hour + agentIdx) % projects.count
                    let proj = projects[projIdx]

                    let inputTokens   = 4_000 + dayOffset * 1_200 + agentIdx * 400
                    let outputTokens  = 2_500 + dayOffset * 700  + agentIdx * 200
                    let cacheReadTok  = inputTokens * 7
                    let cacheCreateTok = inputTokens

                    events.append(
                        UsageEvent(
                            id:               "sample-\(dayOffset)-\(hour)-\(agent.rawValue)",
                            agent:            agent,
                            projectPath:      proj.path,
                            projectName:      proj.name,
                            sessionId:        "sample-session-\(dayOffset)-\(agent.rawValue)",
                            timestamp:        timestamp,
                            inputTokens:      inputTokens,
                            outputTokens:     outputTokens,
                            cacheReadTokens:  cacheReadTok,
                            cacheCreationTokens: cacheCreateTok,
                            reasoningTokens:  agent == .codex ? 800 : nil,
                            modelName:        model,
                            sourcePath:       "sample://\(agent.rawValue)/\(proj.name)",
                            parser:           parser,
                            confidence:       1.0
                        )
                    )
                }
            }
        }

        return events
    }
}
