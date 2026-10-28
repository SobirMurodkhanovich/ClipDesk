import Foundation
import Testing
@testable import ClipDeskCore

@Suite("Content classification")
struct ContentClassifierTests {
    @Test func plainTextUsesFirstLineAsTitle() {
        let text = "\n  Build amazing apps with SwiftUI for macOS.\nA powerful declarative framework."
        let result = ContentClassifier.classify(TestSupport.textSnapshot(text))
        #expect(result.kind == .text)
        #expect(result.title == "Build amazing apps with SwiftUI for macOS.")
        #expect(result.previewText == "Build amazing apps with SwiftUI for macOS. A powerful declarative framework.")
        #expect(result.text == text)
    }

    @Test(arguments: ["https://developer.apple.com", "http://example.com/path?q=1", "mailto:someone@example.com"])
    func singleURLIsLink(url: String) {
        #expect(ContentClassifier.classify(TestSupport.textSnapshot(url)).kind == .link)
    }

    @Test(arguments: ["see https://apple.com for details", "https://", "file:///etc/hosts", "ftp://"])
    func textContainingOrMalformedURLIsNotLink(text: String) {
        #expect(ContentClassifier.classify(TestSupport.textSnapshot(text)).kind != .link)
    }

    @Test func singleLineDeclarationIsCode() {
        #expect(ContentClassifier.classify(TestSupport.textSnapshot("struct ContentView: View {")).kind == .code)
    }

    @Test func multilineCodeIsCode() {
        let code = """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("Hello")
                }
            }
            """
        #expect(ContentClassifier.classify(TestSupport.textSnapshot(code)).kind == .code)
    }

    @Test(arguments: [
        "Meeting notes for the new feature. We discussed the timeline and owners.",
        "If you can, call me tomorrow.",
        "Remember: buy milk, eggs and bread.",
        "Hello",
    ])
    func proseIsText(text: String) {
        #expect(ContentClassifier.classify(TestSupport.textSnapshot(text)).kind == .text)
    }

    @Test func imageOnlyIsImage() throws {
        let png = try TestSupport.pngData(width: 4, height: 3)
        let result = ContentClassifier.classify(TestSupport.imageSnapshot(png))
        #expect(result.kind == .image)
        #expect(!result.isScreenshot)
        #expect(result.title == "Image 4 × 3")
        #expect(result.primaryImage?.type == PasteboardTypes.png)
    }

    @Test func imageWithScreenshotMetadataIsScreenshot() throws {
        let png = try TestSupport.pngData(userComment: "Screenshot")
        let date = Date(timeIntervalSince1970: 1_733_049_492)
        let result = ContentClassifier.classify(TestSupport.imageSnapshot(png, at: date))
        #expect(result.kind == .image)
        #expect(result.isScreenshot)
        #expect(result.title.hasPrefix("Screenshot 20"))
    }

    @Test func imageWithItsWebAddressStaysImage() throws {
        let png = try TestSupport.pngData()
        let snapshot = PasteboardSnapshot(items: [.init(representations: [
            .init(type: PasteboardTypes.png, data: png),
            TestSupport.representation(PasteboardTypes.plainText, "https://example.com/photo.png"),
        ])])
        #expect(ContentClassifier.classify(snapshot).kind == .image)
    }

    @Test func textWithImageRepresentationStaysText() throws {
        let png = try TestSupport.pngData()
        let snapshot = TestSupport.textSnapshot("Quarterly results", extra: [.init(type: PasteboardTypes.png, data: png)])
        let result = ContentClassifier.classify(snapshot)
        #expect(result.kind == .text)
        #expect(result.primaryImage != nil)
    }

    @Test func richTextOnlyExtractsPlainText() throws {
        let rtf = try #require("{\\rtf1\\ansi Bold \\b text\\b0}".data(using: .utf8))
        let snapshot = PasteboardSnapshot(items: [.init(representations: [.init(type: PasteboardTypes.rtf, data: rtf)])])
        let result = ContentClassifier.classify(snapshot)
        #expect(result.kind == .text)
        #expect(result.text?.contains("Bold") == true)
    }

    @Test func fileURLsAreFiles() {
        let urls = [URL(fileURLWithPath: "/tmp/Design_Document.pdf"), URL(fileURLWithPath: "/tmp/Plan.docx")]
        let result = ContentClassifier.classify(TestSupport.fileSnapshot(urls))
        #expect(result.kind == .file)
        #expect(result.fileURLs == urls)
        #expect(result.title == "Design_Document.pdf + 1 more")
        #expect(!result.isScreenshot)
    }

    @Test func screenshotFileNameIsScreenshot() {
        let url = URL(fileURLWithPath: "/tmp/Screenshot 2024-12-01 at 10.38.12.png")
        let result = ContentClassifier.classify(TestSupport.fileSnapshot([url]))
        #expect(result.kind == .file)
        #expect(result.isScreenshot)
    }

    @Test(arguments: [
        ("Screenshot 2024-12-01 at 10.38.12.png", true),
        ("Screen Shot 2020-01-01 at 9.00.00 AM.png", true),
        ("Снимок экрана 2024-12-01 в 10.38.12.png", true),
        ("CleanShot 2024-05-01 at 10.00.00@2x.png", true),
        ("Screenshot notes.txt", false),
        ("Screen Recording 2024-12-01.mov", false),
        ("AppIcon.png", false),
    ])
    func screenshotFileNames(name: String, expected: Bool) {
        #expect(ContentClassifier.isScreenshotFileName(name) == expected)
    }

    @Test func unknownDataIsOther() {
        let snapshot = PasteboardSnapshot(items: [.init(representations: [
            TestSupport.representation("com.example.custom-data", "payload"),
        ])])
        let result = ContentClassifier.classify(snapshot)
        #expect(result.kind == .other)
        #expect(result.title == "com.example.custom-data")
    }

    @Test func textStatistics() {
        let stats = ContentClassifier.textStatistics("Build amazing apps\nwith SwiftUI")
        #expect(stats.characters == 31)
        #expect(stats.words == 5)
        #expect(stats.lines == 2)
    }
}
