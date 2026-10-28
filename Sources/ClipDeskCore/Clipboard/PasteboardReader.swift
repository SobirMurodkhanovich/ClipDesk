import AppKit
import Foundation

public struct PasteboardReadOptions: Sendable, Equatable {
    /// Largest representation (and largest total per capture) that will be retained.
    public var maxCaptureBytes: Int
    /// Limit for representations of types ClipDesk does not specifically understand.
    public var maxUnknownRepresentationBytes: Int
    /// Skip content marked concealed/transient by the source app (for example password managers).
    public var ignorePrivacyMarkedContent: Bool

    public init(maxCaptureBytes: Int, maxUnknownRepresentationBytes: Int = 2 * 1_048_576, ignorePrivacyMarkedContent: Bool = true) {
        self.maxCaptureBytes = maxCaptureBytes
        self.maxUnknownRepresentationBytes = maxUnknownRepresentationBytes
        self.ignorePrivacyMarkedContent = ignorePrivacyMarkedContent
    }

    public static let `default` = PasteboardReadOptions(maxCaptureBytes: 100 * 1_048_576)
}

public enum PasteboardReadResult: Sendable, Equatable {
    case captured(PasteboardSnapshot)
    case skipped(SkipReason)

    public enum SkipReason: Sendable, Equatable {
        case empty
        case privacyMarked
        case ownWrite
        case noReadableData
    }
}

/// Copies the contents of a pasteboard into a `PasteboardSnapshot`.
public enum PasteboardReader {
    public static func read(
        _ pasteboard: NSPasteboard,
        options: PasteboardReadOptions,
        sourceApp: SourceApplication? = nil,
        now: Date = Date()
    ) -> PasteboardReadResult {
        let changeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return .skipped(.empty)
        }

        let itemTypes = pasteboardItems.map { $0.types.map(\.rawValue) }
        let allTypes = Set(itemTypes.joined())
        if allTypes.contains(PasteboardTypes.restoreMarker) {
            return .skipped(.ownWrite)
        }
        if options.ignorePrivacyMarkedContent, !allTypes.isDisjoint(with: PasteboardTypes.privacyMarkers) {
            return .skipped(.privacyMarked)
        }

        var items: [PasteboardSnapshot.Item] = []
        var omitted: [String] = []
        var budget = options.maxCaptureBytes

        for (pasteboardItem, types) in zip(pasteboardItems, itemTypes) {
            var retained: [String: Data] = [:]
            for type in readOrder(for: types) {
                guard let data = pasteboardItem.data(forType: NSPasteboard.PasteboardType(type)) else {
                    omitted.append(type)
                    continue
                }
                let limit = PasteboardTypes.knownTypes.contains(type)
                    ? options.maxCaptureBytes
                    : min(options.maxUnknownRepresentationBytes, options.maxCaptureBytes)
                guard data.count <= limit, data.count <= budget else {
                    omitted.append(type)
                    continue
                }
                budget -= data.count
                retained[type] = data
            }
            // Keep the source app's order: it lists representations from richest to plainest.
            let representations = types.compactMap { type in
                retained[type].map { PasteboardSnapshot.Representation(type: type, data: $0) }
            }
            if !representations.isEmpty {
                items.append(PasteboardSnapshot.Item(representations: representations))
            }
        }

        guard !items.isEmpty else { return .skipped(.noReadableData) }
        return .captured(PasteboardSnapshot(
            items: items,
            changeCount: changeCount,
            capturedAt: now,
            sourceApp: sourceApp,
            omittedTypes: Array(Set(omitted)).sorted()
        ))
    }

    /// The types to read for one item, most important first, so that the byte budget
    /// is spent on the representations that matter most.
    static func readOrder(for types: [String]) -> [String] {
        let candidates = types.filter { type in
            !PasteboardTypes.isFilePromise(type)
                && !PasteboardTypes.privacyMarkers.contains(type)
                && type != PasteboardTypes.restoreMarker
        }

        if candidates.contains(PasteboardTypes.fileURL) {
            // Finder also provides icons and legacy filename lists; file URLs are restored directly.
            return candidates.filter { $0 == PasteboardTypes.fileURL || $0 == PasteboardTypes.plainText }
        }

        var filtered = candidates
        if filtered.contains(PasteboardTypes.plainText) {
            // The pasteboard synthesizes UTF-16 text from UTF-8 on demand, so it need not be stored twice.
            filtered.removeAll { $0 == PasteboardTypes.utf16ExternalPlainText || $0 == PasteboardTypes.utf16PlainText }
        }
        if filtered.contains(PasteboardTypes.png) {
            // TIFF beside PNG is a large, redundant copy of the same image.
            filtered.removeAll { $0 == PasteboardTypes.tiff }
        }

        let priority = [
            PasteboardTypes.plainText, PasteboardTypes.utf16PlainText, PasteboardTypes.url,
            PasteboardTypes.urlName, PasteboardTypes.rtf, PasteboardTypes.html,
            PasteboardTypes.png, PasteboardTypes.jpeg, PasteboardTypes.tiff, PasteboardTypes.rtfd,
        ]
        let ranked = priority.filter(filtered.contains)
        return ranked + filtered.filter { !ranked.contains($0) }
    }
}
