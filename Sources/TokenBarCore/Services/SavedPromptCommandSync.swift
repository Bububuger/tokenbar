import Foundation

public struct SavedPromptCommandSync: Sendable {
    private let commandsRoot: URL

    public init(commandsRoot: URL = SavedPromptCommandSync.defaultCommandsRoot()) {
        self.commandsRoot = commandsRoot
    }

    public static func defaultCommandsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let commandsBase = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
        let tbarRoot = commandsBase.appendingPathComponent("tbar", isDirectory: true)
        let legacyRoot = commandsBase.appendingPathComponent("tb", isDirectory: true)
        SavedPromptCommandSync.migrateLegacyDirectoryIfNeeded(
            legacy: legacyRoot,
            target: tbarRoot
        )
        return tbarRoot
    }

    /// One-time migration: if the legacy `~/.claude/commands/tb/` exists and
    /// the new `~/.claude/commands/tbar/` does not, rename the directory in
    /// place so existing saved prompts surface as `/tbar:<slug>` instead of
    /// `/tb:<slug>`. Safe to call repeatedly; becomes a no-op once the new
    /// directory exists. Errors are swallowed because this is best-effort —
    /// the caller still needs a usable root URL regardless.
    static func migrateLegacyDirectoryIfNeeded(legacy: URL, target: URL) {
        let fileManager = FileManager.default
        var legacyIsDirectory: ObjCBool = false
        var targetIsDirectory: ObjCBool = false
        let legacyExists = fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory)
        let targetExists = fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
        guard legacyExists, legacyIsDirectory.boolValue, !targetExists else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: target)
        } catch {
            // Best-effort. If the move fails, leave both directories alone
            // so the user can investigate manually.
        }
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

    public func removeAll() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: commandsRoot.path) else {
            return
        }
        let files = try fileManager.contentsOfDirectory(
            at: commandsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where file.pathExtension == "md" {
            try fileManager.removeItem(at: file)
        }
    }

    private func removeIfPresent(slug: String) throws {
        let fileManager = FileManager.default
        let url = fileURL(forSlug: slug)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(forSlug slug: String) -> URL {
        let sanitized = slug
            .replacingOccurrences(of: "..", with: "")
            .replacingOccurrences(of: "/", with: "-")
        return commandsRoot.appendingPathComponent("\(sanitized).md")
    }

    /// Serialize a SavedPrompt to the on-disk slash-command file format.
    /// Frontmatter keys are written in stable order: `description`, then
    /// `argument-hint` (if present), then `allowed-tools` (if non-empty).
    /// Unset optional fields are omitted entirely — `argumentHint == nil`
    /// produces no `argument-hint:` line at all so old prompts roundtrip
    /// byte-for-byte.
    private func render(_ prompt: SavedPrompt) -> String {
        let description = prompt.title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        var lines: [String] = ["---", "description: \(description)"]

        if let hint = prompt.argumentHint, !hint.isEmpty {
            lines.append("argument-hint: \(hint)")
        }

        if !prompt.allowedTools.isEmpty {
            // Comma-separated bracket form: `[Read, Bash]`. Whitespace after
            // comma keeps it readable in `cat` and survives YAML parsing.
            let inner = prompt.allowedTools.joined(separator: ", ")
            lines.append("allowed-tools: [\(inner)]")
        }

        lines.append("---")
        let frontmatter = lines.joined(separator: "\n") + "\n"
        return frontmatter + prompt.body
    }
}
