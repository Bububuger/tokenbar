import Foundation

public enum ClaudeDataSource {
    public static func discoverSessionFiles(
        rootDirectory: String = "~/.claude/projects",
        referenceDate: Date = Date(),
        daysBack: Int = 30,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let rootPath = expandHome(in: rootDirectory)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let cutoff = referenceDate.addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)

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

            let children = try fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let candidates = children.filter { url in
                guard !isDirectory(url, fileManager: fileManager) else {
                    return false
                }
                guard url.pathExtension == "jsonl" else {
                    return false
                }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return modifiedAt >= cutoff
            }

            results.append(contentsOf: candidates)
        }

        return results.sorted { $0.path < $1.path }
    }

    public static func readableProjectName(fromSlug slug: String) -> String {
        guard !slug.isEmpty else {
            return "unknown"
        }

        let parts = slug
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }

        return parts.last ?? "unknown"
    }

    public static func expandHome(in path: String) -> String {
        guard path.hasPrefix("~/") else {
            return path
        }

        let suffix = String(path.dropFirst(2))
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(suffix)
            .path
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
