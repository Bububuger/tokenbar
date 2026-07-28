import Foundation

public enum CursorDataSource {
    public static let globalStatePath =
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    public static let hookUsagePath = "~/.cursor/tokenbar/usage.jsonl"

    public static func globalStateURL() -> URL {
        URL(
            fileURLWithPath: CodexDataSource.expandHome(in: globalStatePath),
            isDirectory: false
        )
    }

    public static func discoverSources(fileManager: FileManager = .default) -> [CursorSource] {
        var sources: [CursorSource] = []
        let statePath = globalStateURL().path
        if fileManager.isReadableFile(atPath: statePath) {
            sources.append(.globalState(URL(fileURLWithPath: statePath, isDirectory: false)))
        }
        return sources
    }
}

public enum CursorSource: Hashable, Sendable {
    case globalState(URL)
    case hookJSONL(URL)
}
