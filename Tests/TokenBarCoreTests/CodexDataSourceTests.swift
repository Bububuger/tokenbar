import Foundation
import Testing
@testable import TokenBarCore

struct CodexDataSourceTests {
    @Test
    func discoveryFindsRecentRolloutFilesOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!

        let recentOne = try writeRollout(root: root, date: referenceDate, name: "rollout-a.jsonl")
        let recentTwo = try writeRollout(root: root, date: calendar.date(byAdding: .day, value: -7, to: referenceDate)!, name: "rollout-b.jsonl")
        _ = try writeRollout(root: root, date: calendar.date(byAdding: .day, value: -45, to: referenceDate)!, name: "rollout-old.jsonl")
        _ = try writeNonRollout(root: root, date: referenceDate, name: "notes.txt")

        let urls = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: root.path,
            referenceDate: referenceDate,
            daysBack: 30,
            calendar: calendar
        )

        let actual = urls.map(\.standardizedFileURL)
        let expected = [recentTwo, recentOne]
            .map(\.standardizedFileURL)
            .sorted(by: { $0.path < $1.path })

        #expect(actual == expected)
    }

    @Test
    func discoveryExpandsHomePrefix() throws {
        let expanded = CodexDataSource.expandHome(in: "~/.codex/sessions")
        #expect(expanded.hasPrefix(NSHomeDirectory()))
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: root,
            create: true
        )
    }

    private func writeRollout(root: URL, date: Date, name: String) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let dir = root
            .appendingPathComponent(String(components.year!))
            .appendingPathComponent(String(format: "%02d", components.month!))
            .appendingPathComponent(String(format: "%02d", components.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func writeNonRollout(root: URL, date: Date, name: String) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let dir = root
            .appendingPathComponent(String(components.year!))
            .appendingPathComponent(String(format: "%02d", components.month!))
            .appendingPathComponent(String(format: "%02d", components.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "notes\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
