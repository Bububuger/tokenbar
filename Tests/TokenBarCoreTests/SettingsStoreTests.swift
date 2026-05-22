import Foundation
import Testing
@testable import TokenBarCore

struct SettingsStoreTests {
    @Test
    func settingsPersistAcrossStoreInstances() {
        let suiteName = "tokenbar.settings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let writer = SettingsStore(userDefaults: defaults)
        writer.refreshInterval = .manualOnly
        writer.keepDataOnThisMac = true
        writer.storePromptTextInClearText = false
        writer.usePromptFingerprintsByDefault = true
        writer.retentionWindow = "90d"
        writer.archivedProjectNames = ["my-cli-tool", "tokenbar"]

        let reader = SettingsStore(userDefaults: defaults)

        #expect(reader.refreshInterval == .manualOnly)
        #expect(reader.keepDataOnThisMac)
        #expect(!reader.storePromptTextInClearText)
        #expect(reader.usePromptFingerprintsByDefault)
        #expect(reader.retentionWindow == "90d")
        #expect(reader.archivedProjectNames == Set(["my-cli-tool", "tokenbar"]))
    }

    @Test
    func defaultSettingsMatchMvpPlan() {
        let suiteName = "tokenbar.settings.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.refreshInterval == .fiveMinutes)
        #expect(store.keepDataOnThisMac)
        #expect(store.storePromptTextInClearText)
        #expect(store.usePromptFingerprintsByDefault)
        #expect(store.retentionWindow == "Forever")
        #expect(store.archivedProjectNames.isEmpty)
    }
}
