import Foundation

public enum OpenCodeDataSource {
    public static let defaultDatabasePath = "~/.local/share/opencode/opencode.db"

    public static func discoverDatabases(
        rootPath: String = defaultDatabasePath,
        fileManager: FileManager = .default
    ) -> [URL] {
        let expanded = CodexDataSource.expandHome(in: rootPath)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return []
        }
        if isDirectory.boolValue {
            let candidate = URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("opencode.db")
            return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
        }
        let candidate = URL(fileURLWithPath: expanded)
        return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
    }
}
