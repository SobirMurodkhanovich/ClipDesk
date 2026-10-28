import AppKit
import ClipDeskCore
import SwiftUI

/// The right column: shows the selected entry or a placeholder.
struct PreviewContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let entry = model.history.selectedEntry {
                PreviewPanel(entry: entry)
                    .id(entry.id)
            } else if model.history.hasLoaded && !model.history.entries.isEmpty {
                EmptyStateView(systemImage: "sidebar.right", title: "No Selection", message: "Select an item to preview it.")
            } else {
                EmptyStateView(systemImage: "doc.on.clipboard", title: "Nothing to Preview", message: "Copied items appear here in detail.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    let entry: ClipEntry
    @State private var content: EntryContent?
    @State private var loadError: String?

    private struct LoadKey: Equatable {
        var id: UUID
        var lastUsedAt: Date
        var byteCount: Int64
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.well))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            PreviewInfoBar(entry: entry, content: content)
            PreviewDetails(entry: entry)
            actions
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .task(id: LoadKey(id: entry.id, lastUsedAt: entry.lastUsedAt, byteCount: entry.byteCount)) {
            do {
                content = try await model.content(for: entry)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isScreenshot ? "camera" : entry.kind.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(entry.kindLabel)
                .font(.system(size: 14, weight: .semibold))
            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.favorite)
                    .accessibilityLabel("Favorite")
            }
            Spacer(minLength: 8)
            Text(Formatters.detailTimestamp(entry.lastUsedAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let loadError {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Can’t Show This Item", message: loadError)
        } else if entry.kind == .file {
            FilePreview(entry: entry)
        } else if let content {
            switch entry.kind {
            case .text, .code, .link:
                if let text = content.text {
                    VStack(spacing: 0) {
                        TextPreview(text: text, isMonospaced: entry.kind == .code)
                        if content.isTextTruncated {
                            Text("Showing the first \(Formatters.number(text.count)) characters. Copy to get the full text.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                } else {
                    EmptyStateView(systemImage: "text.badge.xmark", title: "No Text", message: "This item has no plain-text representation.")
                }
            case .image:
                if let image = content.image {
                    ImagePreview(source: image)
                } else {
                    EmptyStateView(systemImage: "photo", title: "Image Unavailable", message: "The stored image could not be found.")
                }
            case .other, .file:
                RepresentationListView(content: content)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(compact: false)
            actionButtons(compact: true)
        }
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.copy(entry) }
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(ClipDeskButtonStyle(kind: .primary))
            .disabled(entry.kind == .file && entry.files.allSatisfy { $0.availability == .unavailable })

            Button {
                Task { await model.toggleFavorite(entry) }
            } label: {
                if compact {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                } else {
                    Label(entry.isFavorite ? "Unfavorite" : "Favorite", systemImage: entry.isFavorite ? "star.fill" : "star")
                }
            }
            .buttonStyle(ClipDeskButtonStyle())
            .help(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Button {
                Task { await model.delete([entry.id]) }
            } label: {
                if compact {
                    Image(systemName: "trash")
                } else {
                    Label("Delete", systemImage: "trash")
                }
            }
            .buttonStyle(ClipDeskButtonStyle())
            .help("Delete from History")
            .accessibilityLabel("Delete")

            Spacer(minLength: 0)
        }
    }
}

/// Counts and the context-specific secondary action under the preview.
private struct PreviewInfoBar: View {
    @Environment(AppModel.self) private var model
    let entry: ClipEntry
    let content: EntryContent?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(facts, id: \.self) { fact in
                Text(fact)
            }
            Spacer(minLength: 8)
            secondaryActions
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minHeight: 30)
    }

    private var facts: [String] {
        let metadata = entry.metadata
        switch entry.kind {
        case .text, .code, .link:
            var facts: [String] = []
            if let characters = metadata.characterCount {
                facts.append("\(Formatters.number(characters)) \(characters == 1 ? "character" : "characters")")
            }
            if let words = metadata.wordCount {
                facts.append("\(Formatters.number(words)) \(words == 1 ? "word" : "words")")
            }
            if let lines = metadata.lineCount, lines > 1 {
                facts.append("\(Formatters.number(lines)) lines")
            }
            return facts
        case .image:
            var facts: [String] = []
            if let width = metadata.imagePixelWidth, let height = metadata.imagePixelHeight {
                facts.append("\(width) × \(height)")
            }
            if let type = content?.imageType {
                facts.append(PasteboardTypes.displayName(for: type))
            }
            facts.append(Formatters.bytes(entry.byteCount))
            return facts
        case .file:
            let total = entry.files.compactMap(\.byteSize).reduce(0, +)
            let count = entry.files.count
            return [count == 1 ? "1 file" : "\(count) files", Formatters.bytes(total)]
        case .other:
            return ["\(entry.typeIdentifiers.count) formats", Formatters.bytes(entry.byteCount)]
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch entry.kind {
        case .text, .code:
            IconButton(systemImage: "doc.on.doc", help: "Copy as Plain Text") {
                Task { await model.copy(entry, asPlainText: true) }
            }
        case .link:
            if let url = EntryActions.linkURL(for: entry) {
                IconButton(systemImage: "safari", help: "Open Link") {
                    NSWorkspace.shared.open(url)
                }
            }
            IconButton(systemImage: "doc.on.doc", help: "Copy as Plain Text") {
                Task { await model.copy(entry, asPlainText: true) }
            }
        case .image:
            if let image = content?.image {
                IconButton(systemImage: "square.and.arrow.down", help: "Save Image…") {
                    EntryActions.saveImage(image, type: content?.imageType, suggestedName: entry.title, model: model)
                }
            }
        case .file:
            let urls = EntryActions.availableFileURLs(for: entry)
            if !urls.isEmpty {
                IconButton(systemImage: "arrow.up.forward.app", help: "Open") {
                    EntryActions.open(urls)
                }
                IconButton(systemImage: "folder", help: "Reveal in Finder") {
                    EntryActions.reveal(urls)
                }
            }
        case .other:
            EmptyView()
        }
    }
}

/// Source app, retained formats and any fidelity limitations.
private struct PreviewDetails: View {
    let entry: ClipEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(entry.typeIdentifiers.joined(separator: "\n"))
            if !entry.metadata.omittedTypes.isEmpty {
                Label {
                    Text("Not saved: \(entry.metadata.omittedTypes.map(PasteboardTypes.displayName(for:)).joined(separator: ", ")) — too large or unreadable.")
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(.secondary)
                .help(entry.metadata.omittedTypes.joined(separator: "\n"))
            }
        }
        .font(.system(size: 11.5))
    }

    private var summary: String {
        var parts: [String] = []
        if let name = entry.sourceApp?.name {
            parts.append("From \(name)")
        }
        let formats = entry.typeIdentifiers
            .filter { !$0.hasPrefix("dyn.") }
            .map(PasteboardTypes.displayName(for:))
        var uniqueFormats: [String] = []
        for format in formats where !uniqueFormats.contains(format) {
            uniqueFormats.append(format)
        }
        if !uniqueFormats.isEmpty {
            parts.append(uniqueFormats.prefix(4).joined(separator: ", ") + (uniqueFormats.count > 4 ? " +\(uniqueFormats.count - 4)" : ""))
        }
        if entry.itemCount > 1 {
            parts.append("\(entry.itemCount) items")
        }
        if entry.useCount > 1 {
            parts.append("Copied \(entry.useCount) times")
        }
        if entry.createdAt < entry.lastUsedAt.addingTimeInterval(-60) {
            parts.append("First copied \(Formatters.rowTimestamp(entry.createdAt))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Lists retained representations for content ClipDesk can't render directly.
private struct RepresentationListView: View {
    let content: EntryContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("This item contains data ClipDesk can’t preview. It is restored exactly as it was copied.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(Array(content.representations.enumerated()), id: \.offset) { _, representation in
                    HStack {
                        Text(PasteboardTypes.displayName(for: representation.type))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(Formatters.bytes(representation.byteCount))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }
}
