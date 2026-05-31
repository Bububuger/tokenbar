import Foundation

public enum QoderDataSource {
    public static let defaultDatabasePath =
        "~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db"

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
                .appendingPathComponent("local.db")
            return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
        }
        let candidate = URL(fileURLWithPath: expanded)
        return fileManager.isReadableFile(atPath: candidate.path) ? [candidate] : []
    }
}
