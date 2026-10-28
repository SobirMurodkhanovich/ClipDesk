import Foundation
import Testing
@testable import ClipDeskCore

@Suite("Retention policy")
struct RetentionPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func candidate(_ age: TimeInterval, favorite: Bool = false) -> RetentionPolicy.Candidate {
        .init(id: UUID(), lastUsedAt: now.addingTimeInterval(-age), isFavorite: favorite)
    }

    @Test func defaultsAre100EntriesAnd30Days() {
        #expect(RetentionPolicy.default.maxEntries == 100)
        #expect(RetentionPolicy.default.maxAgeDays == 30)
    }

    @Test func removesOldestEntriesBeyondLimit() {
        let entries = (0..<5).map { candidate(TimeInterval($0) * 60) }
        let removed = RetentionPolicy(maxEntries: 3, maxAgeDays: nil).entriesToRemove(from: entries.shuffled(), now: now)
        #expect(removed == [entries[4].id, entries[3].id])
    }

    @Test func favoritesAreExemptFromLimitAndAge() {
        let oldFavorite = candidate(400 * 86_400, favorite: true)
        let recent = (0..<3).map { candidate(TimeInterval($0)) }
        let removed = RetentionPolicy(maxEntries: 2, maxAgeDays: 30).entriesToRemove(from: [oldFavorite] + recent, now: now)
        #expect(removed == [recent[2].id])
    }

    @Test func removesExpiredEntries() {
        let fresh = candidate(29 * 86_400)
        let expired = candidate(31 * 86_400)
        let removed = RetentionPolicy(maxEntries: 100, maxAgeDays: 30).entriesToRemove(from: [fresh, expired], now: now)
        #expect(removed == [expired.id])
    }

    @Test func nilAgeKeepsOldEntries() {
        let ancient = candidate(3_000 * 86_400)
        #expect(RetentionPolicy(maxEntries: 10, maxAgeDays: nil).entriesToRemove(from: [ancient], now: now).isEmpty)
    }
}

@MainActor
@Suite("Settings")
struct AppSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ClipDeskTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsMatchSpecification() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.isCaptureEnabled)
            #expect(settings.maxHistoryEntries == 100)
            #expect(settings.retentionDays == 30)
            #expect(settings.maxItemSizeMB == 100)
            #expect(settings.storeFileCopies)
            #expect(settings.ignorePrivacyMarkedContent)
            #expect(settings.pollingInterval == 0.5)
            #expect(settings.retentionPolicy == .default)
            #expect(settings.capturePolicy.maxFileBytes == 100 * 1_048_576)
        }
    }

    @Test func valuesPersistAcrossInstances() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.isCaptureEnabled = false
            settings.maxHistoryEntries = 500
            settings.retentionDays = 0
            settings.maxItemSizeMB = 25
            settings.storeFileCopies = false
            settings.appearance = .dark

            let reloaded = AppSettings(defaults: defaults)
            #expect(!reloaded.isCaptureEnabled)
            #expect(reloaded.maxHistoryEntries == 500)
            #expect(reloaded.retentionPolicy.maxAgeDays == nil)
            #expect(reloaded.readOptions.maxCaptureBytes == 25 * 1_048_576)
            #expect(!reloaded.capturePolicy.storeFileCopies)
            #expect(reloaded.appearance == .dark)
        }
    }

    @Test func invalidStoredValuesAreNormalized() {
        withDefaults { defaults in
            defaults.set(7, forKey: "maxHistoryEntries")
            defaults.set(13, forKey: "retentionDays")
            defaults.set(9.0, forKey: "pollingInterval")
            let settings = AppSettings(defaults: defaults)
            #expect(AppSettings.historySizeOptions.contains(settings.maxHistoryEntries))
            #expect(settings.retentionDays == 30)
            #expect(settings.pollingInterval == 2)
        }
    }
}
