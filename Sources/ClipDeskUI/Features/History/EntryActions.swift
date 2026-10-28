import AppKit
import ClipDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Context menu shared by the history list and the Menu Bar popover.
struct EntryContextMenu: View {
    @Environment(AppModel.self) private var model
    let entry: ClipEntry

    var body: some View {
        Button("Copy to Clipboard") {
            Task { await model.copy(entry) }
        }
        if entry.kind.isTextual {
            Button("Copy as Plain Text") {
                Task { await model.copy(entry, asPlainText: true) }
            }
        }
        if let url = EntryActions.linkURL(for: entry) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if entry.kind == .file {
            let urls = EntryActions.availableFileURLs(for: entry)
            Button("Open") { EntryActions.open(urls) }
                .disabled(urls.isEmpty)
            Button("Reveal in Finder") { EntryActions.reveal(urls) }
                .disabled(urls.isEmpty)
        }
        Divider()
        Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            Task { await model.toggleFavorite(entry) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await model.delete([entry.id]) }
        }
    }
}

@MainActor
enum EntryActions {
    static func linkURL(for entry: ClipEntry) -> URL? {
        guard entry.kind == .link else { return nil }
        return ContentClassifier.linkURL(in: entry.title)
    }

    static func availableFileURLs(for entry: ClipEntry) -> [URL] {
        entry.files.compactMap(\.bestAvailableURL)
    }

    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Saves an image entry's original bytes with a matching file extension.
    static func saveImage(_ source: EntryContent.ImageSource, type: String?, suggestedName: String, model: AppModel) {
        let utType = type.flatMap(UTType.init) ?? .png
        let panel = NSSavePanel()
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        let base = suggestedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(base).\(utType.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            switch source {
            case .file(let url):
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            case .data(let data):
                try data.write(to: destination, options: .atomic)
            }
            model.showToast("Image saved", style: .success)
        } catch {
            model.showToast("Couldn't save the image. \(error.localizedDescription)", style: .failure)
        }
    }
}
