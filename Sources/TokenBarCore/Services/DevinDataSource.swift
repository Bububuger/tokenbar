import Foundation
import GRDB

/// Discovers Devin CLI transcripts and the session → project map.
///
/// Root: `$XDG_DATA_HOME/devin/cli` (default `~/.local/share/devin/cli`).
/// Transcripts live at `transcripts/*.json` (ATIF schema, append-only in
/// practice); `sessions.db` maps `sessions.id` (transcript
/// `session_id`) to `working_directory`. Both are read strictly
/// read-only; a missing or busy database degrades to "unknown" project
/// attribution plus one warning instead of failing the source.
public enum DevinDataSource {
    public struct ProjectIndex: Sendable, Hashable {
        public let sessionToPath: [String: String]
        public init(sessionToPath: [String: String]) {
            self.sessionToPath = sessionToPath
        }
        public static let empty = ProjectIndex(sessionToPath: [:])
    }

    public static func resolvedRootDirectory(
        rootDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let rootDirectory {
            return expandHome(in: rootDirectory, homeDirectory: homeDirectory)
        }
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "~/.local/share"
        let expanded = expandHome(in: dataHome, homeDirectory: homeDirectory)
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent("devin/cli", isDirectory: true)
            .path
    }

    public static func discoverTranscriptFiles(
        rootDirectory: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> [URL] {
        let root = resolvedRootDirectory(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return try DiscoveryCache.cached(key: "devin|\(root)") {
            let transcripts = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true)

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: transcripts.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                    at: transcripts,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return []
            }

            var files: [URL] = []
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
                files.append(url)
            }
            return files.sorted { $0.path < $1.path }
        }
    }

    /// Single read-only query over `sessions.db`. Returns the index and the
    /// read failure (if any) so the caller can surface one warning instead of
    /// silently attributing every session to "unknown".
    public static func loadProjectIndex(
        rootDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> (index: ProjectIndex, readError: String?) {
        let root = resolvedRootDirectory(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        let databaseURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("sessions.db")

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return (index: .empty, readError: "sessions database not found at \(databaseURL.path)")
        }

        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            var sessionToPath: [String: String] = [:]
            try queue.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, working_directory FROM sessions")
                for row in rows {
                    let id = (row["id"] as String?) ?? ""
                    let path = (row["working_directory"] as String?) ?? ""
                    if !id.isEmpty, !path.isEmpty {
                        sessionToPath[id] = path
                    }
                }
            }
            return (index: ProjectIndex(sessionToPath: sessionToPath), readError: nil)
        } catch {
            return (index: .empty, readError: error.localizedDescription)
        }
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
