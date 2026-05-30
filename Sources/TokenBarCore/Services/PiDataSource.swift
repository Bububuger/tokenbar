import Foundation

public enum PiDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String = "~/.pi/agent",
        fileManager: FileManager = .default
    ) throws -> [URL] {
        return try DiscoveryCache.cached(key: "pi|\(rootDirectory)") {
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

        // pi stores one subdirectory per encoded cwd (--<cwd>--), each holding
        // <timestamp>_<sessionId>.jsonl files.
        let cwdDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var files: [URL] = []
        for cwdDir in cwdDirs {
            let sessionFiles = (try? fileManager.contentsOfDirectory(
                at: cwdDir,
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
