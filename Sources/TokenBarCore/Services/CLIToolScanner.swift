import Foundation

/// Scans well-known directories for CLI executables and classifies them.
/// NEVER executes any scanned binary (`--version`, `--help`, etc.) — that
/// triggers Gatekeeper / corporate security agents (StarPoint) and pops
/// confirmation dialogs. All metadata comes from static sources: brew JSON,
/// `man -f` (reads the whatis DB, doesn't launch anything), and filesystem
/// attributes.
public actor CLIToolScanner {
    private static let scanDirs: [(String, CLIToolSource)] = [
        ("/opt/homebrew/bin", .brew),
        ("/usr/local/bin", .brew),
        ("~/.local/bin", .manual),
        ("~/.cargo/bin", .cargo),
        ("~/.go/bin", .go),
        ("~/go/bin", .go),
    ]

    private static let internalNames: Set<String> = [
        "dima", "linkex", "odc-cli", "ssctl", "acli", "antcode",
        "cfuse", "codefuse", "dws", "spanory", "hermes", "ontology",
        "ontology-cli", "dataphin", "observ-cli", "utoo",
    ]

    private static let skipNames: Set<String> = [
        ".", "..", ".DS_Store",
    ]

    private static let skipPrefixes: Set<String> = [
        "libexec", "lib", "share", "etc", "include", "var",
    ]

    private static let skipSuffixes = [
        "-apple-darwin", "-linux-gnu", "-unknown-linux",
        "-x86_64", "-aarch64", "-arm64",
    ]

    public init() {}

    public func scan() async -> [ScannedCLITool] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var tools: [ScannedCLITool] = []
        var seen = Set<String>()

        let brewInfo = await loadBrewInfo()
        let outdatedNames = await loadBrewOutdated()

        for (template, defaultSource) in Self.scanDirs {
            let dirPath = template.hasPrefix("~")
                ? home + template.dropFirst()
                : template
            guard fm.fileExists(atPath: dirPath) else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for entry in entries {
                guard !Self.skipNames.contains(entry) else { continue }
                guard !Self.skipPrefixes.contains(where: { entry.hasPrefix($0) }) else { continue }
                guard !Self.skipSuffixes.contains(where: { entry.contains($0) }) else { continue }

                let fullPath = (dirPath as NSString).appendingPathComponent(entry)
                guard fm.isExecutableFile(atPath: fullPath) else { continue }
                guard !seen.contains(entry) else { continue }
                seen.insert(entry)

                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue { continue }

                let symTarget = resolveSymlink(fullPath)
                let source = classifySource(name: entry, path: fullPath, symTarget: symTarget, defaultSource: defaultSource, brewInfo: brewInfo)
                let category = classifyCategory(name: entry, path: fullPath, symTarget: symTarget, source: source)

                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = (attrs?[.size] as? Int64) ?? 0

                let info = brewInfo[entry]

                tools.append(ScannedCLITool(
                    name: entry,
                    path: fullPath,
                    symlinkTarget: symTarget,
                    version: info?["version"] as? String,
                    description: info?["desc"] as? String,
                    source: source,
                    category: category,
                    isOutdated: outdatedNames.contains(entry),
                    latestVersion: nil,
                    sizeBytes: size,
                    scannedAt: Date()
                ))
            }
        }

        return tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Classification

    private func classifySource(
        name: String,
        path: String,
        symTarget: String?,
        defaultSource: CLIToolSource,
        brewInfo: [String: [String: Any]]
    ) -> CLIToolSource {
        if brewInfo[name] != nil { return .brew }
        let target = symTarget ?? path
        if target.contains("/Cellar/") || target.contains("/homebrew/") { return .brew }
        if target.contains("/lib/node_modules/") || target.contains("/npm/") { return .npm }
        if target.contains("/.cargo/") { return .cargo }
        if target.contains("/go/bin/") || target.contains("/gopath/") { return .go }
        if target.contains("/pip") || target.contains("/python") { return .pip }
        return defaultSource
    }

    private func classifyCategory(
        name: String,
        path: String,
        symTarget: String?,
        source: CLIToolSource
    ) -> CLIToolCategory {
        if Self.internalNames.contains(name) { return .internal }
        let target = symTarget ?? path
        if target.contains("antcode") || target.contains("alipay") || target.contains("antgroup") {
            return .internal
        }
        if [.brew, .npm, .pip, .cargo, .go].contains(source) { return .community }
        return .custom
    }

    private func resolveSymlink(_ path: String) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
        return try? fm.destinationOfSymbolicLink(atPath: path)
    }

    // MARK: - Brew metadata (static, no binary execution)

    private func loadBrewInfo() async -> [String: [String: Any]] {
        guard let output = await runSafeProcess("/opt/homebrew/bin/brew", args: ["info", "--json=v2", "--installed"], timeout: 10) else {
            return [:]
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = json["formulae"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        for f in formulae {
            guard let name = f["name"] as? String else { continue }
            let version = (f["installed"] as? [[String: Any]])?.first?["version"] as? String
            result[name] = [
                "desc": f["desc"] as Any,
                "version": version as Any,
            ]
        }
        return result
    }

    private func loadBrewOutdated() async -> Set<String> {
        guard let output = await runSafeProcess("/opt/homebrew/bin/brew", args: ["outdated", "--json=v2"], timeout: 15) else {
            return []
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = json["formulae"] as? [[String: Any]] else {
            return []
        }
        return Set(formulae.compactMap { $0["name"] as? String })
    }

    // MARK: - Process helper (only for brew)

    private func runSafeProcess(_ path: String, args: [String], timeout: TimeInterval) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
