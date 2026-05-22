import Foundation

public enum GeminiDataSource {
    public struct ProjectIndex: Sendable, Hashable {
        public let slugToPath: [String: String]

        public init(slugToPath: [String: String]) {
            self.slugToPath = slugToPath
        }

        public static let empty = ProjectIndex(slugToPath: [:])
    }

    public static func discoverChatFiles(
        rootDirectory: String = "~/.gemini",
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let expandedRoot = CodexDataSource.expandHome(in: rootDirectory)
        let tmpRoot = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: tmpRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        guard let enumerator = fileManager.enumerator(
            at: tmpRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard !isDirectoryURL(url) else { continue }
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent == "chats" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func loadProjectIndex(
        rootDirectory: String = "~/.gemini",
        fileManager: FileManager = .default
    ) -> ProjectIndex {
        let expandedRoot = CodexDataSource.expandHome(in: rootDirectory)
        let projectsURL = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: projectsURL),
              let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = rootObject["projects"] as? [String: Any] else {
            return .empty
        }

        var slugToPath: [String: String] = [:]
        let sortedEntries = projects
            .compactMap { entry -> (path: String, slug: String)? in
                guard let slug = entry.value as? String else { return nil }
                let path = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, !cleanSlug.isEmpty else { return nil }
                return (path: path, slug: cleanSlug)
            }
            .sorted { lhs, rhs in lhs.path < rhs.path }

        for entry in sortedEntries where slugToPath[entry.slug] == nil {
            let _ = fileManager.fileExists(atPath: entry.path)
            slugToPath[entry.slug] = entry.path
        }

        return ProjectIndex(slugToPath: slugToPath)
    }

    public static func resolveProject(
        forSlug slug: String,
        rootDirectory: String = "~/.gemini",
        projectIndex: ProjectIndex,
        fileManager: FileManager = .default
    ) -> (projectName: String, projectPath: String) {
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)

        if let indexedPath = projectIndex.slugToPath[cleanSlug], !indexedPath.isEmpty {
            return (projectName: projectName(fromPath: indexedPath), projectPath: indexedPath)
        }

        let expandedRoot = CodexDataSource.expandHome(in: rootDirectory)
        let markerURL = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(cleanSlug, isDirectory: true)
            .appendingPathComponent(".project_root")

        if fileManager.fileExists(atPath: markerURL.path),
           let raw = try? String(contentsOf: markerURL, encoding: .utf8) {
            let markerPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !markerPath.isEmpty {
                return (projectName: projectName(fromPath: markerPath), projectPath: markerPath)
            }
        }

        if cleanSlug.isEmpty {
            return (projectName: "unknown", projectPath: "")
        }
        return (projectName: cleanSlug, projectPath: "")
    }

    private static func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func projectName(fromPath path: String) -> String {
        let candidate = URL(fileURLWithPath: path).lastPathComponent
        return candidate.isEmpty ? path : candidate
    }
}
