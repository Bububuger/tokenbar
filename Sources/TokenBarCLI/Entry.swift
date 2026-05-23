import Darwin
import Foundation
import TokenBarCore

@main
struct TokenBarCLIEntry {
    static func main() async {
        do {
            try await dispatch()
        } catch let helpError as HelpRequested {
            switch helpError {
            case .top:
                print(CommandRegistry.helpSummary(programName: CLIProgramName.current()))
            case .command(let name):
                if let descriptor = CommandRegistry.descriptor(named: name) {
                    print(CommandRegistry.helpDetail(descriptor, programName: CLIProgramName.current()))
                } else {
                    print(CommandRegistry.helpSummary(programName: CLIProgramName.current()))
                }
            }
            Foundation.exit(0)
        } catch let error as CLIError {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs("Run `\(CLIProgramName.current()) <command> --help` for usage.\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func dispatch() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            throw HelpRequested.top
        }

        var cursor = ArgumentCursor(args)
        var dbOverride: String?

        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h":
                throw HelpRequested.top
            case "--db":
                dbOverride = try cursor.nextValue(for: "--db")
            case "help":
                throw HelpRequested.top
            case "events":
                try await runFiltered(command: EventsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try EventsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try EventsCommand.run(local.options)
                }
            case "prompts":
                try await runFiltered(command: PromptsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try PromptsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try PromptsCommand.run(local.options)
                }
            case "projects":
                try await runFiltered(command: ProjectsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try ProjectsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try ProjectsCommand.run(local.options)
                }
            case "sessions":
                try await runFiltered(command: SessionsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try SessionsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try SessionsCommand.run(local.options)
                }
            case "models":
                try await runFiltered(command: ModelsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try ModelsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try ModelsCommand.run(local.options)
                }
            case "agents":
                try await runFiltered(command: AgentsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try AgentsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try AgentsCommand.run(local.options)
                }
            case "summary":
                try await runFiltered(command: SummaryCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try SummaryCommand.parse(cursor: &local.cursor, options: &local.options)
                    try SummaryCommand.run(local.options)
                }
            case "timeline":
                try await runFiltered(command: TimelineCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try TimelineCommand.parse(cursor: &local.cursor, options: &local.options)
                    try TimelineCommand.run(local.options)
                }
            case "sources":
                try await runFiltered(command: SourcesCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try SourcesCommand.parse(cursor: &local.cursor, options: &local.options)
                    try await SourcesCommand.run(local.options)
                }
            case "checkpoints":
                try await runFiltered(command: CheckpointsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try CheckpointsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try CheckpointsCommand.run(local.options)
                }
            case "warnings":
                try await runFiltered(command: WarningsCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try WarningsCommand.parse(cursor: &local.cursor, options: &local.options)
                    try WarningsCommand.run(local.options)
                }
            case "schema":
                try await runFiltered(command: SchemaCommand.name, dbOverride: dbOverride, cursor: &cursor) { options in
                    var local = options
                    try SchemaCommand.parse(cursor: &local.cursor, options: &local.options)
                    try SchemaCommand.run(local.options)
                }
            case "rebuild":
                let parsed = try RebuildCommand.parse(cursor: &cursor, dbOverride: dbOverride)
                try await RebuildCommand.run(parsed)
                return
            case "prompt":
                let action = try SavedPromptCommand.parse(cursor: &cursor, dbOverride: dbOverride)
                try SavedPromptCommand.run(action)
                return
            case let unknown where unknown.hasPrefix("-"):
                throw CLIError.invalidArgument("Unknown option: \(unknown)")
            default:
                throw CLIError.invalidArgument("Unknown command: \(arg). Run `\(CLIProgramName.current()) help` to list commands.")
            }
            return
        }
    }

    /// Helper that prepares a fresh FilterOptions seeded with the global
    /// --db override, runs the command-specific closure, and returns. We
    /// pass-by-inout via a struct because closures can't mutate captured
    /// inout parameters across suspension points.
    private static func runFiltered(
        command: String,
        dbOverride: String?,
        cursor: inout ArgumentCursor,
        block: (inout RunBundle) async throws -> Void
    ) async throws {
        var bundle = RunBundle(
            options: FilterOptions(databasePath: dbOverride),
            cursor: cursor
        )
        try await block(&bundle)
        cursor = bundle.cursor
    }
}

struct RunBundle {
    var options: FilterOptions
    var cursor: ArgumentCursor
}
