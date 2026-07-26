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
    func discoveryFindsAllRolloutFilesWhenWindowIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!

        let recent = try writeRollout(root: root, date: referenceDate, name: "rollout-recent.jsonl")
        let historical = try writeRollout(root: root, date: calendar.date(byAdding: .day, value: -90, to: referenceDate)!, name: "rollout-history.jsonl")
        _ = try writeNonRollout(root: root, date: referenceDate, name: "notes.txt")

        let urls = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: root.path,
            referenceDate: referenceDate,
            daysBack: nil,
            calendar: calendar
        )

        let actual = urls.map(\.standardizedFileURL)
        let expected = [historical, recent]
            .map(\.standardizedFileURL)
            .sorted(by: { $0.path < $1.path })

        #expect(actual == expected)
    }

    @Test
    func discoveryFindsFlatArchiveRolloutsByDateAndExcludesOutsideWindow() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let archive = parent.appendingPathComponent("archived_sessions", isDirectory: true)

        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let recent = try writeArchiveRollout(root: archive, date: referenceDate, suffix: "recent")
        let boundary = try writeArchiveRollout(root: archive, date: calendar.date(byAdding: .day, value: -2, to: referenceDate)!, suffix: "boundary")
        _ = try writeArchiveRollout(root: archive, date: calendar.date(byAdding: .day, value: -3, to: referenceDate)!, suffix: "old")

        let urls = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: archive.path,
            referenceDate: referenceDate,
            daysBack: 3,
            calendar: calendar
        )

        #expect(urls.map(\.standardizedFileURL) == [boundary, recent].map(\.standardizedFileURL).sorted { $0.path < $1.path })
    }

    @Test
    func customActiveRootDoesNotImplicitlyScanSiblingArchiveRoot() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let active = parent.appendingPathComponent("sessions", isDirectory: true)
        let archive = parent.appendingPathComponent("archived_sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let basename = "rollout-2026-04-27T12-00-00-shared.jsonl"
        let activeFile = try writeRollout(root: active, date: referenceDate, name: basename)
        _ = try writeArchiveRollout(root: archive, date: referenceDate, basename: basename)

        let urls = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: active.path,
            referenceDate: referenceDate,
            daysBack: 1,
            calendar: calendar
        )

        #expect(CodexUsageEventSource(rootPath: active.path).archiveRootPath == nil)
        #expect(urls.map(\.standardizedFileURL) == [activeFile.standardizedFileURL])
    }

    @Test
    func explicitArchiveRootIsMergedAndActiveBasenameWins() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let activeRoot = parent.appendingPathComponent("sessions", isDirectory: true)
        let archiveRoot = parent.appendingPathComponent("archived_sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let basename = "rollout-2026-04-27T12-00-00-shared.jsonl"
        let active = try writeRollout(root: activeRoot, date: referenceDate, name: basename)
        _ = try writeArchiveRollout(root: archiveRoot, date: referenceDate, basename: basename)
        let archiveOnly = try writeArchiveRollout(root: archiveRoot, date: referenceDate, suffix: "archive-only")

        let urls = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: activeRoot.path,
            archiveRootDirectory: archiveRoot.path,
            referenceDate: referenceDate,
            daysBack: 1,
            calendar: calendar
        )

        #expect(urls.map(\.standardizedFileURL) == [active, archiveOnly].map(\.standardizedFileURL).sorted { $0.path < $1.path })
    }

    @Test
    func defaultCodexSourceUsesBuiltInSessionsRootAndLeavesArchiveOverrideUnset() {
        let source = CodexUsageEventSource()

        #expect(source.rootPath == "~/.codex/sessions")
        #expect(source.archiveRootPath == "~/.codex/archived_sessions")
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

    private func writeArchiveRollout(root: URL, date: Date, suffix: String) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let basename = String(format: "rollout-%04d-%02d-%02dT12-00-00-%@.jsonl", components.year!, components.month!, components.day!, suffix)
        return try writeArchiveRollout(root: root, date: date, basename: basename)
    }

    private func writeArchiveRollout(root: URL, date: Date, basename: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(basename)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
