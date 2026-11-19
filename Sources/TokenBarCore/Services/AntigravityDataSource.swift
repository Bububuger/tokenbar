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
            // Shared across every root in this call so overlapping roots
            // (e.g. root + root/brain/session-a) cannot double-emit a file.
            var seenResolvedFiles = Set<String>()
            for root in roots {
                let expanded = CodexDataSource.expandHome(in: root)
                let originalRoot = URL(fileURLWithPath: expanded, isDirectory: true)
                    .standardizedFileURL
                let resolvedRoot = originalRoot.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedRoots.insert(resolvedRoot.path).inserted else { continue }

                // Symlink roots must enumerate the real directory (otherwise
                // children are missed). Non-symlink roots keep their original
                // spelling so historical event ids / watermarks stay stable.
                let enumerateRoot = originalRoot.path == resolvedRoot.path
                    ? originalRoot.path
                    : resolvedRoot.path
                for file in uncachedDiscover(rootDirectory: enumerateRoot, fileManager: fileManager) {
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
