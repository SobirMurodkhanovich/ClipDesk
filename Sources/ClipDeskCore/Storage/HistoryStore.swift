import CoreGraphics
import Foundation
import os
import UniformTypeIdentifiers

public enum IngestOutcome: Sendable, Equatable {
    /// New content was added to history.
    case inserted(UUID)
    /// Identical content was already stored; it moved to the top of history.
    case refreshed(UUID)
    /// The same content (same text, image or files) arrived with different representations;
    /// the stored payloads were replaced and the entry moved to the top.
    case replaced(UUID)

    public var entryID: UUID {
        switch self {
        case .inserted(let id), .refreshed(let id), .replaced(let id): id
        }
    }
}

public enum HistoryStoreError: LocalizedError, Sendable, Equatable {
    case entryNotFound
    case payloadMissing
    case filesUnavailable

    public var errorDescription: String? {
        switch self {
        case .entryNotFound: "This item is no longer in history."
        case .payloadMissing: "The stored content for this item is missing."
        case .filesUnavailable: "None of the files in this item are available anymore."
        }
    }
}

/// Full content of an entry, loaded on demand for the preview panel.
public struct EntryContent: Sendable {
    public enum ImageSource: Sendable, Equatable {
        case file(URL)
        case data(Data)
    }

    public var text: String?
    public var isTextTruncated: Bool
    public var image: ImageSource?
    /// Type identifier of `image`, for saving it with the right file extension.
    public var imageType: String?
    public var representations: [RepresentationSummary]
}

public struct RepresentationSummary: Sendable, Hashable {
    public var itemIndex: Int
    public var type: String
    public var byteCount: Int64
}

public struct StorageUsage: Sendable, Equatable {
    public var entryCount: Int
    public var payloadBytes: Int64
    public var databaseBytes: Int64
}

/// Durable clipboard history: SQLite metadata plus payload files under the data directory.
/// All database work happens on this actor, off the main thread.
public actor HistoryStore {
    public nonisolated let directory: URL
    /// True when a damaged database was moved aside and a new one created at launch.
    public nonisolated let recoveredFromCorruption: Bool

    private let database: SQLiteDatabase
    private let payloads: PayloadStore
    private static let logger = Logger(subsystem: "io.github.sobirmurodkhanovich.ClipDesk", category: "HistoryStore")

    static let inlineThreshold = 64 * 1024
    static let thumbnailPixelSize = 192
    static let displayTextLimit = 1_000_000

    public init(directory: URL) throws {
        let directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.payloads = try PayloadStore(root: directory)
        (self.database, self.recoveredFromCorruption) = try Self.openDatabase(in: directory)
    }

    private static func openDatabase(in directory: URL) throws -> (SQLiteDatabase, Bool) {
        let url = directory.appendingPathComponent("history.sqlite")
        do {
            let database = try SQLiteDatabase(url: url)
            guard Schema.passesQuickCheck(database) else {
                throw DatabaseError(code: 11, message: "integrity check failed")
            }
            try Schema.configure(database)
            try Schema.migrate(database)
            return (database, false)
        } catch let error as DatabaseError where error.isCorruption {
            logger.error("History database is damaged; moving it aside")
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                let backup = directory.appendingPathComponent("history-damaged-\(stamp).sqlite\(suffix)")
                try? FileManager.default.moveItem(at: source, to: backup)
            }
            let database = try SQLiteDatabase(url: url)
            try Schema.configure(database)
            try Schema.migrate(database)
            return (database, true)
        }
    }

    // MARK: Capture

    /// Stores a snapshot, merging it with an existing entry when the content is the same.
    @discardableResult
    public func ingest(_ snapshot: PasteboardSnapshot, policy: CapturePolicy = .default) throws -> IngestOutcome {
        var classification = ContentClassifier.classify(snapshot)
        let files = classification.fileURLs.map(FileSnapshot.inspect)
        if classification.kind == .file, files.count == 1, policy.storeFileCopies,
           let file = files.first, Self.isImageFile(file), !classification.isScreenshot,
           ImageInspector.inspect(url: file.url)?.hasScreenshotMetadata == true {
            classification.isScreenshot = true
        }
        let prepared = CapturePreparer.prepare(snapshot, classification: classification, files: files)
        let now = snapshot.capturedAt

        let existing = try database.queryFirst(
            "SELECT id, content_hash, payload_dir FROM entries WHERE dedupe_key = ?",
            [.text(prepared.dedupeKey)]
        ) { row in
            (id: UUID(uuidString: row.string(0) ?? "") ?? UUID(), hash: row.string(1) ?? "", payloadDir: row.string(2) ?? "")
        }

        if let existing, existing.hash == prepared.contentHash {
            try database.run(
                "UPDATE entries SET last_used_at = ?, use_count = use_count + 1, source_app_name = ?, source_app_bundle_id = ? WHERE id = ?",
                [.date(now), .optionalText(snapshot.sourceApp?.name), .optionalText(snapshot.sourceApp?.bundleIdentifier), .text(existing.id.uuidString)]
            )
            return .refreshed(existing.id)
        }

        let captureDirectory = try payloads.makeCaptureDirectory()
        do {
            let id = existing?.id ?? UUID()
            let representationRows = try writeRepresentations(of: snapshot, into: captureDirectory)
            let fileRows = storeFiles(prepared.files, policy: policy, into: captureDirectory)
            var metadata = prepared.metadata
            if classification.kind == .file, let first = fileRows.first, Self.isImageFile(first.snapshot),
               let info = ImageInspector.inspect(url: first.storedURL ?? first.snapshot.url) {
                metadata.imagePixelWidth = info.pixelWidth
                metadata.imagePixelHeight = info.pixelHeight
            }
            let thumbnail = makeThumbnail(snapshot: snapshot, classification: classification, fileRows: fileRows, policy: policy, directory: captureDirectory)
            let byteCount = representationRows.reduce(Int64(0)) { $0 + $1.byteCount }
                + fileRows.reduce(Int64(0)) { $0 + ($1.storedURL == nil ? 0 : ($1.snapshot.byteSize ?? 0)) }

            try database.transaction {
                let values: [SQLValue] = [
                    .text(classification.kind.rawValue), .bool(classification.isScreenshot),
                    .text(classification.title), .text(classification.previewText), .text(prepared.searchText),
                    .text(prepared.dedupeKey), .text(prepared.contentHash), .date(now),
                    .integer(byteCount), .integer(Int64(snapshot.items.count)),
                    .text(prepared.typeIdentifiers.joined(separator: "\n")), .text(captureDirectory),
                    .optionalText(thumbnail), .optionalText(snapshot.sourceApp?.name),
                    .optionalText(snapshot.sourceApp?.bundleIdentifier), .text(Self.encode(metadata)),
                ]
                if existing != nil {
                    try database.run("DELETE FROM representations WHERE entry_id = ?", [.text(id.uuidString)])
                    try database.run("DELETE FROM files WHERE entry_id = ?", [.text(id.uuidString)])
                    try database.run("""
                        UPDATE entries SET kind = ?, is_screenshot = ?, title = ?, preview_text = ?, search_text = ?,
                            dedupe_key = ?, content_hash = ?, last_used_at = ?, byte_count = ?, item_count = ?,
                            type_identifiers = ?, payload_dir = ?, thumbnail_path = ?, source_app_name = ?,
                            source_app_bundle_id = ?, metadata = ?, use_count = use_count + 1
                        WHERE id = ?
                        """, values + [.text(id.uuidString)])
                } else {
                    try database.run("""
                        INSERT INTO entries (kind, is_screenshot, title, preview_text, search_text, dedupe_key,
                            content_hash, last_used_at, byte_count, item_count, type_identifiers, payload_dir,
                            thumbnail_path, source_app_name, source_app_bundle_id, metadata, id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, values + [.text(id.uuidString), .date(now)])
                }
                for row in representationRows {
                    try database.run(
                        "INSERT INTO representations (entry_id, item_index, position, type, byte_count, inline_data, payload_file) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(id.uuidString), .integer(Int64(row.itemIndex)), .integer(Int64(row.position)), .text(row.type),
                         .integer(row.byteCount), row.inlineData.map(SQLValue.blob) ?? .null, .optionalText(row.payloadFile)]
                    )
                }
                for (position, row) in fileRows.enumerated() {
                    try database.run(
                        "INSERT INTO files (entry_id, position, original_path, file_name, type_identifier, byte_size, is_directory, modified_at, stored_path, storage_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [.text(id.uuidString), .integer(Int64(position)), .text(row.snapshot.url.path),
                         .text(row.snapshot.url.lastPathComponent), .optionalText(row.snapshot.typeIdentifier),
                         row.snapshot.byteSize.map(SQLValue.integer) ?? .null, .bool(row.snapshot.isDirectory),
                         row.snapshot.modifiedAt.map(SQLValue.date) ?? .null,
                         .optionalText(row.storedURL.flatMap(payloads.relativePath(for:))), .text(row.state.rawValue)]
                    )
                }
            }

            if let existing {
                payloads.removeCaptureDirectory(existing.payloadDir)
                return .replaced(id)
            }
            return .inserted(id)
        } catch {
            payloads.removeCaptureDirectory(captureDirectory)
            throw error
        }
    }

    private struct RepresentationRow {
        var itemIndex: Int
        var position: Int
        var type: String
        var byteCount: Int64
        var inlineData: Data?
        var payloadFile: String?
    }

    private func writeRepresentations(of snapshot: PasteboardSnapshot, into directory: String) throws -> [RepresentationRow] {
        var rows: [RepresentationRow] = []
        for (itemIndex, item) in snapshot.items.enumerated() {
            for (position, representation) in item.representations.enumerated() {
                var row = RepresentationRow(
                    itemIndex: itemIndex, position: position, type: representation.type,
                    byteCount: Int64(representation.data.count)
                )
                if representation.data.count <= Self.inlineThreshold {
                    row.inlineData = representation.data
                } else {
                    row.payloadFile = try payloads.write(representation.data, named: "r\(itemIndex)-\(position).bin", in: directory)
                }
                rows.append(row)
            }
        }
        return rows
    }

    private struct FileRow {
        var snapshot: FileSnapshot
        var state: FileStorageState
        var storedURL: URL?
    }

    /// Copies files into managed storage when allowed, readable and within the size limit.
    private func storeFiles(_ files: [FileSnapshot], policy: CapturePolicy, into directory: String) -> [FileRow] {
        files.enumerated().map { position, file in
            guard file.exists else { return FileRow(snapshot: file, state: .missing) }
            guard !file.isDirectory else { return FileRow(snapshot: file, state: .directory) }
            guard policy.storeFileCopies else { return FileRow(snapshot: file, state: .copyingDisabled) }
            guard let size = file.byteSize, size <= policy.maxFileBytes else {
                return FileRow(snapshot: file, state: file.byteSize == nil ? .unreadable : .tooLarge)
            }
            let folder = payloads.url(for: "\(directory)/files/\(position)")
            let destination = folder.appendingPathComponent(file.url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file.url, to: destination)
                return FileRow(snapshot: file, state: .copied, storedURL: destination)
            } catch {
                Self.logger.notice("Could not copy a file into storage; keeping a reference only")
                return FileRow(snapshot: file, state: .unreadable)
            }
        }
    }

    private func makeThumbnail(
        snapshot: PasteboardSnapshot,
        classification: ContentClassification,
        fileRows: [FileRow],
        policy: CapturePolicy,
        directory: String
    ) -> String? {
        let image: CGImage?
        switch classification.kind {
        case .image:
            guard let primary = classification.primaryImage,
                  let data = snapshot.items[primary.itemIndex].data(for: primary.type) else { return nil }
            image = ImageInspector.downsampledImage(data: data, maxPixelSize: Self.thumbnailPixelSize)
        case .file:
            guard let row = fileRows.first(where: { Self.isImageFile($0.snapshot) }) else { return nil }
            // Without a managed copy, read the original only when file access is allowed.
            guard let url = row.storedURL ?? (policy.storeFileCopies && row.snapshot.exists ? row.snapshot.url : nil) else { return nil }
            image = ImageInspector.downsampledImage(url: url, maxPixelSize: Self.thumbnailPixelSize)
        default:
            return nil
        }
        guard let image, let png = ImageInspector.pngData(from: image) else { return nil }
        return try? payloads.write(png, named: "thumbnail.png", in: directory)
    }

    private static func isImageFile(_ file: FileSnapshot) -> Bool {
        guard !file.isDirectory else { return false }
        let type = file.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: file.url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    // MARK: Queries

    private static let entryColumns = """
        id, kind, is_screenshot, title, preview_text, created_at, last_used_at, use_count, is_favorite,
        byte_count, item_count, type_identifiers, thumbnail_path, source_app_name, source_app_bundle_id, metadata
        """

    /// Entries in a category, most recently used first. `search` matches every whitespace-separated
    /// term against titles, stored text, file names and paths, case- and diacritic-insensitively.
    public func entries(in category: HistoryCategory = .all, matching search: String = "", limit: Int? = nil) throws -> [ClipEntry] {
        var sql = "SELECT \(Self.entryColumns) FROM entries WHERE \(category.sqlPredicate)"
        var bindings: [SQLValue] = []
        for term in Self.searchTerms(search) {
            sql += " AND search_text LIKE ? ESCAPE '\\'"
            bindings.append(.text("%\(Self.escapeLike(term))%"))
        }
        sql += " ORDER BY last_used_at DESC, created_at DESC"
        if let limit {
            sql += " LIMIT ?"
            bindings.append(.integer(Int64(limit)))
        }
        var entries = try database.query(sql, bindings, map: makeEntry)
        try attachFiles(to: &entries)
        return entries
    }

    public func entry(id: UUID) throws -> ClipEntry? {
        var entries = try database.query(
            "SELECT \(Self.entryColumns) FROM entries WHERE id = ?", [.text(id.uuidString)], map: makeEntry
        )
        try attachFiles(to: &entries)
        return entries.first
    }

    public func counts() throws -> CategoryCounts {
        let row = try database.queryFirst("""
            SELECT COUNT(*),
                   COALESCE(SUM(kind IN ('text', 'code', 'link')), 0),
                   COALESCE(SUM(kind = 'image' AND is_screenshot = 0), 0),
                   COALESCE(SUM(is_screenshot = 1), 0),
                   COALESCE(SUM(kind = 'file'), 0),
                   COALESCE(SUM(is_favorite = 1), 0)
            FROM entries
            """) { row in (0..<6).map { Int(row.int(Int32($0))) } }
        guard let row else { return .zero }
        return CategoryCounts(values: [
            .all: row[0], .text: row[1], .images: row[2], .screenshots: row[3], .files: row[4], .favorites: row[5],
        ])
    }

    public func storageUsage() throws -> StorageUsage {
        let row = try database.queryFirst("SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM entries") {
            (Int($0.int(0)), $0.int(1))
        }
        var databaseBytes: Int64 = 0
        for suffix in ["", "-wal"] {
            let path = directory.appendingPathComponent("history.sqlite").path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            databaseBytes += size
        }
        return StorageUsage(entryCount: row?.0 ?? 0, payloadBytes: row?.1 ?? 0, databaseBytes: databaseBytes)
    }

    /// Text, image source and representation list for the preview panel.
    public func content(for id: UUID) throws -> EntryContent {
        guard let entry = try entry(id: id) else { throw HistoryStoreError.entryNotFound }
        let stored = try storedRepresentations(for: id)

        var text: String?
        var truncated = false
        if entry.kind.isTextual {
            let textTypes: Set<String> = [
                PasteboardTypes.plainText, PasteboardTypes.utf16PlainText,
                PasteboardTypes.utf16ExternalPlainText, PasteboardTypes.rtf, PasteboardTypes.url,
            ]
            let items = try snapshotItems(from: stored.filter { textTypes.contains($0.type) })
            let full = items.compactMap(ContentClassifier.plainText(in:)).joined(separator: "\n")
            if full.count > Self.displayTextLimit {
                text = String(full.prefix(Self.displayTextLimit))
                truncated = true
            } else {
                text = full
            }
        }

        var image: EntryContent.ImageSource?
        var imageType: String?
        if entry.kind == .image || (entry.kind == .other && stored.contains { ContentClassifier.isImageType($0.type) }) {
            let preferred = [PasteboardTypes.png, PasteboardTypes.jpeg, "public.heic", PasteboardTypes.tiff]
            let candidate = preferred.lazy.compactMap { type in stored.first { $0.type == type } }.first
                ?? stored.first { ContentClassifier.isImageType($0.type) }
            if let candidate {
                imageType = candidate.type
                if let file = candidate.payloadFile {
                    image = .file(payloads.url(for: file))
                } else if let data = candidate.inlineData {
                    image = .data(data)
                }
            }
        }

        return EntryContent(
            text: text,
            isTextTruncated: truncated,
            image: image,
            imageType: imageType,
            representations: stored.map { RepresentationSummary(itemIndex: $0.itemIndex, type: $0.type, byteCount: $0.byteCount) }
        )
    }

    // MARK: Restore

    /// Builds the pasteboard content for an entry, substituting managed copies for missing files.
    public func restorePayload(for id: UUID) throws -> RestorePayload {
        guard let entry = try entry(id: id) else { throw HistoryStoreError.entryNotFound }
        let items = try snapshotItems(from: storedRepresentations(for: id))
        guard !items.isEmpty else { throw HistoryStoreError.payloadMissing }
        guard entry.kind == .file else {
            return RestorePayload(items: items.map { .representations($0.representations) })
        }

        var restored: [RestoreItem] = []
        var skipped: [String] = []
        var substituted: [String] = []
        var fileIndex = 0
        for item in items {
            guard item.data(for: PasteboardTypes.fileURL) != nil else {
                restored.append(.representations(item.representations))
                continue
            }
            defer { fileIndex += 1 }
            guard fileIndex < entry.files.count else { continue }
            let file = entry.files[fileIndex]
            guard let url = file.bestAvailableURL else {
                skipped.append(file.fileName)
                continue
            }
            if file.availability == .storedCopy {
                substituted.append(file.fileName)
            }
            restored.append(.file(url, extra: item.representations.filter { $0.type != PasteboardTypes.fileURL }))
        }

        guard restored.contains(where: { if case .file = $0 { true } else { false } }) else {
            throw HistoryStoreError.filesUnavailable
        }
        var warnings: [String] = []
        if !skipped.isEmpty {
            warnings.append("\(skipped.count) of \(entry.files.count) files are no longer available and were skipped.")
        }
        if !substituted.isEmpty {
            warnings.append("Used ClipDesk's stored copy for \(substituted.count == 1 ? substituted[0] : "\(substituted.count) files") because the original was moved or deleted.")
        }
        return RestorePayload(items: restored, warnings: warnings)
    }

    /// The entry's text as a single plain-text representation.
    public func plainTextPayload(for id: UUID) throws -> RestorePayload {
        let content = try content(for: id)
        guard let text = content.text, !content.isTextTruncated else { return try restorePayload(for: id) }
        return RestorePayload(items: [.representations([.init(type: PasteboardTypes.plainText, data: Data(text.utf8))])])
    }

    // MARK: Mutations

    /// Records that the entry was copied back to the clipboard, moving it to the top of history.
    public func markUsed(_ id: UUID, at date: Date = Date()) throws {
        try database.run(
            "UPDATE entries SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
            [.date(date), .text(id.uuidString)]
        )
    }

    public func setFavorite(_ id: UUID, _ isFavorite: Bool) throws {
        try database.run("UPDATE entries SET is_favorite = ? WHERE id = ?", [.bool(isFavorite), .text(id.uuidString)])
    }

    /// Deletes entries and their managed payloads (stored representations, file copies and thumbnails).
    public func delete(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let bindings = chunk.map { SQLValue.text($0.uuidString) }
            let directories = try database.query(
                "SELECT payload_dir FROM entries WHERE id IN (\(placeholders))", bindings
            ) { $0.string(0) }
            try database.transaction {
                try database.run("DELETE FROM entries WHERE id IN (\(placeholders))", bindings)
            }
            directories.compactMap { $0 }.forEach(payloads.removeCaptureDirectory)
        }
    }

    /// Removes history. With `keepFavorites == false` every entry and payload is removed and the
    /// database file is compacted so deleted content does not linger in free pages.
    @discardableResult
    public func clear(keepFavorites: Bool) throws -> Int {
        let ids = try database.query(
            keepFavorites ? "SELECT id FROM entries WHERE is_favorite = 0" : "SELECT id FROM entries"
        ) { UUID(uuidString: $0.string(0) ?? "") }.compactMap { $0 }
        try delete(ids)
        if !keepFavorites {
            removeOrphanedPayloads()
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try database.execute("VACUUM")
        return ids.count
    }

    /// Applies the retention policy. Returns the number of entries removed.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) throws -> Int {
        let candidates = try database.query("SELECT id, last_used_at, is_favorite FROM entries") { row in
            UUID(uuidString: row.string(0) ?? "").map {
                RetentionPolicy.Candidate(id: $0, lastUsedAt: row.date(1), isFavorite: row.bool(2))
            }
        }.compactMap { $0 }
        let expired = policy.entriesToRemove(from: candidates, now: now)
        try delete(expired)
        return expired.count
    }

    /// Deletes payload directories that no entry references (for example after a crash mid-capture).
    @discardableResult
    public func removeOrphanedPayloads() -> Int {
        guard let referenced = try? Set(database.query("SELECT payload_dir FROM entries") { $0.string(0) ?? "" }) else {
            return 0
        }
        var removed = 0
        for path in payloads.existingCaptureEntries() where !referenced.contains(path) {
            payloads.removeStrayPayload(path)
            removed += 1
        }
        return removed
    }

    // MARK: Helpers

    private struct StoredRepresentation {
        var itemIndex: Int
        var position: Int
        var type: String
        var byteCount: Int64
        var inlineData: Data?
        var payloadFile: String?
    }

    private func storedRepresentations(for id: UUID) throws -> [StoredRepresentation] {
        try database.query(
            "SELECT item_index, position, type, byte_count, inline_data, payload_file FROM representations WHERE entry_id = ? ORDER BY item_index, position",
            [.text(id.uuidString)]
        ) { row in
            StoredRepresentation(
                itemIndex: Int(row.int(0)), position: Int(row.int(1)), type: row.string(2) ?? "",
                byteCount: row.int(3), inlineData: row.data(4), payloadFile: row.string(5)
            )
        }
    }

    private func snapshotItems(from stored: [StoredRepresentation]) throws -> [PasteboardSnapshot.Item] {
        var items: [Int: [PasteboardSnapshot.Representation]] = [:]
        for representation in stored {
            let data: Data
            if let inline = representation.inlineData {
                data = inline
            } else if let file = representation.payloadFile {
                do {
                    data = try Data(contentsOf: payloads.url(for: file), options: .mappedIfSafe)
                } catch {
                    throw HistoryStoreError.payloadMissing
                }
            } else {
                continue
            }
            items[representation.itemIndex, default: []].append(.init(type: representation.type, data: data))
        }
        return items.keys.sorted().map { PasteboardSnapshot.Item(representations: items[$0] ?? []) }
    }

    private func makeEntry(_ row: SQLRow) -> ClipEntry {
        let metadata = (row.string(15)?.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode(EntryMetadata.self, from: $0) } ?? EntryMetadata()
        let sourceName = row.string(13)
        let sourceBundle = row.string(14)
        return ClipEntry(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            kind: ContentKind(rawValue: row.string(1) ?? "") ?? .other,
            isScreenshot: row.bool(2),
            title: row.string(3) ?? "",
            previewText: row.string(4) ?? "",
            createdAt: row.date(5),
            lastUsedAt: row.date(6),
            useCount: Int(row.int(7)),
            isFavorite: row.bool(8),
            byteCount: row.int(9),
            itemCount: Int(row.int(10)),
            typeIdentifiers: (row.string(11) ?? "").split(separator: "\n").map(String.init),
            thumbnailURL: row.string(12).map(payloads.url(for:)),
            sourceApp: (sourceName != nil || sourceBundle != nil) ? SourceApplication(name: sourceName, bundleIdentifier: sourceBundle) : nil,
            metadata: metadata,
            files: []
        )
    }

    private func attachFiles(to entries: inout [ClipEntry]) throws {
        let ids = entries.filter { $0.kind == .file }.map(\.id)
        guard !ids.isEmpty else { return }
        var filesByEntry: [UUID: [ClipFile]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.query(
                """
                SELECT entry_id, position, original_path, file_name, type_identifier, byte_size, is_directory,
                       modified_at, stored_path, storage_state
                FROM files WHERE entry_id IN (\(placeholders)) ORDER BY entry_id, position
                """,
                chunk.map { .text($0.uuidString) }
            ) { row -> (UUID?, ClipFile) in
                let original = URL(fileURLWithPath: row.string(2) ?? "")
                let stored = row.string(8).map(payloads.url(for:))
                let file = ClipFile(
                    position: Int(row.int(1)),
                    originalURL: original,
                    fileName: row.string(3) ?? original.lastPathComponent,
                    typeIdentifier: row.string(4),
                    byteSize: row.isNull(5) ? nil : row.int(5),
                    isDirectory: row.bool(6),
                    modifiedAt: row.isNull(7) ? nil : row.date(7),
                    storedCopyURL: stored,
                    storage: FileStorageState(rawValue: row.string(9) ?? "") ?? .unreadable,
                    availability: Self.availability(original: original, stored: stored)
                )
                return (UUID(uuidString: row.string(0) ?? ""), file)
            }
            for (id, file) in rows {
                if let id { filesByEntry[id, default: []].append(file) }
            }
        }
        for index in entries.indices where entries[index].kind == .file {
            entries[index].files = filesByEntry[entries[index].id] ?? []
        }
    }

    static func availability(original: URL, stored: URL?) -> FileAvailability {
        if FileManager.default.fileExists(atPath: original.path) { return .original }
        if let stored, FileManager.default.fileExists(atPath: stored.path) { return .storedCopy }
        return .unavailable
    }

    static func searchTerms(_ search: String) -> [String] {
        CapturePreparer.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func escapeLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func encode(_ metadata: EntryMetadata) -> String {
        (try? JSONEncoder().encode(metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
