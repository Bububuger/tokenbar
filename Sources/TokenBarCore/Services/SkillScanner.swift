import Foundation

public actor SkillScanner {
    private static let maxFrontmatterBytes = 8192

    public init() {}

    public func scanScope(_ scope: LibraryScope, root: URL, pluginId: String? = nil) throws -> [ScannedSkill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        var visited = Set<String>()
        var results: [ScannedSkill] = []
        let now = Date()

        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = resourceValues.isSymbolicLink ?? false
            let isDirectory: Bool

            if isSymlink {
                let resolved = item.resolvingSymlinksInPath()
                let canonical = resolved.standardizedFileURL.path
                if visited.contains(canonical) { continue }
                visited.insert(canonical)

                let targetExists = fm.fileExists(atPath: resolved.path)
                if !targetExists {
                    results.append(ScannedSkill(
                        scope: scope,
                        scopeRoot: root,
                        name: item.lastPathComponent,
                        path: item,
                        isSymlink: true,
                        resolvedTarget: resolved,
                        isBroken: true,
                        sizeBytes: 0,
                        estimatedTokens: 0,
                        description: nil,
                        allowedTools: nil,
                        pluginId: pluginId,
                        modifiedAt: now,
                        scannedAt: now
                    ))
                    continue
                }
                var targetIsDir: ObjCBool = false
                fm.fileExists(atPath: resolved.path, isDirectory: &targetIsDir)
                isDirectory = targetIsDir.boolValue

                if isDirectory {
                    let skillMd = resolved.appendingPathComponent("SKILL.md")
                    guard fm.fileExists(atPath: skillMd.path) else { continue }
                    let (desc, tools) = parseFrontmatter(at: skillMd)
                    let size = recursiveSize(at: resolved, fm: fm, visited: &visited)
                    let mtime = modifiedDate(skillMd: skillMd, dir: resolved, fm: fm)
                    results.append(ScannedSkill(
                        scope: scope,
                        scopeRoot: root,
                        name: item.lastPathComponent,
                        path: item,
                        isSymlink: true,
                        resolvedTarget: resolved,
                        isBroken: false,
                        sizeBytes: size,
                        estimatedTokens: Int(size / 4),
                        description: desc,
                        allowedTools: tools,
                        pluginId: pluginId,
                        modifiedAt: mtime,
                        scannedAt: now
                    ))
                }
            } else {
                isDirectory = resourceValues.isDirectory ?? false
                if !isDirectory { continue }

                let canonical = item.standardizedFileURL.path
                if visited.contains(canonical) { continue }
                visited.insert(canonical)

                let skillMd = item.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillMd.path) else { continue }
                let (desc, tools) = parseFrontmatter(at: skillMd)
                let size = recursiveSize(at: item, fm: fm, visited: &visited)
                let mtime = modifiedDate(skillMd: skillMd, dir: item, fm: fm)
                results.append(ScannedSkill(
                    scope: scope,
                    scopeRoot: root,
                    name: item.lastPathComponent,
                    path: item,
                    isSymlink: false,
                    resolvedTarget: nil,
                    isBroken: false,
                    sizeBytes: size,
                    estimatedTokens: Int(size / 4),
                    description: desc,
                    allowedTools: tools,
                    pluginId: pluginId,
                    modifiedAt: mtime,
                    scannedAt: now
                ))
            }
        }

        return results.sorted { $0.name < $1.name }
    }

    /// Walks Claude Code's installed-plugin index and scans each plugin's
    /// `<installPath>/skills/` directory. Earlier this naively looked for
    /// `~/.claude/plugins/*/skills/` but real plugin install paths live
    /// under `cache/<marketplace>/<plugin>/<version>` or
    /// `marketplaces/<marketplace>/plugins/<plugin>` — only the manifest
    /// knows where each one actually is.
    public func scanPluginsRoot(_ pluginsRoot: URL) throws -> [ScannedSkill] {
        let fm = FileManager.default
        let manifestURL = pluginsRoot.appendingPathComponent("installed_plugins.json")
        guard fm.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [[String: Any]]] else { return [] }

        var all: [ScannedSkill] = []
        for (pluginKey, instances) in plugins {
            for inst in instances {
                guard let installPath = inst["installPath"] as? String, !installPath.isEmpty else { continue }
                let skillsRoot = URL(fileURLWithPath: installPath, isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
                let skills = (try? scanScope(.plugin, root: skillsRoot, pluginId: pluginKey)) ?? []
                all.append(contentsOf: skills)
            }
        }
        return all
    }

    public func collectSymlinkTargets(from skills: [ScannedSkill]) -> [URL] {
        skills.compactMap { $0.isSymlink && !$0.isBroken ? $0.resolvedTarget : nil }
    }

    private func parseFrontmatter(at url: URL) -> (description: String?, allowedTools: [String]?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: Self.maxFrontmatterBytes)
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }

        var description: String?
        var allowedTools: [String]?
        var foundEnd = false

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                foundEnd = true
                break
            }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "description":
                    description = value.isEmpty ? nil : value
                case "allowed-tools", "allowed_tools":
                    allowedTools = value
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                        .filter { !$0.isEmpty }
                default:
                    break
                }
            }
        }

        guard foundEnd else { return (nil, nil) }
        return (description, allowedTools)
    }

    private func recursiveSize(at dir: URL, fm: FileManager, visited: inout Set<String>) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                if visited.contains(resolved) {
                    enumerator.skipDescendants()
                    continue
                }
                visited.insert(resolved)
            }
            if resourceValues?.isDirectory == false {
                total += Int64(resourceValues?.fileSize ?? 0)
            }
        }
        return total
    }

    private func modifiedDate(skillMd: URL, dir: URL, fm: FileManager) -> Date {
        if let attrs = try? fm.attributesOfItem(atPath: skillMd.path),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime
        }
        if let attrs = try? fm.attributesOfItem(atPath: dir.path),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime
        }
        return Date()
    }
}
