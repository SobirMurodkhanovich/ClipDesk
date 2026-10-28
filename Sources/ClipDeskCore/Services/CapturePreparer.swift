import CryptoKit
import Foundation

/// Limits applied when a capture is stored.
public struct CapturePolicy: Sendable, Equatable {
    /// Files larger than this are kept as references instead of being copied.
    public var maxFileBytes: Int64
    /// Whether to keep managed copies of copied files at all.
    public var storeFileCopies: Bool

    public init(maxFileBytes: Int64, storeFileCopies: Bool) {
        self.maxFileBytes = maxFileBytes
        self.storeFileCopies = storeFileCopies
    }

    public static let `default` = CapturePolicy(maxFileBytes: 100 * 1_048_576, storeFileCopies: true)
}

/// File metadata read at capture time.
struct FileSnapshot: Sendable, Equatable {
    var url: URL
    var exists: Bool
    var isDirectory: Bool
    var byteSize: Int64?
    var modifiedAt: Date?
    var typeIdentifier: String?

    static func inspect(_ url: URL) -> FileSnapshot {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .typeIdentifierKey]
        let values = try? url.resourceValues(forKeys: keys)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return FileSnapshot(
            url: url,
            exists: exists,
            isDirectory: values?.isDirectory ?? isDirectory.boolValue,
            byteSize: values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate,
            typeIdentifier: values?.typeIdentifier
        )
    }
}

/// Everything derived from a snapshot that the store needs to persist or deduplicate it.
struct PreparedCapture: Sendable {
    var classification: ContentClassification
    var files: [FileSnapshot]
    var dedupeKey: String
    var contentHash: String
    var searchText: String
    var metadata: EntryMetadata
    var typeIdentifiers: [String]
}

enum CapturePreparer {
    static let searchTextLimit = 200_000

    static func prepare(_ snapshot: PasteboardSnapshot, classification: ContentClassification, files: [FileSnapshot]) -> PreparedCapture {
        var metadata = EntryMetadata(omittedTypes: snapshot.omittedTypes)
        if let text = classification.text {
            let stats = ContentClassifier.textStatistics(text)
            metadata.characterCount = stats.characters
            metadata.wordCount = stats.words
            metadata.lineCount = stats.lines
        }
        if let info = classification.imageInfo {
            metadata.imagePixelWidth = info.pixelWidth
            metadata.imagePixelHeight = info.pixelHeight
            metadata.imageTypeIdentifier = info.typeIdentifier
        }

        var typeIdentifiers: [String] = []
        for type in snapshot.items.flatMap(\.types) where !typeIdentifiers.contains(type) {
            typeIdentifiers.append(type)
        }

        let contentHash = contentHash(of: snapshot, files: files)
        return PreparedCapture(
            classification: classification,
            files: files,
            dedupeKey: dedupeKey(for: snapshot, classification: classification, contentHash: contentHash),
            contentHash: contentHash,
            searchText: searchText(classification: classification, sourceApp: snapshot.sourceApp),
            metadata: metadata,
            typeIdentifiers: typeIdentifiers
        )
    }

    /// Identity of the content, used to merge repeated copies into one entry.
    /// Text is identified by its plain text, images by their primary image bytes,
    /// files by their ordered paths, and anything else by all of its bytes.
    static func dedupeKey(for snapshot: PasteboardSnapshot, classification: ContentClassification, contentHash: String) -> String {
        switch classification.kind {
        case .file:
            let paths = classification.fileURLs.map(\.path).joined(separator: "\n")
            return "file:" + sha256(Data(paths.utf8))
        case .text, .code, .link:
            return "text:" + sha256(Data((classification.text ?? "").utf8))
        case .image:
            if let image = classification.primaryImage,
               let data = snapshot.items[image.itemIndex].data(for: image.type) {
                return "image:" + sha256(data)
            }
            return "data:" + contentHash
        case .other:
            return "data:" + contentHash
        }
    }

    /// Hash of every retained representation (and, for files, their size and modification date).
    /// Two captures with the same dedupe key but different hashes carry different representations.
    static func contentHash(of snapshot: PasteboardSnapshot, files: [FileSnapshot]) -> String {
        var hasher = SHA256()
        for (index, item) in snapshot.items.enumerated() {
            hasher.update(data: Data("item:\(index)\n".utf8))
            for representation in item.representations {
                hasher.update(data: Data("\(representation.type):\(representation.data.count)\n".utf8))
                hasher.update(data: representation.data)
            }
        }
        for file in files {
            let stamp = "file:\(file.url.path):\(file.byteSize ?? -1):\(file.modifiedAt?.timeIntervalSince1970 ?? -1)\n"
            hasher.update(data: Data(stamp.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func searchText(classification: ContentClassification, sourceApp: SourceApplication?) -> String {
        var parts = [classification.title]
        if let text = classification.text {
            parts.append(String(text.prefix(searchTextLimit)))
        }
        parts += classification.fileURLs.map(\.path)
        if let name = sourceApp?.name {
            parts.append(name)
        }
        return fold(parts.joined(separator: "\n"))
    }

    /// Case-, diacritic- and width-insensitive normalization shared by indexing and queries.
    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
