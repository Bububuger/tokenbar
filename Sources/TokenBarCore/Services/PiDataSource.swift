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

        let cwdDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var files: [URL] = []
        for cwdDir in cwdDirs {
            let sessionEntries = (try? fileManager.contentsOfDirectory(
                at: cwdDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in sessionEntries {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isRegularFile == true, entry.pathExtension.lowercased() == "jsonl" {
                    files.append(entry)
                    continue
                }
                guard values?.isDirectory == true else { continue }
                let nestedFiles = (try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for nestedFile in nestedFiles {
                    let nestedValues = try? nestedFile.resourceValues(forKeys: [.isRegularFileKey])
                    guard nestedValues?.isRegularFile == true,
                          nestedFile.pathExtension.lowercased() == "jsonl" else {
                        continue
                    }
                    files.append(nestedFile)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
