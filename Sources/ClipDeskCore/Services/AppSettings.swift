import Foundation
import Observation

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// User preferences, persisted in `UserDefaults`. Every setting here changes real behavior.
@MainActor
@Observable
public final class AppSettings {
    public static let historySizeOptions = [25, 50, 100, 200, 500, 1_000]
    /// Days; 0 means "never remove by age".
    public static let retentionOptions = [1, 7, 14, 30, 90, 365, 0]
    public static let itemSizeOptions = [10, 25, 50, 100, 250, 500]
    public static let pollingOptions: [Double] = [0.25, 0.5, 1, 2]

    private enum Key {
        static let captureEnabled = "captureEnabled"
        static let pollingInterval = "pollingInterval"
        static let maxHistoryEntries = "maxHistoryEntries"
        static let retentionDays = "retentionDays"
        static let maxItemSizeMB = "maxItemSizeMB"
        static let storeFileCopies = "storeFileCopies"
        static let ignorePrivacyMarkedContent = "ignorePrivacyMarkedContent"
        static let appearance = "appearance"
        static let showPreviewPanel = "showPreviewPanel"
        static let groupByDate = "groupByDate"
        static let hasDismissedWelcome = "hasDismissedWelcome"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var isCaptureEnabled: Bool {
        didSet { defaults.set(isCaptureEnabled, forKey: Key.captureEnabled) }
    }
    /// Seconds between pasteboard checks.
    public var pollingInterval: Double {
        didSet { defaults.set(pollingInterval, forKey: Key.pollingInterval) }
    }
    public var maxHistoryEntries: Int {
        didSet { defaults.set(maxHistoryEntries, forKey: Key.maxHistoryEntries) }
    }
    public var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }
    public var maxItemSizeMB: Int {
        didSet { defaults.set(maxItemSizeMB, forKey: Key.maxItemSizeMB) }
    }
    public var storeFileCopies: Bool {
        didSet { defaults.set(storeFileCopies, forKey: Key.storeFileCopies) }
    }
    public var ignorePrivacyMarkedContent: Bool {
        didSet { defaults.set(ignorePrivacyMarkedContent, forKey: Key.ignorePrivacyMarkedContent) }
    }
    public var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    public var showPreviewPanel: Bool {
        didSet { defaults.set(showPreviewPanel, forKey: Key.showPreviewPanel) }
    }
    public var groupByDate: Bool {
        didSet { defaults.set(groupByDate, forKey: Key.groupByDate) }
    }
    public var hasDismissedWelcome: Bool {
        didSet { defaults.set(hasDismissedWelcome, forKey: Key.hasDismissedWelcome) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCaptureEnabled = defaults.object(forKey: Key.captureEnabled) as? Bool ?? true
        pollingInterval = Self.closest(defaults.object(forKey: Key.pollingInterval) as? Double ?? 0.5, in: Self.pollingOptions)
        maxHistoryEntries = Self.closest(
            defaults.object(forKey: Key.maxHistoryEntries) as? Int ?? RetentionPolicy.defaultMaxEntries,
            in: Self.historySizeOptions
        )
        let days = defaults.object(forKey: Key.retentionDays) as? Int ?? RetentionPolicy.defaultRetentionDays
        retentionDays = Self.retentionOptions.contains(days) ? days : RetentionPolicy.defaultRetentionDays
        maxItemSizeMB = Self.closest(defaults.object(forKey: Key.maxItemSizeMB) as? Int ?? 100, in: Self.itemSizeOptions)
        storeFileCopies = defaults.object(forKey: Key.storeFileCopies) as? Bool ?? true
        ignorePrivacyMarkedContent = defaults.object(forKey: Key.ignorePrivacyMarkedContent) as? Bool ?? true
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        showPreviewPanel = defaults.object(forKey: Key.showPreviewPanel) as? Bool ?? true
        groupByDate = defaults.object(forKey: Key.groupByDate) as? Bool ?? true
        hasDismissedWelcome = defaults.bool(forKey: Key.hasDismissedWelcome)
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxEntries: maxHistoryEntries, maxAgeDays: retentionDays == 0 ? nil : retentionDays)
    }

    public var maxItemBytes: Int { maxItemSizeMB * 1_048_576 }

    public var capturePolicy: CapturePolicy {
        CapturePolicy(maxFileBytes: Int64(maxItemBytes), storeFileCopies: storeFileCopies)
    }

    public var readOptions: PasteboardReadOptions {
        PasteboardReadOptions(maxCaptureBytes: maxItemBytes, ignorePrivacyMarkedContent: ignorePrivacyMarkedContent)
    }

    private static func closest<T: Comparable & SignedNumeric>(_ value: T, in options: [T]) -> T {
        options.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}
