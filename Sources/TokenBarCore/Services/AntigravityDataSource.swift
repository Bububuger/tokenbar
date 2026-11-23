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
                // Only the root directory entry itself — not ancestors like
                // macOS `/var` → `/private/var` — counts as a "symlink root".
                let rootIsSymlink = isSymlinkDirectory(originalRoot, fileManager: fileManager)
                let resolvedRoot = originalRoot.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedRoots.insert(resolvedRoot.path).inserted else { continue }

                // Always walk the resolved directory (enumerator itself may
                // canonicalize). Return paths under the caller's spelling when
                // the root entry is not a symlink so historical event ids stay
                // stable; symlink roots return the resolved spelling.
                let returnRootPath = rootIsSymlink ? resolvedRoot.path : originalRoot.path
                for file in uncachedDiscover(rootDirectory: resolvedRoot.path, fileManager: fileManager) {
                    let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
                    guard seenResolvedFiles.insert(resolvedFile).inserted else { continue }
                    files.append(
                        rebasedURL(
                            file: file,
                            ontoRoot: returnRootPath,
                            resolvedRootPath: resolvedRoot.path
                        )
                    )
                }
            }
            return files.sorted { $0.path < $1.path }
        }
    }

    private static func isSymlinkDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Map an enumerator URL (often fully resolved) back onto `ontoRoot`.
    /// Resolved paths are dedup keys only; returned sourcePath keeps spelling.
    private static func rebasedURL(
        file: URL,
        ontoRoot: String,
        resolvedRootPath: String
    ) -> URL {
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = resolvedRootPath.hasSuffix("/")
            ? String(resolvedRootPath.dropLast())
            : resolvedRootPath
        guard resolvedFile == resolvedRoot || resolvedFile.hasPrefix(resolvedRoot + "/") else {
            return file
        }
        var suffix = String(resolvedFile.dropFirst(resolvedRoot.count))
        while suffix.hasPrefix("/") {
            suffix.removeFirst()
        }
        let base = URL(fileURLWithPath: ontoRoot, isDirectory: true)
        if suffix.isEmpty {
            return base
        }
        return base.appendingPathComponent(suffix)
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
            guard keepsSessionFile(url) else { continue }
            files.append(url)
        }
        return files
    }

    /// `.system_generated/logs/transcript.jsonl` is the session. The full
    /// transcript and the chunk files next to it repeat those steps.
    private static func keepsSessionFile(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard let logsIndex = parts.lastIndex(of: "logs"),
              logsIndex > 0,
              parts[logsIndex - 1] == ".system_generated" else {
            return true
        }
        return logsIndex == parts.count - 2
            && parts[parts.count - 1].lowercased() == "transcript.jsonl"
    }
}
