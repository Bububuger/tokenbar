import Foundation
import TokenBarCore

/// Signals from inside command parsing that the user asked for help. Bubbles
/// up to main.swift which prints the appropriate help text and exits cleanly.
enum HelpRequested: Error {
    case top
    case command(String)
}

enum CLIPath {
    static func resolve(_ explicitPath: String?) -> URL {
        let path = explicitPath ?? UsageDatabase.defaultDatabaseURL().path
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    static func makeRepository(path: String?) throws -> UsageRepository {
        let resolved = resolve(path)
        return try UsageRepository(databaseURL: resolved)
    }
}

enum CLIProgramName {
    static func current() -> String {
        guard let executablePath = CommandLine.arguments.first else {
            return "tbar"
        }
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? "tbar" : name
    }
}

extension AgentKind {
    /// Derived display string for an event/prompt that may have an empty
    /// model_name. Used so the CLI rows always have something printable.
    func modelFallbackName(_ event: UsageEvent) -> String {
        if let model = event.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        return displayName
    }
}

func modelNameOrFallback(_ event: UsageEvent) -> String {
    if let model = event.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
        return model
    }
    return event.agent.displayName
}
