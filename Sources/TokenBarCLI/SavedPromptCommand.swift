import Foundation
import TokenBarCore

enum SavedPromptCommand {
    enum Action {
        case list(databasePath: String?)
        case get(databasePath: String?, slug: String)
    }

    static func parse(cursor: inout ArgumentCursor, dbOverride: String?) throws -> Action {
        guard let action = cursor.next() else {
            throw CLIError.invalidArgument("Usage: prompt <list|get <slug>>")
        }
        switch action {
        case "--help", "-h":
            throw HelpRequested.command("prompt")
        case "list":
            var databasePath = dbOverride
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    throw HelpRequested.command("prompt")
                case "--db":
                    databasePath = try cursor.nextValue(for: "--db")
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown prompt list option: \(unknown)")
                default:
                    throw CLIError.invalidArgument("Unexpected prompt list argument: \(arg)")
                }
            }
            return .list(databasePath: databasePath)
        case "get":
            var databasePath = dbOverride
            var slug: String?
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    throw HelpRequested.command("prompt")
                case "--db":
                    databasePath = try cursor.nextValue(for: "--db")
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown prompt get option: \(unknown)")
                default:
                    if slug == nil {
                        slug = arg
                    } else {
                        throw CLIError.invalidArgument("Unexpected prompt get argument: \(arg)")
                    }
                }
            }
            guard let slug else {
                throw CLIError.invalidArgument("Usage: prompt get <slug>")
            }
            return .get(databasePath: databasePath, slug: slug)
        default:
            throw CLIError.invalidArgument("Unknown prompt action: \(action). Use list or get <slug>.")
        }
    }

    static func run(_ action: Action) throws {
        switch action {
        case .list(let databasePath):
            let repository = try CLIPath.makeRepository(path: databasePath)
            let prompts = try repository.allSavedPrompts()
            for prompt in prompts {
                print("\(prompt.slug)\t\(prompt.title)")
            }
        case .get(let databasePath, let slug):
            let repository = try CLIPath.makeRepository(path: databasePath)
            guard let prompt = try repository.savedPrompt(slug: slug) else {
                fputs("Unknown saved prompt slug: \(slug)\n", stderr)
                Foundation.exit(1)
            }
            FileHandle.standardOutput.write(Data(prompt.body.utf8))
        }
    }
}
