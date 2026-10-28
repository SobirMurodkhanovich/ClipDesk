import AppKit
import Foundation
import Testing
@testable import ClipDeskCore

/// Exercises the real NSPasteboard APIs against private, uniquely named pasteboards,
/// so the user's general clipboard is never read or modified.
@MainActor
@Suite("Pasteboard integration", .serialized)
struct PasteboardIntegrationTests {
    private func withPasteboard(_ body: (NSPasteboard) async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try await body(pasteboard)
    }

    private func write(_ items: [[(String, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    private func captured(_ result: PasteboardReadResult?) -> PasteboardSnapshot? {
        if case .captured(let snapshot) = result { snapshot } else { nil }
    }

    @Test func readsEveryRepresentationInOriginalOrder() async {
        await withPasteboard { pasteboard in
            write([[
                (PasteboardTypes.rtf, Data("{\\rtf1 Hi}".utf8)),
                (PasteboardTypes.html, Data("<b>Hi</b>".utf8)),
                (PasteboardTypes.plainText, Data("Hi".utf8)),
            ]], to: pasteboard)
            let snapshot = captured(PasteboardReader.read(pasteboard, options: .default))
            #expect(snapshot?.items.count == 1)
            // Representations keep the pasteboard's own order; the synthesized UTF-16 copy is not stored.
            let pasteboardOrder = (pasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
                .filter { $0 != PasteboardTypes.utf16ExternalPlainText }
            #expect(snapshot?.items.first?.types == pasteboardOrder)
            #expect(Set(snapshot?.items.first?.types ?? []) == [PasteboardTypes.rtf, PasteboardTypes.html, PasteboardTypes.plainText])
            #expect(snapshot?.changeCount == pasteboard.changeCount)
        }
    }

    @Test func readsMultipleItems() async {
        await withPasteboard { pasteboard in
            write([
                [(PasteboardTypes.plainText, Data("one".utf8))],
                [(PasteboardTypes.plainText, Data("two".utf8))],
            ], to: pasteboard)
            let snapshot = captured(PasteboardReader.read(pasteboard, options: .default))
            #expect(snapshot?.items.compactMap { $0.data(for: PasteboardTypes.plainText) } == [Data("one".utf8), Data("two".utf8)])
        }
    }

    @Test func skipsConcealedAndTransientContentByDefault() async {
        await withPasteboard { pasteboard in
            for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
                write([[(PasteboardTypes.plainText, Data("secret".utf8)), (marker, Data())]], to: pasteboard)
                #expect(PasteboardReader.read(pasteboard, options: .default) == .skipped(.privacyMarked))
                var options = PasteboardReadOptions.default
                options.ignorePrivacyMarkedContent = false
                #expect(captured(PasteboardReader.read(pasteboard, options: options)) != nil)
            }
        }
    }

    @Test func recognizesEmptyAndOwnWrites() async {
        await withPasteboard { pasteboard in
            pasteboard.clearContents()
            #expect(PasteboardReader.read(pasteboard, options: .default) == .skipped(.empty))
            PasteboardWriter.write(RestorePayload(items: [.representations([TestSupport.representation(PasteboardTypes.plainText, "x")])]), to: pasteboard)
            #expect(PasteboardReader.read(pasteboard, options: .default) == .skipped(.ownWrite))
        }
    }

    @Test func dropsRedundantTIFFAndOversizedUnknownData() async throws {
        try await withPasteboard { pasteboard in
            let png = try TestSupport.pngData()
            write([[
                (PasteboardTypes.png, png),
                (PasteboardTypes.tiff, Data(repeating: 1, count: 5_000)),
                ("com.example.huge", Data(repeating: 2, count: 3_000_000)),
            ]], to: pasteboard)
            let snapshot = try #require(captured(PasteboardReader.read(pasteboard, options: .default)))
            #expect(snapshot.items.first?.types == [PasteboardTypes.png])
            #expect(snapshot.omittedTypes == ["com.example.huge"])
        }
    }

    @Test func respectsMaximumCaptureSize() async {
        await withPasteboard { pasteboard in
            write([[(PasteboardTypes.plainText, Data(repeating: 0x61, count: 2_000))]], to: pasteboard)
            let options = PasteboardReadOptions(maxCaptureBytes: 1_000)
            #expect(PasteboardReader.read(pasteboard, options: options) == .skipped(.noReadableData))
        }
    }

    @Test func finderStyleFileCopyKeepsOnlyURLAndName() async throws {
        try await withPasteboard { pasteboard in
            let url = URL(fileURLWithPath: "/tmp/Report.pdf")
            write([[
                (PasteboardTypes.fileURL, Data(url.absoluteString.utf8)),
                (PasteboardTypes.plainText, Data("Report.pdf".utf8)),
                ("com.apple.icns", Data(repeating: 3, count: 1_000)),
            ]], to: pasteboard)
            let snapshot = try #require(captured(PasteboardReader.read(pasteboard, options: .default)))
            #expect(snapshot.items.first?.types == [PasteboardTypes.fileURL, PasteboardTypes.plainText])
            #expect(ContentClassifier.classify(snapshot).fileURLs == [url])
        }
    }

    @Test func storedContentRoundTripsThroughPasteboard() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        let store = try HistoryStore(directory: directory)
        try await withPasteboard { source in
            let png = try TestSupport.pngData(width: 120, height: 80)
            write([
                [(PasteboardTypes.html, Data("<i>caption</i>".utf8)), (PasteboardTypes.plainText, Data("caption".utf8))],
                [(PasteboardTypes.png, png)],
            ], to: source)
            let snapshot = try #require(captured(PasteboardReader.read(source, options: .default)))
            let id = try await store.ingest(snapshot).entryID

            try await withPasteboard { destination in
                let payload = try await store.restorePayload(for: id)
                #expect(PasteboardWriter.write(payload, to: destination) == destination.changeCount)
                let items = try #require(destination.pasteboardItems)
                #expect(items.count == 2)
                #expect(items[0].string(forType: .html) == "<i>caption</i>")
                #expect(items[0].string(forType: .string) == "caption")
                #expect(items[1].data(forType: .png) == png)
            }
        }
    }

    @Test func monitorCapturesExternalChangesAndIgnoresOwnWrites() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { TestSupport.removeItem(directory) }
        let store = try HistoryStore(directory: directory)
        try await withPasteboard { pasteboard in
            let captures = Collector<PasteboardSnapshot>()
            let monitor = ClipboardMonitor(pasteboard: pasteboard, interval: 60) { captures.append($0) }
            monitor.start()
            defer { monitor.stop() }
            #expect(monitor.isRunning)
            #expect(monitor.pollNow() == nil)

            // An external copy is captured.
            write([[(PasteboardTypes.plainText, Data("external".utf8))]], to: pasteboard)
            #expect(captured(monitor.pollNow()) != nil)
            let snapshot = try #require(captures.values.last)
            let id = try await store.ingest(snapshot).entryID

            // Copying it back from history is not captured again.
            let changeCount = try #require(PasteboardWriter.write(try await store.restorePayload(for: id), to: pasteboard))
            monitor.ignoreChange(count: changeCount)
            #expect(monitor.pollNow() == .skipped(.ownWrite))
            #expect(captures.values.count == 1)
            #expect(try await store.entries().count == 1)

            // Copying the same text again from another app refreshes the existing entry.
            write([[(PasteboardTypes.plainText, Data("external".utf8))]], to: pasteboard)
            let again = try #require(captured(monitor.pollNow()))
            #expect(try await store.ingest(again) == .refreshed(id))
            #expect(try await store.entries().count == 1)
        }
    }

    @Test func contentCopiedWhilePausedIsNotCaptured() async {
        await withPasteboard { pasteboard in
            let captures = Collector<PasteboardSnapshot>()
            let monitor = ClipboardMonitor(pasteboard: pasteboard, interval: 60) { captures.append($0) }
            monitor.start()
            monitor.stop()
            #expect(!monitor.isRunning)

            write([[(PasteboardTypes.plainText, Data("while paused".utf8))]], to: pasteboard)
            monitor.start()
            defer { monitor.stop() }
            #expect(monitor.pollNow() == nil)

            write([[(PasteboardTypes.plainText, Data("after resume".utf8))]], to: pasteboard)
            #expect(captured(monitor.pollNow()) != nil)
            #expect(captures.values.count == 1)
        }
    }

    @Test func timerDrivenMonitoringDeliversCaptures() async throws {
        try await withPasteboard { pasteboard in
            let captures = Collector<PasteboardSnapshot>()
            let monitor = ClipboardMonitor(pasteboard: pasteboard, interval: 0.1) { captures.append($0) }
            monitor.start()
            defer { monitor.stop() }
            write([[(PasteboardTypes.plainText, Data("timed".utf8))]], to: pasteboard)
            for _ in 0..<40 where captures.values.isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(captures.values.count == 1)
        }
    }
}
