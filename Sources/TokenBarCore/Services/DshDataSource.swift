import Foundation

/// Discovers DeepSeek Harness (DSH) session files.
///
/// Layout: <DSH_HOME>/sessions/<project-dir-slug>/<session-id>/session.jsonl.zstd
/// (legacy v0) or session.v4.jsonl.zstd (v4). The project directory name is a
/// slug of the session cwd, but the parser reads the authoritative cwd from
/// the leading session event, so discovery stays name-agnostic.
public enum DshDataSource {
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
        return try DiscoveryCache.cached(key: "dsh|" + roots.joined(separator: "|")) {
            try uncachedDiscoverSessionFiles(
                rootDirectories: roots,
                fileManager: fileManager
            )
        }
    }

    /// DSH_HOME relocates the whole harness home (profiles, sessions, ...);
    /// the default is ~/.dsh. Kept as a two-entry list only to mirror the
    /// Kimi resolver shape; DSH has no legacy location.
    public static func resolvedRootDirectories(
        rootDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        if let rootDirectory {
            return [expandHome(in: rootDirectory, homeDirectory: homeDirectory)]
        }
        let root = environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "~/.dsh"
        return [expandHome(in: root, homeDirectory: homeDirectory)]
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

            for case let url as URL in enumerator
            where url.lastPathComponent.hasSuffix(".jsonl.zstd") {
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
