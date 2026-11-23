import Foundation
import Testing
@testable import TokenBarCore

struct PiDataSourceTests {
    @Test
    func discoveryIncludesJsonlOneDirectoryUnderTheCwdDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-discover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cwdDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("-Users-me-work-observ", isDirectory: true)
        let mainSessionDir = cwdDir.appendingPathComponent("20261001_main-session", isDirectory: true)
        let deeperDir = mainSessionDir.appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: deeperDir, withIntermediateDirectories: true)

        let mainFile = cwdDir.appendingPathComponent("20261001_main-session.jsonl")
        let advisorFile = mainSessionDir.appendingPathComponent("advisor.jsonl")
        let workerFile = mainSessionDir.appendingPathComponent("worker.jsonl")
        let noteFile = cwdDir.appendingPathComponent("notes.txt")
        let tooDeepFile = deeperDir.appendingPathComponent("too-deep.jsonl")
        for url in [mainFile, advisorFile, workerFile, noteFile, tooDeepFile] {
            try Data("{}".utf8).write(to: url)
        }

        let discovered = try PiDataSource.discoverSessionFiles(rootDirectory: root.path)

        #expect(discovered.map(\.standardizedFileURL.path).sorted() == [
            mainFile, advisorFile, workerFile,
        ].map(\.standardizedFileURL.path).sorted())
    }
}
