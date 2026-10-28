import Foundation
import Testing
@testable import ClipDeskCore

@Suite("History store")
struct HistoryStoreTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func withStore(_ body: (HistoryStore, URL) async throws -> Void) async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        try await body(try HistoryStore(directory: directory), directory)
    }

    @Test func insertsAndLoadsTextEntry() async throws {
        try await withStore { store, _ in
            let outcome = try await store.ingest(TestSupport.textSnapshot("Hello world", at: base))
            guard case .inserted(let id) = outcome else {
                Issue.record("Expected insert, got \(outcome)")
                return
            }
            let entries = try await store.entries()
            #expect(entries.map(\.id) == [id])
            let entry = try #require(entries.first)
            #expect(entry.kind == .text)
            #expect(entry.title == "Hello world")
            #expect(entry.metadata.characterCount == 11)
            #expect(entry.metadata.wordCount == 2)
            #expect(entry.createdAt == base)
            #expect(entry.useCount == 1)
            #expect(try await store.content(for: id).text == "Hello world")
        }
    }

    @Test func identicalCopyRefreshesInsteadOfDuplicating() async throws {
        try await withStore { store, _ in
            let first = try await store.ingest(TestSupport.textSnapshot("A", at: base))
            try await store.ingest(TestSupport.textSnapshot("B", at: base.addingTimeInterval(10)))
            let again = try await store.ingest(TestSupport.textSnapshot("A", at: base.addingTimeInterval(20)))

            #expect(again == .refreshed(first.entryID))
            let entries = try await store.entries()
            #expect(entries.map(\.title) == ["A", "B"])
            #expect(entries[0].useCount == 2)
            #expect(entries[0].createdAt == base)
            #expect(entries[0].lastUsedAt == base.addingTimeInterval(20))
        }
    }

    @Test func sameTextWithNewRepresentationsReplacesPayload() async throws {
        try await withStore { store, directory in
            let first = try await store.ingest(TestSupport.textSnapshot("Report", at: base))
            let html = TestSupport.representation(PasteboardTypes.html, "<b>Report</b>")
            let second = try await store.ingest(TestSupport.textSnapshot("Report", extra: [html], at: base.addingTimeInterval(5)))

            #expect(second == .replaced(first.entryID))
            #expect(try await store.entries().count == 1)
            let payload = try await store.restorePayload(for: first.entryID)
            #expect(payload.items == [.representations([TestSupport.representation(PasteboardTypes.plainText, "Report"), html])])
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 1)
        }
    }

    @Test func restorePreservesItemsAndRepresentationOrder() async throws {
        try await withStore { store, _ in
            let rtf = TestSupport.representation(PasteboardTypes.rtf, "{\\rtf1 First}")
            let snapshot = PasteboardSnapshot(items: [
                .init(representations: [rtf, TestSupport.representation(PasteboardTypes.plainText, "First")]),
                .init(representations: [TestSupport.representation(PasteboardTypes.plainText, "Second")]),
            ], capturedAt: base)
            let id = try await store.ingest(snapshot).entryID
            let payload = try await store.restorePayload(for: id)
            #expect(payload.items == snapshot.items.map { .representations($0.representations) })
            #expect(try await store.entry(id: id)?.itemCount == 2)

            let plain = try await store.plainTextPayload(for: id)
            #expect(plain.items == [.representations([TestSupport.representation(PasteboardTypes.plainText, "First\nSecond")])])
        }
    }

    @Test func historyIsOrderedByMostRecentActivity() async throws {
        try await withStore { store, _ in
            let old = try await store.ingest(TestSupport.textSnapshot("old", at: base)).entryID
            try await store.ingest(TestSupport.textSnapshot("new", at: base.addingTimeInterval(60)))
            #expect(try await store.entries().map(\.title) == ["new", "old"])

            try await store.markUsed(old, at: base.addingTimeInterval(120))
            let entries = try await store.entries()
            #expect(entries.map(\.title) == ["old", "new"])
            #expect(entries[0].useCount == 2)
        }
    }

    @Test func searchIsCaseAndDiacriticInsensitiveWithAllTerms() async throws {
        try await withStore { store, _ in
            try await store.ingest(TestSupport.textSnapshot("Café Résumé notes", at: base))
            try await store.ingest(TestSupport.textSnapshot("Grocery list", at: base.addingTimeInterval(1)))
            try await store.ingest(TestSupport.textSnapshot("Привет мир", at: base.addingTimeInterval(2)))

            #expect(try await store.entries(matching: "cafe").map(\.title) == ["Café Résumé notes"])
            #expect(try await store.entries(matching: "RESUME notes").count == 1)
            #expect(try await store.entries(matching: "resume grocery").isEmpty)
            #expect(try await store.entries(matching: "ПРИВЕТ").map(\.title) == ["Привет мир"])
            #expect(try await store.entries(matching: "   ").count == 3)
        }
    }

    @Test func searchTreatsWildcardsLiterally() async throws {
        try await withStore { store, _ in
            try await store.ingest(TestSupport.textSnapshot("Discount 100% off", at: base))
            try await store.ingest(TestSupport.textSnapshot("snake_case_name", at: base.addingTimeInterval(1)))
            try await store.ingest(TestSupport.textSnapshot("plain", at: base.addingTimeInterval(2)))

            #expect(try await store.entries(matching: "%").map(\.title) == ["Discount 100% off"])
            #expect(try await store.entries(matching: "_").map(\.title) == ["snake_case_name"])
        }
    }

    @Test func categoriesAndCountsReflectStoredData() async throws {
        try await withStore { store, _ in
            try await store.ingest(TestSupport.textSnapshot("note", at: base))
            try await store.ingest(TestSupport.textSnapshot("https://apple.com", at: base.addingTimeInterval(1)))
            try await store.ingest(TestSupport.imageSnapshot(try TestSupport.pngData(width: 8, height: 8), at: base.addingTimeInterval(2)))
            let screenshot = try await store.ingest(TestSupport.imageSnapshot(try TestSupport.pngData(userComment: "Screenshot"), at: base.addingTimeInterval(3)))
            try await store.setFavorite(screenshot.entryID, true)

            let counts = try await store.counts()
            #expect(counts[.all] == 4)
            #expect(counts[.text] == 2)
            #expect(counts[.images] == 1)
            #expect(counts[.screenshots] == 1)
            #expect(counts[.files] == 0)
            #expect(counts[.favorites] == 1)
            for category in HistoryCategory.allCases {
                let entries = try await store.entries(in: category)
                #expect(entries.count == counts[category])
                #expect(entries.allSatisfy(category.includes))
            }
        }
    }

    @Test func imageEntriesGetThumbnailAndPreviewSource() async throws {
        try await withStore { store, _ in
            let png = try TestSupport.pngData(width: 400, height: 300)
            let id = try await store.ingest(TestSupport.imageSnapshot(png, at: base)).entryID
            let entry = try #require(try await store.entry(id: id))
            let thumbnail = try #require(entry.thumbnailURL)
            #expect(FileManager.default.fileExists(atPath: thumbnail.path))
            let thumbnailInfo = try #require(ImageInspector.inspect(url: thumbnail))
            #expect(max(thumbnailInfo.pixelWidth, thumbnailInfo.pixelHeight) <= 192)
            #expect(entry.metadata.imagePixelWidth == 400)

            let content = try await store.content(for: id)
            #expect(content.imageType == PasteboardTypes.png)
            switch content.image {
            case .data(let data): #expect(data == png)
            case .file(let url): #expect(try Data(contentsOf: url) == png)
            case nil: Issue.record("Missing image source")
            }
        }
    }

    @Test func deleteRemovesRowsAndPayloads() async throws {
        try await withStore { store, directory in
            let large = String(repeating: "x", count: 200_000)
            let id = try await store.ingest(TestSupport.textSnapshot(large, at: base)).entryID
            try await store.ingest(TestSupport.imageSnapshot(try TestSupport.pngData(), at: base.addingTimeInterval(1)))
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 2)

            try await store.delete([id])
            #expect(try await store.entry(id: id) == nil)
            #expect(try await store.entries().count == 1)
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 1)
            await #expect(throws: HistoryStoreError.entryNotFound) {
                try await store.restorePayload(for: id)
            }
        }
    }

    @Test func clearKeepsFavoritesUnlessEverythingIsRequested() async throws {
        try await withStore { store, directory in
            let favorite = try await store.ingest(TestSupport.textSnapshot("keep", at: base)).entryID
            try await store.ingest(TestSupport.textSnapshot("drop", at: base.addingTimeInterval(1)))
            try await store.ingest(TestSupport.imageSnapshot(try TestSupport.pngData(), at: base.addingTimeInterval(2)))
            try await store.setFavorite(favorite, true)

            #expect(try await store.clear(keepFavorites: true) == 2)
            #expect(try await store.entries().map(\.id) == [favorite])
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 1)

            #expect(try await store.clear(keepFavorites: false) == 1)
            #expect(try await store.entries().isEmpty)
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 0)
        }
    }

    @Test func retentionEnforcesLimitAndAgeButKeepsFavorites() async throws {
        try await withStore { store, _ in
            let now = base.addingTimeInterval(100 * 86_400)
            let expiredFavorite = try await store.ingest(TestSupport.textSnapshot("old favorite", at: base)).entryID
            try await store.setFavorite(expiredFavorite, true)
            try await store.ingest(TestSupport.textSnapshot("expired", at: base.addingTimeInterval(1)))
            for index in 0..<5 {
                try await store.ingest(TestSupport.textSnapshot("recent \(index)", at: now.addingTimeInterval(TimeInterval(index))))
            }

            let removed = try await store.applyRetention(RetentionPolicy(maxEntries: 3, maxAgeDays: 30), now: now.addingTimeInterval(10))
            #expect(removed == 3)
            #expect(try await store.entries().map(\.title) == ["recent 4", "recent 3", "recent 2", "old favorite"])
        }
    }

    @Test func defaultRetentionKeeps100Entries() async throws {
        try await withStore { store, _ in
            for index in 0..<105 {
                try await store.ingest(TestSupport.textSnapshot("item \(index)", at: base.addingTimeInterval(TimeInterval(index))))
            }
            try await store.applyRetention(.default, now: base.addingTimeInterval(200))
            let entries = try await store.entries()
            #expect(entries.count == 100)
            #expect(entries.first?.title == "item 104")
            #expect(entries.last?.title == "item 5")
        }
    }

    @Test func orphanedPayloadsAreRemovedAndReferencedOnesKept() async throws {
        try await withStore { store, directory in
            try await store.ingest(TestSupport.imageSnapshot(try TestSupport.pngData(), at: base))
            let orphan = directory.appendingPathComponent("Payloads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: orphan.appendingPathComponent("r0-0.bin"))
            try Data("stray".utf8).write(to: directory.appendingPathComponent("Payloads/stray.tmp"))

            #expect(await store.removeOrphanedPayloads() == 2)
            #expect(TestSupport.payloadDirectoryCount(in: directory) == 1)
            #expect(try await store.entries().count == 1)
        }
    }

    @Test func historyPersistsAcrossLaunches() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        let id = try await HistoryStore(directory: directory).ingest(TestSupport.textSnapshot("persisted", at: base)).entryID
        let reopened = try HistoryStore(directory: directory)
        #expect(try await reopened.entries().map(\.id) == [id])
        #expect(!reopened.recoveredFromCorruption)
    }

    @Test func migrationsSetSchemaVersionAndRejectNewerDatabases() throws {
        let database = try SQLiteDatabase(url: nil)
        try Schema.configure(database)
        try Schema.migrate(database)
        #expect(try database.userVersion == Schema.latestVersion)
        try Schema.migrate(database) // Idempotent.

        try database.setUserVersion(Schema.latestVersion + 1)
        #expect(throws: DatabaseError.self) {
            try Schema.migrate(database)
        }
    }

    @Test func damagedDatabaseIsMovedAsideAndRecreated() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        try Data(repeating: 0x7A, count: 8_192).write(to: directory.appendingPathComponent("history.sqlite"))

        let store = try HistoryStore(directory: directory)
        #expect(store.recoveredFromCorruption)
        try await store.ingest(TestSupport.textSnapshot("works", at: base))
        #expect(try await store.entries().count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("history-damaged-") })
    }

    @Test func payloadStoreRefusesPathsOutsideCaptureDirectories() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        let keep = try TestSupport.writeFile("keep.txt", in: directory)
        let store = try PayloadStore(root: directory)
        store.removeCaptureDirectory("keep.txt")
        store.removeCaptureDirectory("Payloads/../keep.txt")
        store.removeCaptureDirectory("/")
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!store.isCaptureDirectoryPath("Payloads/not-a-uuid"))
        #expect(store.isCaptureDirectoryPath("Payloads/\(UUID().uuidString)"))
    }
}
