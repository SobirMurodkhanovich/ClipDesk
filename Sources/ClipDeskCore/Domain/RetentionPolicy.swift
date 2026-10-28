import Foundation

/// Rules for automatically removing old history.
///
/// - Age is measured from `lastUsedAt`, so content that is copied again stays in history.
/// - Favorites are exempt from both the age limit and the entry limit; they are removed only
///   when the user deletes them or clears all data.
/// - `maxEntries` therefore limits the number of non-favorite entries.
public struct RetentionPolicy: Sendable, Equatable {
    public static let defaultMaxEntries = 100
    public static let defaultRetentionDays = 30

    public var maxEntries: Int
    /// Maximum age in days, or `nil` to keep entries regardless of age.
    public var maxAgeDays: Int?

    public init(maxEntries: Int, maxAgeDays: Int?) {
        self.maxEntries = max(1, maxEntries)
        self.maxAgeDays = maxAgeDays.map { max(1, $0) }
    }

    public static let `default` = RetentionPolicy(
        maxEntries: defaultMaxEntries,
        maxAgeDays: defaultRetentionDays
    )

    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var lastUsedAt: Date
        public var isFavorite: Bool

        public init(id: UUID, lastUsedAt: Date, isFavorite: Bool) {
            self.id = id
            self.lastUsedAt = lastUsedAt
            self.isFavorite = isFavorite
        }
    }

    /// Returns the IDs that should be removed, oldest first.
    public func entriesToRemove(from candidates: [Candidate], now: Date = Date()) -> [UUID] {
        let removable = candidates
            .filter { !$0.isFavorite }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }

        var expired: [UUID] = []
        var kept: [Candidate] = []
        if let maxAgeDays {
            let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeDays) * 86_400)
            for candidate in removable {
                if candidate.lastUsedAt < cutoff {
                    expired.append(candidate.id)
                } else {
                    kept.append(candidate)
                }
            }
        } else {
            kept = removable
        }

        let overflow = kept.count > maxEntries ? kept[maxEntries...].map(\.id) : []
        return (overflow + expired).reversed()
    }
}
