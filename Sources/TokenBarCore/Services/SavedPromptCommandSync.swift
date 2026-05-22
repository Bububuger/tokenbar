import Foundation

public struct SavedPromptCommandSync: Sendable {
    private let commandsRoot: URL

    public init(commandsRoot: URL = SavedPromptCommandSync.defaultCommandsRoot()) {
        self.commandsRoot = commandsRoot
    }

    public static func defaultCommandsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent("tb", isDirectory: true)
    }

    public func apply(_ prompt: SavedPrompt, previousSlug: String?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: commandsRoot, withIntermediateDirectories: true)
        if let previousSlug, previousSlug != prompt.slug {
            try removeIfPresent(slug: previousSlug)
        }
        let url = fileURL(forSlug: prompt.slug)
        let contents = render(prompt)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    public func remove(slug: String) throws {
        try removeIfPresent(slug: slug)
    }

    private func removeIfPresent(slug: String) throws {
        let fileManager = FileManager.default
        let url = fileURL(forSlug: slug)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(forSlug slug: String) -> URL {
        commandsRoot.appendingPathComponent("\(slug).md")
    }

    private func render(_ prompt: SavedPrompt) -> String {
        let description = prompt.title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let frontmatter = "---\ndescription: \(description)\n---\n"
        return frontmatter + prompt.body
    }
}
