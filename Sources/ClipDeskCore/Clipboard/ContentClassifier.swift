import AppKit
import Foundation
import UniformTypeIdentifiers

/// The result of classifying a pasteboard snapshot.
public struct ContentClassification: Sendable, Equatable {
    public var kind: ContentKind
    public var isScreenshot: Bool
    public var title: String
    public var previewText: String
    /// Full plain text for textual content, combined across items.
    public var text: String?
    public var fileURLs: [URL]
    /// The representation used for image previews and image deduplication.
    public var primaryImage: PrimaryImage?
    public var imageInfo: ImageInspector.Info?

    public struct PrimaryImage: Sendable, Equatable {
        public var itemIndex: Int
        public var type: String
    }
}

/// Decides what kind of content a snapshot holds, in priority order:
/// files, then text (links, code, plain text), then images, then other data.
public enum ContentClassifier {
    static let previewLength = 400
    static let titleLength = 200

    public static func classify(_ snapshot: PasteboardSnapshot) -> ContentClassification {
        let fileURLs = snapshot.items.compactMap(fileURL(in:))
        if !fileURLs.isEmpty {
            return classifyFiles(fileURLs)
        }

        let texts = snapshot.items.compactMap(plainText(in:))
        let text = texts.joined(separator: "\n")
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let image = primaryImage(in: snapshot)

        let textIsImageAddress = snapshot.items.count == 1 && linkURL(in: text) != nil
        if let image, !hasText || textIsImageAddress {
            // Image content. Browsers often attach the image's address as text; that does not make it a link.
            let data = snapshot.items[image.itemIndex].data(for: image.type) ?? Data()
            return classifyImage(image, info: ImageInspector.inspect(data: data), capturedAt: snapshot.capturedAt)
        }

        if hasText {
            let kind: ContentKind
            if snapshot.items.count == 1, linkURL(in: text) != nil {
                kind = .link
            } else if looksLikeCode(text) {
                kind = .code
            } else {
                kind = .text
            }
            let title = kind == .link
                ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                : firstLine(of: text)
            return ContentClassification(
                kind: kind,
                isScreenshot: false,
                title: String(title.prefix(titleLength)),
                previewText: collapsedPreview(of: text),
                text: text,
                fileURLs: [],
                primaryImage: image,
                imageInfo: nil
            )
        }

        let types = snapshot.items.flatMap(\.types)
        let title: String
        if types.contains(PasteboardTypes.pdf) {
            title = "PDF Data"
        } else if let first = types.first {
            title = PasteboardTypes.displayName(for: first)
        } else {
            title = "Clipboard Data"
        }
        return ContentClassification(
            kind: .other,
            isScreenshot: false,
            title: title,
            previewText: types.map(PasteboardTypes.displayName(for:)).joined(separator: ", "),
            text: nil,
            fileURLs: [],
            primaryImage: nil,
            imageInfo: nil
        )
    }

    // MARK: Files

    private static func classifyFiles(_ urls: [URL]) -> ContentClassification {
        let names = urls.map(\.lastPathComponent)
        let title = names.count == 1 ? names[0] : "\(names[0]) + \(names.count - 1) more"
        return ContentClassification(
            kind: .file,
            isScreenshot: urls.count == 1 && isScreenshotFileName(names[0]),
            title: title,
            previewText: String(names.joined(separator: ", ").prefix(previewLength)),
            text: nil,
            fileURLs: urls,
            primaryImage: nil,
            imageInfo: nil
        )
    }

    static func fileURL(in item: PasteboardSnapshot.Item) -> URL? {
        guard let data = item.data(for: PasteboardTypes.fileURL) else { return nil }
        let url = URL(dataRepresentation: data, relativeTo: nil)
            ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    /// Screenshot-style file names produced by macOS in common languages and by popular tools.
    static let screenshotNamePrefixes = [
        "Screenshot", "Screen Shot", "CleanShot", "Снимок экрана", "Bildschirmfoto",
        "Capture d’écran", "Capture d'écran", "Captura de pantalla", "Captura de Tela",
        "Schermata", "Schermafbeelding", "Skärmavbild", "Skjermbilde", "Skærmbillede",
        "Zrzut ekranu", "Ekran Resmi", "スクリーンショット", "截屏", "屏幕快照", "螢幕截圖", "스크린샷",
    ]

    static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    public static func isScreenshotFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard screenshotExtensions.contains(ext) else { return false }
        return screenshotNamePrefixes.contains { prefix in
            name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    // MARK: Images

    private static func classifyImage(
        _ image: ContentClassification.PrimaryImage,
        info: ImageInspector.Info?,
        capturedAt: Date
    ) -> ContentClassification {
        let isScreenshot = info?.hasScreenshotMetadata ?? false
        let title: String
        if isScreenshot {
            title = "Screenshot \(screenshotTimestamp(capturedAt))"
        } else if let info {
            title = "Image \(info.pixelWidth) × \(info.pixelHeight)"
        } else {
            title = "Image"
        }
        return ContentClassification(
            kind: .image,
            isScreenshot: isScreenshot,
            title: title,
            previewText: title,
            text: nil,
            fileURLs: [],
            primaryImage: image,
            imageInfo: info
        )
    }

    /// Picks the most useful image representation: PNG, then other image types.
    static func primaryImage(in snapshot: PasteboardSnapshot) -> ContentClassification.PrimaryImage? {
        let preferred = [PasteboardTypes.png, PasteboardTypes.jpeg, "public.heic", PasteboardTypes.tiff]
        for type in preferred {
            if let index = snapshot.items.firstIndex(where: { $0.data(for: type) != nil }) {
                return .init(itemIndex: index, type: type)
            }
        }
        for (index, item) in snapshot.items.enumerated() {
            if let type = item.types.first(where: isImageType) {
                return .init(itemIndex: index, type: type)
            }
        }
        return nil
    }

    static func isImageType(_ type: String) -> Bool {
        guard let utType = UTType(type) else { return false }
        return utType.conforms(to: .image) && !utType.conforms(to: .pdf)
    }

    private static func screenshotTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    // MARK: Text

    /// Extracts plain text from an item, preferring plain-text representations and falling back to RTF.
    public static func plainText(in item: PasteboardSnapshot.Item) -> String? {
        if let data = item.data(for: PasteboardTypes.plainText), let string = String(data: data, encoding: .utf8) {
            return string
        }
        for type in [PasteboardTypes.utf16PlainText, PasteboardTypes.utf16ExternalPlainText] {
            if let data = item.data(for: type), let string = String(data: data, encoding: .utf16) {
                return string
            }
        }
        if let data = item.data(for: PasteboardTypes.rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed.string
        }
        if let data = item.data(for: PasteboardTypes.url), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }

    /// Returns a URL when the text is exactly one web or mail link.
    public static func linkURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https", "ftp":
            return (url.host?.isEmpty == false) ? url : nil
        case "mailto":
            return trimmed.count > "mailto:".count ? url : nil
        default:
            return nil
        }
    }

    private static let codeKeywordPattern = try? NSRegularExpression(
        pattern: #"^\s*(func|let|var|import|class|struct|enum|protocol|extension|def|return|public|private|static|const|function|async|await|package|interface|fn|impl|using|namespace|#include|#import|SELECT|INSERT|UPDATE|CREATE|if|for|while|switch|try|catch)\b"#,
        options: [.anchorsMatchLines]
    )

    /// Heuristic code detection. Favors precision: ordinary prose should stay `.text`.
    public static func looksLikeCode(_ text: String) -> Bool {
        let sample = String(text.prefix(8_000))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        var codeLines = 0
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            let keyword = codeKeywordPattern?.firstMatch(in: line, range: range) != nil
            let structural = line.hasSuffix("{") || line.hasSuffix("};") || line == "}"
                || (line.hasSuffix(";") && line.contains("("))
                || line.contains("=>") || line.contains("->") || line.contains("::")
                || line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("</")
            if structural || (keyword && (line.contains("(") || line.contains("=") || line.contains(":") || line.hasSuffix("{"))) {
                codeLines += 1
            }
        }

        if lines.count == 1 {
            return codeLines == 1 && !lines[0].hasSuffix(".")
        }
        let indented = sample.split(separator: "\n").filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        let ratio = Double(codeLines) / Double(lines.count)
        return ratio >= 0.4 || (ratio >= 0.25 && indented >= 2)
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return line ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapsedPreview(of text: String) -> String {
        let prefix = text.prefix(previewLength * 2)
        let collapsed = prefix.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(previewLength))
    }

    /// Character, word and line counts. Word counting is skipped for very large text.
    public static func textStatistics(_ text: String) -> (characters: Int, words: Int?, lines: Int) {
        let characters = text.count
        let lines = text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard text.utf16.count <= 2_000_000 else { return (characters, nil, lines) }
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return (characters, words, lines)
    }
}
