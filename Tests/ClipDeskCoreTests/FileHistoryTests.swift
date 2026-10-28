import Foundation
import Testing
@testable import ClipDeskCore

@Suite("File history")
struct FileHistoryTests {
    private struct Fixture {
        let root: URL
        let originals: URL
        let store: HistoryStore
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(root) }
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let store = try HistoryStore(directory: root.appendingPathComponent("Data", isDirectory: true))
        try await body(Fixture(root: root, originals: originals, store: store))
    }

    @Test func copiesFileAndFallsBackToStoredCopy() async throws {
        try await withFixture { fixture in
            let original = try TestSupport.writeFile("Design_Document.pdf", in: fixture.originals, bytes: 2_048)
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot([original])).entryID

            var file = try #require(try await fixture.store.entry(id: id)?.files.first)
            #expect(file.storage == .copied)
            #expect(file.availability == .original)
            #expect(file.byteSize == 2_048)
            #expect(file.fileName == "Design_Document.pdf")
            let stored = try #require(file.storedCopyURL)
            #expect(stored.lastPathComponent == "Design_Document.pdf")
            #expect(try Data(contentsOf: stored) == Data(contentsOf: original))
            // Retained bytes include the managed copy plus the small URL and name representations.
            #expect(try #require(try await fixture.store.entry(id: id)).byteCount >= 2_048)

            var payload = try await fixture.store.restorePayload(for: id)
            guard case .file(let restoredURL, let extra) = payload.items.first else {
                Issue.record("Expected a file item")
                return
            }
            #expect(restoredURL.standardizedFileURL == original.standardizedFileURL)
            #expect(extra.map(\.type) == [PasteboardTypes.plainText])
            #expect(payload.warnings.isEmpty)

            try FileManager.default.removeItem(at: original)
            file = try #require(try await fixture.store.entry(id: id)?.files.first)
            #expect(file.availability == .storedCopy)
            payload = try await fixture.store.restorePayload(for: id)
            #expect(payload.items.first == .file(stored, extra: extra))
            #expect(payload.warnings.count == 1)

            try FileManager.default.removeItem(at: stored)
            #expect(try await fixture.store.entry(id: id)?.files.first?.availability == .unavailable)
            #expect(try await fixture.store.entry(id: id)?.hasUnavailableFiles == true)
            await #expect(throws: HistoryStoreError.filesUnavailable) {
                try await fixture.store.restorePayload(for: id)
            }
        }
    }

    @Test func filesOverLimitAreKeptAsReferences() async throws {
        try await withFixture { fixture in
            let original = try TestSupport.writeFile("Large.bin", in: fixture.originals, bytes: 4_096)
            let policy = CapturePolicy(maxFileBytes: 1_024, storeFileCopies: true)
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot([original]), policy: policy).entryID
            let entry = try #require(try await fixture.store.entry(id: id))
            #expect(entry.files.first?.storage == .tooLarge)
            #expect(entry.files.first?.storedCopyURL == nil)
            #expect(entry.files.first?.availability == .original)
            #expect(entry.byteCount < 4_096)
        }
    }

    @Test func copyingCanBeDisabled() async throws {
        try await withFixture { fixture in
            let original = try TestSupport.writeFile("notes.txt", in: fixture.originals)
            let policy = CapturePolicy(maxFileBytes: 1_048_576, storeFileCopies: false)
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot([original]), policy: policy).entryID
            #expect(try await fixture.store.entry(id: id)?.files.first?.storage == .copyingDisabled)
        }
    }

    @Test func directoriesAndMissingFilesAreReferences() async throws {
        try await withFixture { fixture in
            let folder = fixture.originals.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let missing = fixture.originals.appendingPathComponent("gone.docx")
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot([folder, missing])).entryID
            let files = try #require(try await fixture.store.entry(id: id)?.files)
            #expect(files.map(\.storage) == [.directory, .missing])
            #expect(files.map(\.availability) == [.original, .unavailable])

            let payload = try await fixture.store.restorePayload(for: id)
            #expect(payload.items.count == 1)
            #expect(payload.warnings.first?.contains("1 of 2") == true)
        }
    }

    @Test func multipleFilesAreRestoredAsAGroup() async throws {
        try await withFixture { fixture in
            let names = ["Project_Plan.docx", "Budget.xlsx", "archive.unknownext"]
            let urls = try names.map { try TestSupport.writeFile($0, in: fixture.originals) }
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot(urls)).entryID
            let entry = try #require(try await fixture.store.entry(id: id))
            #expect(entry.kind == .file)
            #expect(entry.itemCount == 3)
            #expect(entry.files.map(\.fileName) == names)
            #expect(entry.title == "Project_Plan.docx + 2 more")

            let payload = try await fixture.store.restorePayload(for: id)
            let restored = payload.items.compactMap { item -> URL? in
                if case .file(let url, _) = item { url } else { nil }
            }
            #expect(restored.map(\.lastPathComponent) == names)
        }
    }

    @Test func deletingEntryNeverTouchesOriginalFile() async throws {
        try await withFixture { fixture in
            let original = try TestSupport.writeFile("keep-me.txt", in: fixture.originals)
            let id = try await fixture.store.ingest(TestSupport.fileSnapshot([original])).entryID
            let stored = try #require(try await fixture.store.entry(id: id)?.files.first?.storedCopyURL)

            try await fixture.store.delete([id])
            #expect(FileManager.default.fileExists(atPath: original.path))
            #expect(!FileManager.default.fileExists(atPath: stored.path))
        }
    }

    @Test func screenshotFilesAreClassifiedAndThumbnailed() async throws {
        try await withFixture { fixture in
            let byName = fixture.originals.appendingPathComponent("Screenshot 2024-12-01 at 10.38.12.png")
            try TestSupport.pngData(width: 300, height: 200).write(to: byName)
            let byMetadata = fixture.originals.appendingPathComponent("capture.png")
            try TestSupport.pngData(width: 300, height: 200, userComment: "Screenshot").write(to: byMetadata)
            let plain = fixture.originals.appendingPathComponent("AppIcon.png")
            try TestSupport.pngData(width: 300, height: 200).write(to: plain)

            for (url, expected) in [(byName, true), (byMetadata, true), (plain, false)] {
                let id = try await fixture.store.ingest(TestSupport.fileSnapshot([url])).entryID
                let entry = try #require(try await fixture.store.entry(id: id))
                #expect(entry.isScreenshot == expected, "\(url.lastPathComponent)")
                #expect(entry.thumbnailURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
                #expect(entry.metadata.imagePixelWidth == 300)
            }
            #expect(try await fixture.store.counts()[.screenshots] == 2)
        }
    }

    @Test func recopyingModifiedFileRefreshesStoredCopy() async throws {
        try await withFixture { fixture in
            let original = try TestSupport.writeFile("draft.txt", in: fixture.originals, bytes: 10)
            let first = try await fixture.store.ingest(TestSupport.fileSnapshot([original])).entryID
            try Data(repeating: 0x42, count: 20).write(to: original)

            let second = try await fixture.store.ingest(TestSupport.fileSnapshot([original]))
            #expect(second == .replaced(first))
            let stored = try #require(try await fixture.store.entry(id: first)?.files.first?.storedCopyURL)
            #expect(try Data(contentsOf: stored).count == 20)
        }
    }
}
