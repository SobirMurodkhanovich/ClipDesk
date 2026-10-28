import Foundation

/// One clipboard operation in history.
///
/// An entry may contain several pasteboard items (`itemCount`), and each item may carry
/// several representations of the same content (for example plain text, RTF and HTML).
/// File entries additionally describe each referenced file in `files`.
public struct ClipEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: ContentKind
    public var isScreenshot: Bool
    public var title: String
    /// Short text used by list rows. The full text is loaded on demand.
    public var previewText: String
    /// When the content was first captured.
    public var createdAt: Date
    /// Most recent activity: a new capture of identical content, or a copy back to the clipboard.
    /// History is ordered by this value.
    public var lastUsedAt: Date
    /// How many times the content was captured or copied back from history.
    public var useCount: Int
    public var isFavorite: Bool
    /// Total bytes of retained payloads (representations and managed file copies).
    public var byteCount: Int64
    public var itemCount: Int
    /// Distinct pasteboard types retained for this entry, in capture order.
    public var typeIdentifiers: [String]
    public var thumbnailURL: URL?
    public var sourceApp: SourceApplication?
    public var metadata: EntryMetadata
    public var files: [ClipFile]

    public init(
        id: UUID,
        kind: ContentKind,
        isScreenshot: Bool,
        title: String,
        previewText: String,
        createdAt: Date,
        lastUsedAt: Date,
        useCount: Int,
        isFavorite: Bool,
        byteCount: Int64,
        itemCount: Int,
        typeIdentifiers: [String],
        thumbnailURL: URL?,
        sourceApp: SourceApplication?,
        metadata: EntryMetadata,
        files: [ClipFile]
    ) {
        self.id = id
        self.kind = kind
        self.isScreenshot = isScreenshot
        self.title = title
        self.previewText = previewText
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isFavorite = isFavorite
        self.byteCount = byteCount
        self.itemCount = itemCount
        self.typeIdentifiers = typeIdentifiers
        self.thumbnailURL = thumbnailURL
        self.sourceApp = sourceApp
        self.metadata = metadata
        self.files = files
    }

    /// Label shown in row subtitles, e.g. "Text", "Screenshot", "3 Files".
    public var kindLabel: String {
        if isScreenshot { return "Screenshot" }
        if kind == .file && files.count > 1 { return "\(files.count) Files" }
        return kind.displayName
    }

    /// Whether every referenced file is gone (neither original nor managed copy exists).
    public var hasUnavailableFiles: Bool {
        files.contains { $0.availability == .unavailable }
    }
}

/// The application that was frontmost when content was captured. Best effort only:
/// macOS does not report which process wrote to the pasteboard.
public struct SourceApplication: Hashable, Sendable, Codable {
    public var name: String?
    public var bundleIdentifier: String?

    public init(name: String?, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Derived facts about an entry, stored as JSON alongside the entry row.
public struct EntryMetadata: Hashable, Sendable, Codable {
    public var characterCount: Int?
    public var wordCount: Int?
    public var lineCount: Int?
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    public var imageTypeIdentifier: String?
    /// Pasteboard types that were present but not retained (too large, unreadable or redundant).
    public var omittedTypes: [String]

    public init(
        characterCount: Int? = nil,
        wordCount: Int? = nil,
        lineCount: Int? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        imageTypeIdentifier: String? = nil,
        omittedTypes: [String] = []
    ) {
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.lineCount = lineCount
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.imageTypeIdentifier = imageTypeIdentifier
        self.omittedTypes = omittedTypes
    }
}

/// A file referenced by a file entry.
///
/// A reference (`originalURL`) is distinct from a managed copy (`storedCopyURL`): ClipDesk keeps a
/// copy of the file's contents only when it is readable and within the configured size limit.
public struct ClipFile: Hashable, Sendable, Identifiable {
    public var id: Int { position }
    public var position: Int
    public var originalURL: URL
    public var fileName: String
    public var typeIdentifier: String?
    public var byteSize: Int64?
    public var isDirectory: Bool
    public var modifiedAt: Date?
    public var storedCopyURL: URL?
    public var storage: FileStorageState
    public var availability: FileAvailability

    public init(
        position: Int,
        originalURL: URL,
        fileName: String,
        typeIdentifier: String?,
        byteSize: Int64?,
        isDirectory: Bool,
        modifiedAt: Date?,
        storedCopyURL: URL?,
        storage: FileStorageState,
        availability: FileAvailability
    ) {
        self.position = position
        self.originalURL = originalURL
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
        self.byteSize = byteSize
        self.isDirectory = isDirectory
        self.modifiedAt = modifiedAt
        self.storedCopyURL = storedCopyURL
        self.storage = storage
        self.availability = availability
    }

    /// The URL to use when restoring or previewing: the original when it still exists,
    /// otherwise the managed copy.
    public var bestAvailableURL: URL? {
        switch availability {
        case .original: originalURL
        case .storedCopy: storedCopyURL
        case .unavailable: nil
        }
    }

    public var fileExtension: String {
        (fileName as NSString).pathExtension
    }
}

/// Whether ClipDesk kept a managed copy of a file, and if not, why.
public enum FileStorageState: String, Sendable, Codable {
    case copied
    case tooLarge
    case directory
    case unreadable
    case copyingDisabled
    case missing

    public var explanation: String {
        switch self {
        case .copied: "A copy is stored by ClipDesk."
        case .tooLarge: "Larger than the storage limit; only a reference is kept."
        case .directory: "Folders are kept as references, not copied."
        case .unreadable: "ClipDesk could not read the file; only a reference is kept."
        case .copyingDisabled: "File copies are turned off in Settings; only a reference is kept."
        case .missing: "The file did not exist when it was copied."
        }
    }
}

/// Current availability of a referenced file, evaluated when history is loaded.
public enum FileAvailability: String, Sendable, Codable {
    /// The original file exists at its recorded location.
    case original
    /// The original is gone but ClipDesk's managed copy exists.
    case storedCopy
    /// Neither the original nor a managed copy exists.
    case unavailable
}
