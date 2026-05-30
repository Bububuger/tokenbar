import Foundation
import Testing
@testable import TokenBarCore

struct McpScannerTests {
    private func writeMcpJson(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcptest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test
    func scanProjectMcpJsonReadsServersAndDisabledState() async throws {
        let root = try writeMcpJson("""
        {
          "mcpServers": {
            "alpha": { "type": "stdio", "command": "utoo-proxy", "args": ["x", "-t", "SSE"], "env": {} },
            "beta":  { "type": "stdio", "command": "node", "args": ["server.js"], "env": { "TOKEN": "z" } }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = McpScanner()
        let servers = try await scanner.scanProjectMcpJson(projectRoot: root, disabledNames: ["beta"])

        #expect(servers.count == 2)
        let alpha = try #require(servers.first { $0.name == "alpha" })
        let beta = try #require(servers.first { $0.name == "beta" })
        #expect(alpha.scope == .project)
        #expect(alpha.isDisabled == false)
        #expect(alpha.projectRoot == root.path)
        #expect(alpha.sourceFile.lastPathComponent == ".mcp.json")
        #expect(beta.isDisabled == true)
        #expect(beta.envKeys == ["TOKEN"])
    }

    @Test
    func scanProjectMcpJsonReturnsEmptyWhenNoFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcptest-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scanner = McpScanner()
        let servers = try await scanner.scanProjectMcpJson(projectRoot: dir, disabledNames: [])
        #expect(servers.isEmpty)
    }

    @Test
    func deleteServerRemovesEntryAndPreservesOthers() throws {
        let root = try writeMcpJson("""
        {
          "mcpServers": {
            "alpha": { "command": "a" },
            "beta":  { "command": "b" }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent(".mcp.json")

        try McpConfigEditor.deleteServer(name: "alpha", configFile: configFile)

        let data = try Data(contentsOf: configFile)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(servers["alpha"] == nil)
        #expect(servers["beta"] != nil)
    }

    @Test
    func deleteServerPreservesUnrelatedTopLevelKeys() throws {
        // ~/.claude.json has many sibling keys; deletion must not drop them.
        let root = try writeMcpJson("""
        {
          "someOtherKey": 42,
          "nested": { "a": 1 },
          "mcpServers": { "alpha": { "command": "a" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent(".mcp.json")

        try McpConfigEditor.deleteServer(name: "alpha", configFile: configFile)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any])
        #expect(json["someOtherKey"] as? Int == 42)
        #expect(json["nested"] != nil)
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(servers.isEmpty)
    }

    @Test
    func deleteServerThrowsWhenServerMissing() throws {
        let root = try writeMcpJson("""
        { "mcpServers": { "alpha": { "command": "a" } } }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent(".mcp.json")

        #expect(throws: McpConfigEditor.EditError.self) {
            try McpConfigEditor.deleteServer(name: "ghost", configFile: configFile)
        }
    }
}
