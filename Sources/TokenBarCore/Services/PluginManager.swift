import Foundation

public actor PluginManager {
    private let store: UsageStore
    private let fileManager: FileManager

    public init(store: UsageStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public static var pluginsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TokenBar/plugins", isDirectory: true)
    }

    public static func pluginDirectory(for pluginId: String) -> URL {
        pluginsRoot.appendingPathComponent(pluginId, isDirectory: true)
    }

    public func install(manifest: PluginManifest, manifestData: Data, attachments: [(name: String, data: Data)] = []) async throws {
        try manifest.validate()

        let dir = Self.pluginDirectory(for: manifest.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifestURL = dir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)

        for attachment in attachments {
            let attachmentURL = dir.appendingPathComponent(attachment.name)
            try attachment.data.write(to: attachmentURL)
            if attachment.name.hasSuffix(".py") || attachment.name.hasSuffix(".sh") {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: attachmentURL.path)
            }
        }

        let record = manifestToRecord(manifest)
        try await store.upsertCustomSource(record)
    }

    public func uninstall(pluginId: String) async throws {
        let sources = try await store.customSources()
        for source in sources where source.pluginId == pluginId {
            try await store.deleteCustomSource(id: source.id)
        }

        let dir = Self.pluginDirectory(for: pluginId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    public func update(manifest: PluginManifest, manifestData: Data, attachments: [(name: String, data: Data)] = []) async throws {
        try await uninstall(pluginId: manifest.id)
        try await install(manifest: manifest, manifestData: manifestData, attachments: attachments)
    }

    public nonisolated func installedManifests() -> [PluginManifest] {
        let root = Self.pluginsRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { dir -> PluginManifest? in
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            return try? JSONDecoder().decode(PluginManifest.self, from: data)
        }
    }

    public nonisolated func manifestToRecord(_ manifest: PluginManifest) -> CustomSourceRecord {
        switch manifest.source {
        case .jsonl(let src):
            return CustomSourceRecord(
                id: "plugin-\(manifest.id)",
                name: manifest.name,
                engine: .claudeCode,
                directory: src.directory,
                globPattern: src.glob,
                format: .unknown,
                displayAgent: manifest.name,
                enabled: true,
                fieldMapping: src.fields.toCustomSourceFieldMapping(),
                pluginId: manifest.id,
                pluginVersion: manifest.version,
                inputIncludesCached: manifest.inputIncludesCached,
                timestampFormat: manifest.timestampFormat
            )
        case .sqlite(let src):
            return CustomSourceRecord(
                id: "plugin-\(manifest.id)",
                name: manifest.name,
                engine: .pluginSqlite,
                directory: src.directory,
                globPattern: src.glob,
                format: .unknown,
                displayAgent: manifest.name,
                enabled: true,
                fieldMapping: src.query.columns.toCustomSourceFieldMapping(),
                pluginId: manifest.id,
                pluginVersion: manifest.version,
                inputIncludesCached: manifest.inputIncludesCached,
                timestampFormat: manifest.timestampFormat,
                sqliteQuery: src.query
            )
        case .executable(let src):
            return CustomSourceRecord(
                id: "plugin-\(manifest.id)",
                name: manifest.name,
                engine: .pluginExecutable,
                directory: Self.pluginDirectory(for: manifest.id).path,
                globPattern: "*",
                format: .unknown,
                displayAgent: manifest.name,
                enabled: true,
                pluginId: manifest.id,
                pluginVersion: manifest.version,
                inputIncludesCached: manifest.inputIncludesCached,
                timestampFormat: manifest.timestampFormat,
                executableConfig: src
            )
        }
    }
}
