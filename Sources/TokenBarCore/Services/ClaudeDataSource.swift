import Foundation

public enum ClaudeDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String = "~/.claude/projects",
        referenceDate: Date = Date(),
        daysBack: Int? = nil,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        // Coalesce repeat calls within a refresh cycle. `loadEvents` and
        // `status()` both call here, plus the runtime collects statuses
        // twice per refresh — this cuts the call count from ~12+ per refresh
        // to ~6 on the hot path.
        let cacheKey = "claude|\(rootDirectory)|\(daysBack.map(String.init) ?? "all")"
        return try DiscoveryCache.cached(key: cacheKey) {
            try uncachedDiscoverSessionFiles(
                rootDirectory: rootDirectory,
                referenceDate: referenceDate,
                daysBack: daysBack,
                fileManager: fileManager
            )
        }
    }

    private static func uncachedDiscoverSessionFiles(
        rootDirectory: String,
        referenceDate: Date,
        daysBack: Int?,
        fileManager: FileManager
    ) throws -> [URL] {
        let rootPath = expandHome(in: rootDirectory)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let cutoff = daysBack.map { referenceDate.addingTimeInterval(-Double($0) * 24 * 60 * 60) }

        let projectDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var results: [URL] = []

        for projectDirectory in projectDirectories {
            guard isDirectory(projectDirectory, fileManager: fileManager) else {
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: projectDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard !isDirectory(url, fileManager: fileManager) else {
                    continue
                }
                guard url.pathExtension == "jsonl" else {
                    continue
                }
                guard let cutoff else {
                    results.append(url)
                    continue
                }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modifiedAt >= cutoff {
                    results.append(url)
                }
            }
        }

        return results.sorted { $0.path < $1.path }
    }

    public static func projectSlug(for fileURL: URL, rootDirectory: String = "~/.claude/projects") -> String {
        let rootPath = expandHome(in: rootDirectory)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let file = fileURL.standardizedFileURL
        let relative = file.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        return relative.split(separator: "/").first.map(String.init)
            ?? file.deletingLastPathComponent().lastPathComponent
    }

    public static func readableProjectName(fromSlug slug: String) -> String {
        guard !slug.isEmpty else {
            return "unknown"
        }

        if let projectName = readableProjectNameFromKnownPathSlug(slug) {
            return projectName
        }

        let parts = slug
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }

        return parts.last ?? "unknown"
    }

    private static func readableProjectNameFromKnownPathSlug(_ slug: String) -> String? {
        let normalized = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let markers = [
            "Projects-",
            "Projects-",
            "Documents-workspace-projects-",
            "Documents-workspace-",
        ]

        for marker in markers {
            guard let range = normalized.range(of: marker, options: .backwards) else {
                continue
            }
            let tail = String(normalized[range.upperBound...])
            if let worktreeRange = tail.range(of: "--claude-worktrees-", options: .backwards) {
                let worktreeName = String(tail[worktreeRange.upperBound...])
                return worktreeName.isEmpty ? nil : worktreeName
            }
            return tail.isEmpty ? nil : tail
        }

        return nil
    }

    public static func expandHome(in path: String) -> String {
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(suffix)
                .path
        }

        if path.hasPrefix("/."), !FileManager.default.fileExists(atPath: path) {
            let suffix = String(path.dropFirst())
            let homeCandidate = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(suffix)
                .path
            if FileManager.default.fileExists(atPath: homeCandidate) {
                return homeCandidate
            }
        }

        return path
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
