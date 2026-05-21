import Foundation

public final class SettingsStore: @unchecked Sendable {
    private enum Keys {
        static let refreshInterval = "tokenbar.refreshInterval"
        static let keepDataOnThisMac = "tokenbar.keepDataOnThisMac"
        static let storePromptTextInClearText = "tokenbar.storePromptTextInClearText"
        static let usePromptFingerprintsByDefault = "tokenbar.usePromptFingerprintsByDefault"
        static let retentionWindow = "tokenbar.retentionWindow"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        registerDefaults()
    }

    public var refreshInterval: RefreshIntervalOption {
        get {
            let rawValue = userDefaults.string(forKey: Keys.refreshInterval) ?? RefreshIntervalOption.fiveMinutes.rawValue
            return RefreshIntervalOption(rawValue: rawValue) ?? .fiveMinutes
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.refreshInterval)
        }
    }

    public var keepDataOnThisMac: Bool {
        get { userDefaults.bool(forKey: Keys.keepDataOnThisMac) }
        set { userDefaults.set(newValue, forKey: Keys.keepDataOnThisMac) }
    }

    public var storePromptTextInClearText: Bool {
        get { userDefaults.bool(forKey: Keys.storePromptTextInClearText) }
        set { userDefaults.set(newValue, forKey: Keys.storePromptTextInClearText) }
    }

    public var usePromptFingerprintsByDefault: Bool {
        get { userDefaults.bool(forKey: Keys.usePromptFingerprintsByDefault) }
        set { userDefaults.set(newValue, forKey: Keys.usePromptFingerprintsByDefault) }
    }

    public var retentionWindow: String {
        get { userDefaults.string(forKey: Keys.retentionWindow) ?? "Forever" }
        set { userDefaults.set(newValue, forKey: Keys.retentionWindow) }
    }

    private func registerDefaults() {
        userDefaults.register(defaults: [
            Keys.refreshInterval: RefreshIntervalOption.fiveMinutes.rawValue,
            Keys.keepDataOnThisMac: true,
            Keys.storePromptTextInClearText: false,
            Keys.usePromptFingerprintsByDefault: true,
            Keys.retentionWindow: "Forever",
        ])
    }
}
