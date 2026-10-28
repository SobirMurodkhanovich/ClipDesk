import AppKit
import ClipDeskCore
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Read-only, selectable text backed by NSTextView, which stays fast for very long content.
struct TextPreview: NSViewRepresentable {
    let text: String
    var isMonospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = false
            textView.textContainerInset = NSSize(width: 12, height: 14)
            textView.isAutomaticLinkDetectionEnabled = false
            textView.setAccessibilityLabel("Item content")
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.isMonospaced != isMonospaced else { return }
        coordinator.text = text
        coordinator.isMonospaced = isMonospaced

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = isMonospaced ? 2 : 4
        let font = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : NSFont.systemFont(ofSize: 14)
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        textView.scrollToBeginningOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var text: String?
        var isMonospaced = false
    }
}

/// Aspect-fit image preview, decoded off the main thread at a bounded size.
struct ImagePreview: View {
    let source: EntryContent.ImageSource
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image preview")
            } else if failed {
                EmptyStateView(systemImage: "photo", title: "Can’t Display Image", message: "The image data could not be decoded.")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) {
            let source = source
            let decoded = await Task.detached(priority: .userInitiated) { () -> SendableImage? in
                switch source {
                case .file(let url):
                    ImageInspector.downsampledImage(url: url, maxPixelSize: 2_400).map(SendableImage.init)
                case .data(let data):
                    ImageInspector.downsampledImage(data: data, maxPixelSize: 2_400).map(SendableImage.init)
                }
            }.value
            guard let cgImage = decoded?.image else {
                failed = true
                return
            }
            // Treat image pixels as 2x points so Retina screenshots appear at their natural size.
            image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        }
    }
}

/// Native Quick Look preview for documents (PDF, Office files, images, and more).
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Preview for file entries: Quick Look for a single file, a list for several.
struct FilePreview: View {
    let entry: ClipEntry

    var body: some View {
        if entry.files.count == 1, let file = entry.files.first {
            SingleFilePreview(file: file)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entry.files) { file in
                        FileListRow(file: file)
                        if file.id != entry.files.last?.id {
                            Hairline(axis: .horizontal).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct SingleFilePreview: View {
    let file: ClipFile

    /// The managed copy shows exactly what was copied and avoids re-reading protected folders.
    private var previewURL: URL? {
        if let stored = file.storedCopyURL, FileManager.default.fileExists(atPath: stored.path) {
            return stored
        }
        return file.availability == .original ? file.originalURL : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let url = previewURL, !file.isDirectory {
                QuickLookPreview(url: url)
            } else {
                VStack(spacing: 10) {
                    Image(nsImage: FileIcons.icon(for: file))
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text(file.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(file.availability == .unavailable ? "This file is no longer available." : "No preview available for this item.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline(axis: .horizontal)
            FileDetailsGrid(file: file)
                .padding(14)
                .background(Theme.panel.opacity(0.6))
        }
    }
}

private struct FileDetailsGrid: View {
    let file: ClipFile

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Name", file.fileName)
            row("Kind", kindDescription)
            if let size = file.byteSize {
                row("Size", Formatters.bytes(size))
            }
            GridRow {
                label("Location")
                Text(file.originalURL.deletingLastPathComponent().path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.originalURL.path)
                    .textSelection(.enabled)
            }
            GridRow {
                label("Status")
                FileAvailabilityLabel(file: file)
            }
            GridRow {
                label("Storage")
                Text(file.storage.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindDescription: String {
        if file.isDirectory { return "Folder" }
        let type = file.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: file.fileExtension)
        return type?.localizedDescription ?? (file.fileExtension.isEmpty ? "Document" : file.fileExtension.uppercased())
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

struct FileAvailabilityLabel: View {
    let file: ClipFile

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch file.availability {
        case .original: "Available"
        case .storedCopy: "Original moved or deleted — stored copy available"
        case .unavailable: "Unavailable"
        }
    }

    private var color: Color {
        switch file.availability {
        case .original: .green
        case .storedCopy: .orange
        case .unavailable: .red
        }
    }
}

private struct FileListRow: View {
    let file: ClipFile

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(for: file))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let size = file.byteSize {
                        Text(Formatters.bytes(size))
                    }
                    FileAvailabilityLabel(file: file)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help(file.originalURL.path)
    }
}
