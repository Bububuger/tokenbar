import Foundation

public struct CursorConversationContext: Sendable, Hashable {
    public let conversationID: String
    /// Canonical absolute path. For multi-root workspaces this is the
    /// `.code-workspace` config path, keeping the workspace as one project.
    public let projectPath: String
    public let projectName: String

    public init(conversationID: String, projectPath: String, projectName: String) {
        self.conversationID = conversationID
        self.projectPath = projectPath
        self.projectName = projectName
    }
}

public struct CursorDashboardTokenUsage: Decodable, Sendable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalCents: Double?

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheWriteTokens
        case totalCents
    }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalCents: Double?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalCents = totalCents
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedInput = try values.decodeFlexibleIntIfPresent(forKey: .inputTokens)
        let decodedOutput = try values.decodeFlexibleIntIfPresent(forKey: .outputTokens)
        let decodedCacheRead = try values.decodeFlexibleIntIfPresent(forKey: .cacheReadTokens)
        let decodedCacheWrite = try values.decodeFlexibleIntIfPresent(forKey: .cacheWriteTokens)
        guard decodedInput != nil || decodedOutput != nil
                || decodedCacheRead != nil || decodedCacheWrite != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .inputTokens,
                in: values,
                debugDescription: "Cursor token usage contains no token fields"
            )
        }
        inputTokens = decodedInput ?? 0
        outputTokens = decodedOutput ?? 0
        cacheReadTokens = decodedCacheRead ?? 0
        cacheWriteTokens = decodedCacheWrite ?? 0
        totalCents = try values.decodeFlexibleDoubleIfPresent(forKey: .totalCents)
        guard inputTokens >= 0, outputTokens >= 0, cacheReadTokens >= 0, cacheWriteTokens >= 0,
              totalCents.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .inputTokens,
                in: values,
                debugDescription: "Cursor token usage contains a negative or non-finite value"
            )
        }
    }
}

public struct CursorDashboardUsageEvent: Decodable, Sendable, Hashable {
    public let timestamp: Date
    public let model: String?
    public let tokenUsage: CursorDashboardTokenUsage?
    public let conversationID: String?

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case model
        case tokenUsage
        case conversationID = "conversationId"
        case conversationSnake = "conversation_id"
        case misspelledSnake = "coversation_id"
        case misspelledCamel = "coversationId"
    }

    public init(
        timestamp: Date,
        model: String?,
        tokenUsage: CursorDashboardTokenUsage?,
        conversationID: String?
    ) {
        self.timestamp = timestamp
        self.model = model
        self.tokenUsage = tokenUsage
        self.conversationID = conversationID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let milliseconds = try values.decodeFlexibleInt64(forKey: .timestamp)
        guard milliseconds >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: values,
                debugDescription: "Cursor timestamp must be non-negative milliseconds"
            )
        }
        timestamp = .tokenBarDate(millisecondsSince1970: milliseconds)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        tokenUsage = try values.decodeIfPresent(CursorDashboardTokenUsage.self, forKey: .tokenUsage)
        conversationID =
            try values.decodeIfPresent(String.self, forKey: .conversationID)
            ?? values.decodeIfPresent(String.self, forKey: .conversationSnake)
            ?? values.decodeIfPresent(String.self, forKey: .misspelledSnake)
            ?? values.decodeIfPresent(String.self, forKey: .misspelledCamel)
    }
}

public struct CursorDashboardUsagePage: Sendable, Hashable {
    public let totalCount: Int
    public let events: [CursorDashboardUsageEvent]

    public init(totalCount: Int, events: [CursorDashboardUsageEvent]) {
        self.totalCount = totalCount
        self.events = events
    }
}

public struct CursorDashboardSyncResult: Sendable, Hashable {
    public let totalEvents: Int
    public let tokenEvents: Int
    public let attributedEvents: Int
    public let costEvents: Int
    public let insertedEvents: Int

    public init(
        totalEvents: Int,
        tokenEvents: Int,
        attributedEvents: Int,
        costEvents: Int,
        insertedEvents: Int
    ) {
        self.totalEvents = totalEvents
        self.tokenEvents = tokenEvents
        self.attributedEvents = attributedEvents
        self.costEvents = costEvents
        self.insertedEvents = insertedEvents
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite,
           value.rounded(.towardZero) == value, value <= Double(Int.max), value >= Double(Int.min) {
            return Int(value)
        }
        if let value = try? decode(String.self, forKey: key), let parsed = Int(value) { return parsed }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected an integer or integer string"
        )
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let parsed = Double(value) { return parsed }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a number or numeric string"
        )
    }

    func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let parsed = Int64(value) { return parsed }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected millisecond timestamp"
        )
    }
}
