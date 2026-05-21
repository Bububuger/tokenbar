import Foundation

public enum CodexDataSource {
    public static func discoverRolloutFiles(
        rootDirectory: String = "~/.codex/sessions",
        referenceDate: Date = Date(),
        daysBack: Int = 30,
        calendar: Calendar = Calendar(identifier: .gregorian),
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let rootPath = expandHome(in: rootDirectory)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        var urls: [URL] = []
        let today = calendar.startOfDay(for: referenceDate)

        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let dayDirectory = rootURL
                .appendingPathComponent(String(components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))

            guard let children = try? fileManager.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            urls.append(contentsOf: contentsOfRolloutFiles(in: children))
        }

        return urls.sorted { $0.path < $1.path }
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

    private static func contentsOfRolloutFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        }
    }
}
