import Foundation

public enum KimiDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> [URL] {
        let roots = resolvedRootDirectories(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return try DiscoveryCache.cached(key: "kimi|\(roots.joined(separator: "|"))") {
            try uncachedDiscoverSessionFiles(
                rootDirectories: roots,
                fileManager: fileManager
            )
        }
    }

    public static func resolvedRootDirectories(
        rootDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        if let rootDirectory {
            return [expandHome(in: rootDirectory, homeDirectory: homeDirectory)]
        }

        let newRoot = environment["KIMI_CODE_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "~/.kimi-code"
        let candidates = [newRoot, "~/.kimi"]
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let path = expandHome(in: candidate, homeDirectory: homeDirectory)
            return seen.insert(path).inserted ? path : nil
        }
    }

    private static func uncachedDiscoverSessionFiles(
        rootDirectories: [String],
        fileManager: FileManager
    ) throws -> [URL] {
        var files: [URL] = []

        for rootDirectory in rootDirectories {
            let sessionsRoot = URL(fileURLWithPath: rootDirectory, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                    at: sessionsRoot,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for case let url as URL in enumerator where url.lastPathComponent == "wire.jsonl" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func expandHome(in path: String, homeDirectory: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory
        } else if path.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
