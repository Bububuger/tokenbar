import Foundation

public enum AntigravityDataSource {
    /// Antigravity writes session JSONL under the Gemini config dir and,
    /// on some builds, an Application Support tree. The `agy` CLI uses a
    /// sibling `antigravity-cli` tree; its events still map to `.antigravity`.
    public static let defaultRoots = [
        "~/.gemini/antigravity",
        "~/.gemini/antigravity-cli",
        "~/Library/Application Support/Antigravity",
    ]

    public static func discoverSessionFiles(
        roots: [String] = defaultRoots,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        return try DiscoveryCache.cached(key: "antigravity|\(roots.joined(separator: ","))") {
            var files: [URL] = []
            var resolvedRoots = Set<String>()
            for root in roots {
                // A root that resolves to an already-scanned path (symlink or
                // spelling difference) must not double-count its files.
                let resolved = URL(
                    fileURLWithPath: CodexDataSource.expandHome(in: root),
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedRoots.insert(resolved).inserted else { continue }
                files.append(contentsOf: uncachedDiscover(rootDirectory: root, fileManager: fileManager))
            }
            return files.sorted { $0.path < $1.path }
        }
    }

    private static func uncachedDiscover(
        rootDirectory: String,
        fileManager: FileManager
    ) -> [URL] {
        let expandedRoot = CodexDataSource.expandHome(in: rootDirectory)
        let root = URL(fileURLWithPath: expandedRoot, isDirectory: true)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            // Transcripts live under `brain/<id>/.system_generated/logs/`;
            // hidden segments must be traversed to reach them.
            options: []
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            files.append(url)
        }
        return files
    }
}
