import Foundation

public enum TokenNormalizer {
    public static func normalize(
        rawInput: Int, rawOutput: Int,
        cacheRead: Int, cacheCreation: Int, reasoning: Int,
        inputIncludesCached: Bool
    ) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int, reasoning: Int) {
        let clampedInput = max(rawInput, 0)
        let clampedOutput = max(rawOutput, 0)
        let clampedRead = max(cacheRead, 0)
        let clampedCreation = max(cacheCreation, 0)
        let clampedReasoning = max(reasoning, 0)

        if inputIncludesCached {
            let effectiveRead = min(clampedRead, clampedInput)
            return (clampedInput - effectiveRead, clampedOutput, effectiveRead, clampedCreation, clampedReasoning)
        }
        return (clampedInput, clampedOutput, clampedRead, clampedCreation, clampedReasoning)
    }

    public static func normalizeEvents(_ events: [UsageEvent], inputIncludesCached: Bool) -> [UsageEvent] {
        guard inputIncludesCached else { return events }
        return events.map { event in
            let result = normalize(
                rawInput: event.inputTokens,
                rawOutput: event.outputTokens,
                cacheRead: event.cacheReadTokens,
                cacheCreation: event.cacheCreationTokens,
                reasoning: event.reasoningTokens ?? 0,
                inputIncludesCached: true
            )
            return UsageEvent(
                id: event.id,
                agent: event.agent,
                projectPath: event.projectPath,
                projectName: event.projectName,
                sessionId: event.sessionId,
                timestamp: event.timestamp,
                inputTokens: result.input,
                outputTokens: result.output,
                cacheReadTokens: result.cacheRead,
                cacheCreationTokens: result.cacheCreation,
                reasoningTokens: result.reasoning,
                modelName: event.modelName,
                sourcePath: event.sourcePath,
                parser: event.parser,
                confidence: event.confidence
            )
        }
    }
}
