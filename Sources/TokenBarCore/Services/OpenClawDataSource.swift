import Foundation

public enum OpenClawDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String = "~/.openclaw",
        fileManager: FileManager = .default
    ) throws -> [URL] {
        return try DiscoveryCache.cached(key: "openclaw|\(rootDirectory)") {
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
        let agentsRoot = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: agentsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let agentDirs = (try? fileManager.contentsOfDirectory(
            at: agentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var files: [URL] = []
        for agentDir in agentDirs {
            let sessionsDir = agentDir.appendingPathComponent("sessions", isDirectory: true)
            guard fileManager.fileExists(atPath: sessionsDir.path) else { continue }
            let sessionFiles = (try? fileManager.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in sessionFiles where file.pathExtension.lowercased() == "jsonl" {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
