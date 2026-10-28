import AppKit
import Foundation

/// One pasteboard item to restore.
public enum RestoreItem: Sendable, Equatable {
    /// Stored representations written back verbatim.
    case representations([PasteboardSnapshot.Representation])
    /// A file reference, plus any additional representations captured with it (such as the file name).
    case file(URL, extra: [PasteboardSnapshot.Representation])
}

/// Content ready to be written to the pasteboard, with any fidelity warnings for the user.
public struct RestorePayload: Sendable, Equatable {
    public var items: [RestoreItem]
    public var warnings: [String]

    public init(items: [RestoreItem], warnings: [String] = []) {
        self.items = items
        self.warnings = warnings
    }
}

/// Writes history content back to a pasteboard.
@MainActor
public enum PasteboardWriter {
    /// Replaces the pasteboard contents. Returns the resulting `changeCount`, or `nil` if the write failed.
    @discardableResult
    public static func write(_ payload: RestorePayload, to pasteboard: NSPasteboard) -> Int? {
        guard !payload.items.isEmpty else { return nil }
        let pasteboardItems = payload.items.enumerated().map { index, item in
            let pasteboardItem = NSPasteboardItem()
            switch item {
            case .representations(let representations):
                for representation in representations {
                    pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
            case .file(let url, let extra):
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                for representation in extra where representation.type != PasteboardTypes.fileURL {
                    pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
            }
            if index == 0 {
                pasteboardItem.setString("1", forType: NSPasteboard.PasteboardType(PasteboardTypes.restoreMarker))
            }
            return pasteboardItem
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else { return nil }
        return pasteboard.changeCount
    }
}
