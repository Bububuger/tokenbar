import Foundation

public enum KiroDataSource {
    public static let defaultDatabasePath =
        "~/Library/Application Support/kiro-cli/data.sqlite3"

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
                .appendingPathComponent("data.sqlite3")
            return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
        }
        let candidate = URL(fileURLWithPath: expanded)
        return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
    }
}
