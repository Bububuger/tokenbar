import Foundation

/// One row of the popover rate drilldown: either a whole agent
/// (`modelName == nil`) or that agent pinned to one model. `burn` and
/// `generation` are computed over exactly the events the slice covers, so
/// `eventCount` counts window-relevant events even when a rate self-filters
/// some of them out (e.g. a generation-ended event whose timestamp predates
/// the window counts here but only feeds `generation`).
public struct RateSlice: Sendable, Hashable {
    public let agent: AgentKind
    public let modelName: String?        // nil → whole-agent slice
    public let burn: BurnRate
    public let generation: GenerationRate
    public let eventCount: Int           // window events backing this slice

    public init(agent: AgentKind, modelName: String?, burn: BurnRate, generation: GenerationRate, eventCount: Int) {
        self.agent = agent
        self.modelName = modelName
        self.burn = burn
        self.generation = generation
        self.eventCount = eventCount
    }
}

/// Agent × model breakdown of the two menu-bar rate modes over a shared
/// trailing window (default 10 min). An event is window-relevant when its
/// timestamp falls in `[asOf-window, asOf)` or its `generationEndMs` does —
/// matching the membership rules BurnRate and GenerationRate apply
/// internally, so no slice exists purely from out-of-window data.
///
/// Cursor remote-account events are excluded up front: their timestamps
/// describe account-scope activity, not this Mac's (same convention as
/// BurnRate / GenerationRate).
public enum RateDrilldown {
    public static func makeSlices(
        events: [UsageEvent],
        asOf: Date = Date(),
        window: TimeInterval = BurnRate.defaultWindow
    ) -> [RateSlice] {
        let windowStart = asOf.addingTimeInterval(-window)
        let windowStartMs = Int64((windowStart.timeIntervalSince1970 * 1_000).rounded())
        let asOfMs = Int64((asOf.timeIntervalSince1970 * 1_000).rounded())

        let relevant = events.filter { event in
            guard event.sourcePath != UsageRepository.cursorRemoteSourcePath else {
                return false
            }
            if event.timestamp >= windowStart && event.timestamp < asOf {
                return true
            }
            if let endMs = event.generationEndMs, endMs >= windowStartMs && endMs < asOfMs {
                return true
            }
            return false
        }

        var eventsByAgent: [AgentKind: [UsageEvent]] = [:]
        for event in relevant {
            eventsByAgent[event.agent, default: []].append(event)
        }

        var slices: [RateSlice] = []
        for agent in eventsByAgent.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let agentEvents = eventsByAgent[agent] ?? []
            slices.append(makeSlice(agent: agent, modelName: nil, events: agentEvents, asOf: asOf, window: window))
            let modelNames = Set(agentEvents.compactMap(\.modelName)).sorted()
            for modelName in modelNames {
                let modelEvents = agentEvents.filter { $0.modelName == modelName }
                slices.append(makeSlice(agent: agent, modelName: modelName, events: modelEvents, asOf: asOf, window: window))
            }
        }
        return slices
    }

    private static func makeSlice(
        agent: AgentKind,
        modelName: String?,
        events: [UsageEvent],
        asOf: Date,
        window: TimeInterval
    ) -> RateSlice {
        RateSlice(
            agent: agent,
            modelName: modelName,
            burn: BurnRate(events: events, asOf: asOf, window: window),
            generation: GenerationRate(events: events, window: window, asOf: asOf),
            eventCount: events.count
        )
    }
}
