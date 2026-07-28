import Foundation
import GRDB

/// Parses Cursor usage from:
/// - `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
///   (`cursorDiskKV` rows keyed `bubbleId:{composerId}:{bubbleId}`)
/// - optional hook JSONL at `~/.cursor/tokenbar/usage.jsonl`
public struct CursorLocalUsageSnapshot: Sendable, Hashable {
    public let loadResult: UsageSourceLoadResult
    public let conversationContexts: [CursorConversationContext]

    public init(loadResult: UsageSourceLoadResult, conversationContexts: [CursorConversationContext]) {
        self.loadResult = loadResult
        self.conversationContexts = conversationContexts
    }
}

public enum CursorUsageParser {
    public static func parseGlobalState(
        databaseURL: URL,
        watermark: SourceWatermark? = nil
    ) throws -> UsageSourceLoadResult {
        try parseLocalSnapshot(databaseURL: databaseURL, watermark: watermark).loadResult
    }

    /// Reads only local human-authored prompts and project identity. Cursor's
    /// local token fields are intentionally ignored because they are not an
    /// authoritative usage source.
    public static func parseLocalSnapshot(
        databaseURL: URL,
        watermark: SourceWatermark? = nil
    ) throws -> CursorLocalUsageSnapshot {
        let sourcePath = databaseURL.path
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: sourcePath, configuration: configuration)

        return try queue.read { db in
            let currentFingerprint = try? JSONLIncrementalReader.fingerprint(at: sourcePath)
            let composers = loadComposers(db: db)
            let resolvedContexts = resolveConversationContexts(composers)

            let rows = try Row.fetchAll(db, sql: """
            SELECT key, value
            FROM cursorDiskKV
            WHERE key LIKE 'bubbleId:%'
            ORDER BY key ASC
            """)

            var prompts: [PromptRecord] = []
            var maxKey = watermark?.lastEventId ?? ""
            var maxTimestamp = watermark?.lastMtime ?? .distantPast

            for row in rows {
                let key: String = row["key"]
                guard let value = row["value"] as DatabaseValueConvertible? else { continue }
                let jsonText = databaseString(from: value)
                guard !jsonText.isEmpty,
                      let data = jsonText.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continue
                }

                let bubbleType = intValue(object["type"])
                guard bubbleType == 1,
                      !boolValue(object["isSimulatedMsg"]),
                      !boolValue(object["isSimulatedMessage"]),
                      object["subagentSpawnTaskToolCallId"] == nil else {
                    continue
                }
                let composerID = composerID(fromKey: key) ?? "unknown"
                // Prompts synthesized inside subagent composers are not direct
                // user input, even when Cursor stores them as type=1 bubbles.
                guard composers[composerID]?.parentID == nil else { continue }

                guard let rawText = object["text"] as? String else { continue }
                let content = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }

                let context = resolvedContexts[composerID]
                    ?? fallbackContext(forBubble: object, conversationID: composerID)
                let projectName = context?.projectName ?? "Cursor · 未归属"
                let bubbleID = bubbleID(fromKey: key) ?? key
                let timestamp = parseBubbleTimestamp(object) ?? .distantPast
                let contentHash = PromptExtraction.hash(content)
                prompts.append(
                    PromptRecord(
                        id: "\(sourcePath)#cursor-prompt#\(bubbleID)#\(contentHash)",
                        eventId: nil,
                        agent: .cursor,
                        projectName: projectName,
                        sessionId: composerID,
                        timestamp: timestamp,
                        content: content,
                        contentHash: contentHash,
                        sourcePath: sourcePath,
                    )
                )

                if key > maxKey { maxKey = key }
                if timestamp > maxTimestamp { maxTimestamp = timestamp }
            }

            let nextWatermark = SourceWatermark(
                sourcePath: sourcePath,
                agent: .cursor,
                lastMtime: maxTimestamp,
                lastByteOffset: 0,
                lastEventId: maxKey.isEmpty ? watermark?.lastEventId : maxKey,
                lastInode: currentFingerprint?.inode ?? watermark?.lastInode,
                updatedAt: Date()
            )

            return CursorLocalUsageSnapshot(
                loadResult: UsageSourceLoadResult(
                    events: [],
                    prompts: prompts,
                    nextWatermarks: [nextWatermark],
                    warnings: []
                ),
                conversationContexts: resolvedContexts.values.sorted {
                    $0.conversationID < $1.conversationID
                }
            )
        }
    }

    public static func parseHookJSONL(
        fileURL: URL,
        watermark: SourceWatermark? = nil
    ) throws -> UsageSourceLoadResult {
        let readResult = try JSONLIncrementalReader.read(
            fileURL: fileURL,
            sourceName: "Cursor",
            agent: .cursor,
            watermark: watermark
        )

        var events: [UsageEvent] = []
        for line in readResult.lines {
            let result = CursorHookJSONLParser.parse(lines: [line], fileURL: fileURL)
            events.append(contentsOf: result.events)
        }

        return UsageSourceLoadResult(
            events: events,
            prompts: [],
            nextWatermarks: [readResult.nextWatermark],
            warnings: readResult.warnings
        )
    }

    private struct Composer {
        let id: String
        let ownProjectPath: String?
        let parentID: String?
        let childIDs: [String]
    }

    private static func loadComposers(db: Database) -> [String: Composer] {
        guard let rows = try? Row.fetchAll(
            db,
            sql: "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
        ) else {
            return [:]
        }

        var composers: [String: Composer] = [:]
        for row in rows {
            let key: String = row["key"]
            guard let composerID = key.split(separator: ":").last.map(String.init) else { continue }
            guard let value = row["value"] as DatabaseValueConvertible? else { continue }
            let jsonText = databaseString(from: value)
            guard let data = jsonText.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let workspace = object["workspaceIdentifier"] as? [String: Any]
            let context = object["context"] as? [String: Any]
            let subagentInfo = object["subagentInfo"] as? [String: Any]
            let parentID = stringValue(
                subagentInfo ?? [:],
                "parentComposerId",
                "forkedFromComposerId",
                "rootParentConversationId"
            )
            let childIDs = (object["subagentComposerIds"] as? [String]) ?? []
            composers[composerID] = Composer(
                id: composerID,
                ownProjectPath: projectPath(fromWorkspaceIdentifier: workspace)
                    ?? context.flatMap(projectPath(fromContext:)),
                parentID: parentID,
                childIDs: childIDs
            )
        }
        // Older rows sometimes expose only the parent's child list.
        for parent in Array(composers.values) {
            for childID in parent.childIDs where composers[childID]?.parentID == nil {
                guard let child = composers[childID] else { continue }
                composers[childID] = Composer(
                    id: child.id,
                    ownProjectPath: child.ownProjectPath,
                    parentID: parent.id,
                    childIDs: child.childIDs
                )
            }
        }
        return composers
    }

    private static func resolveConversationContexts(
        _ composers: [String: Composer]
    ) -> [String: CursorConversationContext] {
        var result: [String: CursorConversationContext] = [:]
        func resolve(_ id: String, visited: Set<String>) -> CursorConversationContext? {
            if let existing = result[id] { return existing }
            guard !visited.contains(id), let composer = composers[id] else { return nil }
            var nextVisited = visited
            nextVisited.insert(id)
            let path: String?
            if let parentID = composer.parentID {
                path = resolve(parentID, visited: nextVisited)?.projectPath ?? composer.ownProjectPath
            } else {
                path = composer.ownProjectPath
            }
            guard let path else { return nil }
            let context = makeContext(conversationID: id, path: path)
            result[id] = context
            return context
        }
        for id in composers.keys {
            _ = resolve(id, visited: [])
        }
        return disambiguateProjectNames(result)
    }

    private static func disambiguateProjectNames(
        _ contexts: [String: CursorConversationContext]
    ) -> [String: CursorConversationContext] {
        let pathsByBaseName = Dictionary(
            grouping: Set(contexts.values.map(\.projectPath)),
            by: { displayPathComponents($0).last ?? $0 }
        )
        var displayNameByPath: [String: String] = [:]

        for (_, paths) in pathsByBaseName {
            if paths.count == 1, let path = paths.first {
                displayNameByPath[path] = displayPathComponents(path).last
            } else {
                let componentLists = paths.map { ($0, displayPathComponents($0)) }
                let maximumDepth = componentLists.map { $0.1.count }.max() ?? 1
                var chosenDepth = maximumDepth
                for depth in 2...maximumDepth {
                    let candidates = Set(componentLists.map {
                        $0.1.suffix(depth).joined(separator: "/")
                    })
                    if candidates.count == componentLists.count {
                        chosenDepth = depth
                        break
                    }
                }
                for (path, components) in componentLists {
                    displayNameByPath[path] = components.suffix(chosenDepth).joined(separator: "/")
                }
            }
        }

        return contexts.mapValues { context in
            CursorConversationContext(
                conversationID: context.conversationID,
                projectPath: context.projectPath,
                projectName: displayNameByPath[context.projectPath] ?? context.projectName
            )
        }
    }

    private static func displayPathComponents(_ path: String) -> [String] {
        var components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        if let last = components.last, last.hasSuffix(".code-workspace") {
            components[components.count - 1] = String(last.dropLast(".code-workspace".count))
        }
        return components
    }

    private static func fallbackContext(
        forBubble bubble: [String: Any],
        conversationID: String
    ) -> CursorConversationContext? {
        if let uris = bubble["workspaceUris"] as? [String],
           let path = uris.compactMap(filePath(fromURI:)).first {
            return makeContext(conversationID: conversationID, path: path)
        }
        if let context = bubble["context"] as? [String: Any],
           let path = projectPath(fromContext: context) {
            return makeContext(conversationID: conversationID, path: path)
        }
        return nil
    }

    private static func projectPath(fromWorkspaceIdentifier workspace: [String: Any]?) -> String? {
        guard let workspace else { return nil }
        // A config path represents the multi-root workspace itself. Do not
        // split usage across its individual folders.
        if let configPath = pathFromURIObject(workspace["configPath"]) {
            return configPath
        }
        return pathFromURIObject(workspace["uri"])
    }

    private static func projectPath(fromContext context: [String: Any]) -> String? {
        if let selections = context["fileSelections"] as? [[String: Any]] {
            for selection in selections {
                if let fsPath = pathFromURIObject(selection["uri"]) {
                    return (fsPath as NSString).deletingLastPathComponent
                }
            }
        }
        if let folders = context["folderSelections"] as? [[String: Any]] {
            for folder in folders {
                if let fsPath = pathFromURIObject(folder["uri"]) {
                    return fsPath
                }
            }
        }
        return nil
    }

    private static func filePath(fromURI uri: String) -> String? {
        if uri.hasPrefix("file://"), let url = URL(string: uri) {
            return canonicalPath(url.path)
        }
        if uri.hasPrefix("/") { return canonicalPath(uri) }
        return nil
    }

    private static func pathFromURIObject(_ raw: Any?) -> String? {
        if let string = raw as? String {
            return filePath(fromURI: string)
        }
        guard let object = raw as? [String: Any] else { return nil }
        if let fsPath = object["fsPath"] as? String, !fsPath.isEmpty {
            return canonicalPath(fsPath)
        }
        if let external = object["external"] as? String {
            return filePath(fromURI: external)
        }
        if let path = object["path"] as? String, !path.isEmpty {
            return canonicalPath(path)
        }
        return nil
    }

    private static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func makeContext(conversationID: String, path: String) -> CursorConversationContext {
        let url = URL(fileURLWithPath: canonicalPath(path))
        let filename = url.lastPathComponent
        let name = filename.hasSuffix(".code-workspace")
            ? String(filename.dropLast(".code-workspace".count))
            : filename
        return CursorConversationContext(
            conversationID: conversationID,
            projectPath: url.path,
            projectName: name.isEmpty ? "Cursor" : name
        )
    }

    private static func composerID(fromKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return String(parts[1])
    }

    private static func bubbleID(fromKey key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return String(parts[2])
    }

    private static func parseBubbleTimestamp(_ object: [String: Any]) -> Date? {
        if let createdAt = object["createdAt"] as? String {
            return ISO8601Fast.parseUTC(createdAt)
                ?? iso8601WithFractional.date(from: createdAt)
                ?? iso8601NoFractional.date(from: createdAt)
        }
        if let createdAt = object["createdAt"] as? NSNumber {
            let value = createdAt.doubleValue
            if value > 10_000_000_000 {
                return .tokenBarDate(millisecondsSince1970: Int64(value))
            }
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    private static func databaseString(from value: DatabaseValueConvertible) -> String {
        if let string = value as? String { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) ?? "" }
        return ""
    }

    private static func intValue(_ values: Any?...) -> Int {
        for value in values {
            guard let value else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let number = value as? Int { return number }
            if let string = value as? String, let number = Int(string) { return number }
        }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }

    private static func stringValue(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601NoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Hook-written JSONL rows at `~/.cursor/tokenbar/usage.jsonl`.
enum CursorHookJSONLParser {
    static func parse(lines: [JSONLLineRecord], fileURL: URL) -> ParseResult {
        let sourcePath = fileURL.path
        var events: [UsageEvent] = []

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let usage = (object["usage"] as? [String: Any]) ?? object
            let input = intValue(usage, "input_tokens", "inputTokens", "promptTokens")
            let output = intValue(usage, "output_tokens", "outputTokens", "completionTokens")
            let cacheRead = intValue(usage, "cache_read_tokens", "cacheReadTokens")
            let cacheCreation = intValue(usage, "cache_write_tokens", "cacheCreationTokens")
            guard input + output + cacheRead + cacheCreation > 0 else { continue }

            let messageID = (object["id"] as? String)
                ?? (object["bubble_id"] as? String)
                ?? (object["request_id"] as? String)
                ?? "line-\(line.lineNumber)"
            let sessionID = (object["session_id"] as? String)
                ?? (object["composer_id"] as? String)
                ?? "cursor"
            let model = (object["model"] as? String) ?? (usage["model"] as? String)
            let timestamp = resolveTimestamp(object) ?? .distantPast
            let projectPath = (object["project_path"] as? String) ?? (object["cwd"] as? String)

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#cursor#\(messageID)",
                    agent: .cursor,
                    projectPath: projectPath,
                    projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "cursor",
                    sessionId: sessionID,
                    timestamp: timestamp,
                    inputTokens: max(input, 0),
                    outputTokens: max(output, 0),
                    cacheReadTokens: max(cacheRead, 0),
                    cacheCreationTokens: max(cacheCreation, 0),
                    reasoningTokens: nil,
                    modelName: model,
                    sourcePath: sourcePath,
                    parser: .cursor,
                    confidence: 1.0
                )
            )
        }

        return ParseResult(events: events, warnings: [])
    }

    private static func intValue(_ object: [String: Any], _ keys: String...) -> Int {
        for key in keys {
            if let raw = object[key] {
                if let number = raw as? NSNumber { return number.intValue }
                if let number = raw as? Int { return number }
                if let string = raw as? String, let number = Int(string) { return number }
            }
        }
        return 0
    }

    private static func resolveTimestamp(_ object: [String: Any]) -> Date? {
        if let number = object["timestamp"] as? NSNumber {
            let value = number.doubleValue
            if value > 10_000_000_000 {
                return .tokenBarDate(millisecondsSince1970: number.int64Value)
            }
            return Date(timeIntervalSince1970: value)
        }
        if let iso = object["timestamp"] as? String {
            return ISO8601Fast.parseUTC(iso)
        }
        return nil
    }
}
