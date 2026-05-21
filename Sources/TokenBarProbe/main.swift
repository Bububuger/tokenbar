import Foundation
import TokenBarCore

@main
struct TokenBarProbe {
    static func main() async {
        let settingsStore = SettingsStore()
        let useDefaultDatabase = ProcessInfo.processInfo.environment["TOKENBAR_PROBE_USE_DEFAULT_DATABASE"] == "1"
        let store: UsageStore
        if useDefaultDatabase {
            do {
                store = try UsageStore(databaseURL: UsageDatabase.defaultDatabaseURL())
            } catch {
                FileHandle.standardError.write(Data("Failed to open default TokenBar database: \(error)\n".utf8))
                Foundation.exit(1)
            }
        } else {
            store = UsageStore()
        }
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()

        let sources: [any InspectableUsageEventSource] = [
            CodexUsageEventSource(),
            ClaudeUsageEventSource(),
            HermesUsageEventSource(),
        ]

        let rebuilder = IndexRebuilder(sources: sources, store: store)
        let result = await rebuilder.rebuild(indexedAt: now, referenceDate: now, calendar: calendar)
        let noOpResult = await rebuilder.rebuild(indexedAt: Date(), referenceDate: now, calendar: calendar)
        let finalState = noOpResult.state

        let statuses = await collectStatuses(from: sources, referenceDate: now, calendar: calendar)
        let refreshState = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: finalState.lastIndexedAt,
            lastRebuildError: finalState.lastRebuildError,
            refreshInterval: settingsStore.refreshInterval
        )

        let payload: [String: Any] = [
            "acceptance_status": acceptanceStatus(for: noOpResult),
            "generated_at": iso8601(now),
            "refresh_interval": settingsStore.refreshInterval.rawValue,
            "refresh_state": refreshState.rawValue,
            "database_scope": useDefaultDatabase ? "default_app_database" : "temporary_probe_database",
            "last_indexed_at": finalState.lastIndexedAt.map(iso8601) as Any,
            "parser_warning_count": finalState.warnings.count,
            "rebuild_error": finalState.lastRebuildError as Any,
            "event_count": finalState.events.count,
            "prompt_count": finalState.prompts.count,
            "last_checkpoint_id": finalState.lastCheckpoint?.id as Any,
            "last_checkpoint_events_added": finalState.lastCheckpoint?.eventsAdded as Any,
            "last_checkpoint_prompts_added": finalState.lastCheckpoint?.promptsAdded as Any,
            "first_checkpoint_events_added": result.state.lastCheckpoint?.eventsAdded as Any,
            "first_checkpoint_prompts_added": result.state.lastCheckpoint?.promptsAdded as Any,
            "no_op_checkpoint_events_added": noOpResult.state.lastCheckpoint?.eventsAdded as Any,
            "no_op_checkpoint_prompts_added": noOpResult.state.lastCheckpoint?.promptsAdded as Any,
            "today_total_tokens": finalState.snapshot.today.totalTokens,
            "top_projects": finalState.snapshot.topProjects.map {
                [
                    "name": $0.name,
                    "total_tokens": $0.summary.totalTokens,
                ]
            },
            "top_agents": finalState.snapshot.topAgents.map {
                [
                    "name": $0.name,
                    "total_tokens": $0.summary.totalTokens,
                ]
            },
            "data_sources": statuses.map {
                [
                    "name": $0.sourceName,
                    "root_path": $0.rootPath,
                    "is_readable": $0.isReadable,
                    "discovered_file_count": $0.discoveredFileCount,
                ]
            },
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Failed to encode probe payload: \(error)\n".utf8))
            Foundation.exit(1)
        }

        if noOpResult.failure != nil && finalState.events.isEmpty {
            Foundation.exit(2)
        }
    }

    private static func collectStatuses(
        from sources: [any InspectableUsageEventSource],
        referenceDate: Date,
        calendar: Calendar
    ) async -> [UsageDataSourceStatus] {
        var statuses: [UsageDataSourceStatus] = []
        for source in sources {
            statuses.append(await source.status(referenceDate: referenceDate, calendar: calendar))
        }
        return statuses.sorted { $0.sourceName < $1.sourceName }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func acceptanceStatus(for result: IndexRebuildResult) -> String {
        if result.failure == nil {
            return "pass"
        }
        return result.state.events.isEmpty ? "fail" : "pass_with_warnings"
    }
}
