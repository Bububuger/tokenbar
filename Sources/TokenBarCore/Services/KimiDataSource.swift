import Foundation

public enum KimiDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String = "~/.kimi",
        fileManager: FileManager = .default
    ) throws -> [URL] {
        return try DiscoveryCache.cached(key: "kimi|\(rootDirectory)") {
            try uncachedDiscoverSessionFiles(
                rootDirectory: rootDirectory,
                fileManager: fileManager
            )
        }
    }

    private static func uncachedDiscoverSessionFiles(
        rootDirectory: String,
        fileManager: FileManager
    ) throws -> [URL] {
        let expandedRoot = CodexDataSource.expandHome(in: rootDirectory)
        let sessionsRoot = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "wire.jsonl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
