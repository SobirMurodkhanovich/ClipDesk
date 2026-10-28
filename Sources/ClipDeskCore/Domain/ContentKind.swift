import Foundation

/// The primary kind of content captured by a history entry.
public enum ContentKind: String, Sendable, Codable, CaseIterable {
    case text
    case code
    case link
    case image
    case file
    case other

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .code: "Code"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .other: "Data"
        }
    }

    public var isTextual: Bool {
        switch self {
        case .text, .code, .link: true
        case .image, .file, .other: false
        }
    }
}

/// Sidebar categories. Each category is a filter over history entries.
public enum HistoryCategory: String, Sendable, CaseIterable, Identifiable {
    case all
    case text
    case images
    case screenshots
    case files
    case favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All Items"
        case .text: "Text"
        case .images: "Images"
        case .screenshots: "Screenshots"
        case .files: "Files"
        case .favorites: "Favorites"
        }
    }

    /// Whether an entry belongs to this category. Mirrors `sqlPredicate`.
    public func includes(_ entry: ClipEntry) -> Bool {
        switch self {
        case .all: true
        case .text: entry.kind.isTextual
        case .images: entry.kind == .image && !entry.isScreenshot
        case .screenshots: entry.isScreenshot
        case .files: entry.kind == .file
        case .favorites: entry.isFavorite
        }
    }

    /// SQL filter over the `entries` table. Contains no user input.
    var sqlPredicate: String {
        switch self {
        case .all: "1"
        case .text: "kind IN ('text', 'code', 'link')"
        case .images: "kind = 'image' AND is_screenshot = 0"
        case .screenshots: "is_screenshot = 1"
        case .files: "kind = 'file'"
        case .favorites: "is_favorite = 1"
        }
    }
}

/// Number of entries in each sidebar category.
public struct CategoryCounts: Sendable, Equatable {
    public var values: [HistoryCategory: Int]

    public init(values: [HistoryCategory: Int] = [:]) {
        self.values = values
    }

    public subscript(category: HistoryCategory) -> Int {
        values[category] ?? 0
    }

    public static let zero = CategoryCounts()
}
