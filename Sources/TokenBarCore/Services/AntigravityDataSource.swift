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
            var seenResolvedFiles = Set<String>()
            for root in roots {
                // A root that resolves to an already-scanned path (symlink or
                // spelling difference) must not double-count its files.
                let resolvedRoot = URL(
                    fileURLWithPath: CodexDataSource.expandHome(in: root),
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedRoots.insert(resolvedRoot).inserted else { continue }
                // Enumerate the resolved directory so symlink roots still yield
                // children; keep first-seen path spelling for event-id stability.
                for file in uncachedDiscover(rootDirectory: resolvedRoot, fileManager: fileManager) {
                    let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
                    guard seenResolvedFiles.insert(resolvedFile).inserted else { continue }
                    files.append(file)
                }
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
            .resolvingSymlinksInPath()

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            // Transcripts live under `brain/<id>/.system_generated/logs/`;
            // that one hidden segment must be traversable. Other hidden
            // directories (caches, backups) stay out of the session set.
            options: []
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                // Allow only the known Antigravity transcript container;
                // skip every other hidden directory tree.
                if name.hasPrefix("."), name != ".system_generated" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "jsonl",
                  !url.lastPathComponent.hasPrefix(".") else {
                continue
            }
            // resourceValues can omit isRegularFile for some symlink spellings;
            // only reject when the filesystem explicitly says it is not a file.
            if values?.isRegularFile == false {
                continue
            }
            files.append(url)
        }
        return files
    }
}
