import Foundation

public enum CodexDataSource {
    private static let defaultRootDirectory = "~/.codex/sessions"

    public static func discoverRolloutFiles(
        rootDirectory: String = "~/.codex/sessions",
        archiveRootDirectory: String? = nil,
        referenceDate: Date = Date(),
        daysBack: Int? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian),
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let cacheKey = "codex|\(rootDirectory)|\(archiveRootDirectory ?? "default")|\(daysBack.map(String.init) ?? "all")"
        return try DiscoveryCache.cached(key: cacheKey) {
            try uncachedDiscoverRolloutFiles(
                rootDirectory: rootDirectory,
                archiveRootDirectory: archiveRootDirectory,
                referenceDate: referenceDate,
                daysBack: daysBack,
                calendar: calendar,
                fileManager: fileManager
            )
        }
    }

    private static func uncachedDiscoverRolloutFiles(
        rootDirectory: String,
        archiveRootDirectory: String?,
        referenceDate: Date,
        daysBack: Int?,
        calendar: Calendar,
        fileManager: FileManager
    ) throws -> [URL] {
        let rootPath = expandHome(in: rootDirectory)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let rootIsArchive = rootURL.lastPathComponent == "archived_sessions"
        let archiveURL = resolvedArchiveURL(
            rootDirectory: rootDirectory,
            archiveRootDirectory: archiveRootDirectory
        )

        var urls: [URL] = []

        guard let daysBack else {
            if !rootIsArchive, let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    if contentsOfRolloutFiles(in: [url]).isEmpty {
                        continue
                    }
                    urls.append(url)
                }
            }

            if let archiveURL,
               let children = try? fileManager.contentsOfDirectory(
                   at: archiveURL,
                   includingPropertiesForKeys: nil,
                   options: [.skipsHiddenFiles]
               ) {
                let activeNames = Set(urls.map(\.lastPathComponent))
                urls.append(contentsOf: contentsOfRolloutFiles(in: children).filter {
                    !activeNames.contains($0.lastPathComponent)
                })
            }

            return urls.sorted { $0.path < $1.path }
        }

        var includedDatePrefixes: Set<String> = []
        let today = calendar.startOfDay(for: referenceDate)
        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let year = components.year ?? 0
            let month = components.month ?? 0
            let dayOfMonth = components.day ?? 0
            includedDatePrefixes.insert(String(format: "rollout-%04d-%02d-%02d", year, month, dayOfMonth))

            let dayDirectory = rootURL
                .appendingPathComponent(String(year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))

            guard !rootIsArchive,
                  let children = try? fileManager.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            urls.append(contentsOf: contentsOfRolloutFiles(in: children))
        }

        if let archiveURL,
           let children = try? fileManager.contentsOfDirectory(
               at: archiveURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            let activeNames = Set(urls.map(\.lastPathComponent))
            urls.append(contentsOf: contentsOfRolloutFiles(in: children).filter { url in
                !activeNames.contains(url.lastPathComponent)
                    && includedDatePrefixes.contains { url.lastPathComponent.hasPrefix($0) }
            })
        }

        return urls.sorted { $0.path < $1.path }
    }

    static func resolvedArchiveURL(rootDirectory: String, archiveRootDirectory: String?) -> URL? {
        if let archiveRootDirectory {
            return URL(
                fileURLWithPath: expandHome(in: archiveRootDirectory),
                isDirectory: true
            ).standardizedFileURL
        }
        let rootURL = URL(
            fileURLWithPath: expandHome(in: rootDirectory),
            isDirectory: true
        ).standardizedFileURL
        if rootURL.lastPathComponent == "archived_sessions" {
            return rootURL
        }
        let defaultRootURL = URL(
            fileURLWithPath: expandHome(in: defaultRootDirectory),
            isDirectory: true
        ).standardizedFileURL
        guard rootURL == defaultRootURL else {
            return nil
        }
        return rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
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

    private static func contentsOfRolloutFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        }
    }
}
