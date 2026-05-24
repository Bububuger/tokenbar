import Foundation

/// Versioning info surfaced to the popover footer / menubar dot.
public struct UpdateCheckResult: Sendable, Hashable {
    public let currentVersion: String
    public let latestVersion: String
    public let releaseURL: URL
    /// True iff `latestVersion` parses as a newer semver than `currentVersion`.
    public let isNewer: Bool

    public init(currentVersion: String, latestVersion: String, releaseURL: URL, isNewer: Bool) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.isNewer = isNewer
    }
}

/// Once-per-launch + once-per-24h GitHub-Releases-API ping. The single
/// outbound network call the app makes; everything else stays local. Users
/// can disable via `Settings → Updates` (UserDefaults key
/// `tokenbar.updateCheckEnabled`, default true).
public actor UpdateChecker {
    public static let defaultRepository = "Bububuger/tokenbar"
    public static let userDefaultsEnabledKey = "tokenbar.updateCheckEnabled"
    public static let userDefaultsLastCheckKey = "tokenbar.updateLastCheckedAt"

    private let repository: String
    private let session: URLSession
    private let bundle: Bundle
    private let userDefaults: UserDefaults

    public init(
        repository: String = UpdateChecker.defaultRepository,
        session: URLSession = .shared,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.session = session
        self.bundle = bundle
        self.userDefaults = userDefaults
    }

    /// Returns `nil` when the user has disabled the check, when the cached
    /// result is still fresh (< 24h), or when the GitHub call fails — all
    /// best-effort. Throws are swallowed so a network blip never trips an
    /// alert dialog.
    public func checkIfDue() async -> UpdateCheckResult? {
        guard isEnabled else { return nil }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 60 * 60 {
            return nil
        }
        let result = try? await fetchLatest()
        if result != nil {
            userDefaults.set(Date(), forKey: Self.userDefaultsLastCheckKey)
        }
        return result
    }

    /// Force-fetch — user clicked "Check now" or similar. Bypasses the 24h
    /// throttle but still respects the enabled flag.
    public func checkNow() async -> UpdateCheckResult? {
        guard isEnabled else { return nil }
        let result = try? await fetchLatest()
        if result != nil {
            userDefaults.set(Date(), forKey: Self.userDefaultsLastCheckKey)
        }
        return result
    }

    public var isEnabled: Bool {
        // Default-on: missing key counts as enabled.
        userDefaults.object(forKey: Self.userDefaultsEnabledKey) as? Bool ?? true
    }

    public var lastChecked: Date? {
        userDefaults.object(forKey: Self.userDefaultsLastCheckKey) as? Date
    }

    public var currentVersion: String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func fetchLatest() async throws -> UpdateCheckResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let tag = payload["tag_name"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let latestVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let releaseURL = (payload["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repository)/releases/latest")!
        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: releaseURL,
            isNewer: Self.compare(latestVersion, isNewerThan: currentVersion)
        )
    }

    /// Returns true iff `a` strictly greater than `b` under semver-style
    /// component comparison. Non-numeric pieces ("1.3.0-rc1") get coerced
    /// to 0 — release tags in this repo are plain x.y.z so far.
    public static func compare(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(aParts.count, bParts.count) {
            let lhs = i < aParts.count ? aParts[i] : 0
            let rhs = i < bParts.count ? bParts[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
