import AppKit
import ClipDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// The ClipDesk brand mark: a white clipboard on a blue rounded square.
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(nsColor: NSColor(hex: 0x3B8BFF)), Color(nsColor: NSColor(hex: 0x1F6FEB))],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: "list.clipboard")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// Square icon tile shown in list rows: a thumbnail for images, the system icon for files,
/// and a symbol for text, code, and links.
struct EntryIconTile: View {
    let entry: ClipEntry
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let thumbnail = entry.thumbnailURL {
                ThumbnailImage(url: thumbnail, fallback: AnyView(symbolTile))
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(Theme.stroke))
            } else if entry.kind == .file, let file = entry.files.first {
                Image(nsImage: FileIcons.icon(for: file))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.04)
            } else {
                symbolTile
            }
        }
        .frame(width: size, height: size)
    }

    private var symbolTile: some View {
        let highlighted = entry.kind == .code || entry.kind == .link
        return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(highlighted ? Theme.accentTile : Theme.tile)
            .overlay {
                Image(systemName: entry.isScreenshot ? "camera" : entry.kind.systemImage)
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(highlighted ? Theme.accent : Theme.tileGlyph)
            }
    }
}

/// Loads a downsampled image from disk off the main thread, with an in-memory cache.
struct ThumbnailImage: View {
    let url: URL
    var maxPixelSize = 192
    var contentMode: ContentMode = .fill
    var fallback: AnyView = AnyView(Color.clear)
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                fallback
            }
        }
        .task(id: url) {
            image = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = key(url, maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        let loaded = await Task.detached(priority: .utility) {
            ImageInspector.downsampledImage(url: url, maxPixelSize: maxPixelSize).map(SendableImage.init)
        }.value
        guard let cgImage = loaded?.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    private func key(_ url: URL, _ size: Int) -> NSString {
        "\(size)|\(url.path)" as NSString
    }
}

/// CGImage is immutable and safe to pass between threads.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

@MainActor
enum FileIcons {
    static func icon(for file: ClipFile) -> NSImage {
        if let url = file.bestAvailableURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = file.typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: file.fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: file.isDirectory ? .folder : type)
    }
}

/// Button styles matching the reference design.
struct ClipDeskButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(kind == .primary ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(kind == .primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.panel))
                        .overlay {
                            if kind == .primary {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.black.opacity(configuration.isPressed ? 0.15 : (isHovered ? 0.06 : 0)))
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(configuration.isPressed ? Theme.hover : (isHovered ? Theme.hover.opacity(0.6) : .clear))
                            }
                        }
                }
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.stroke)
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// Small borderless icon button with a hover background.
struct IconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 30
    var isActive = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.75))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? Theme.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }
}

/// Transient feedback shown at the bottom of a window or popover.
struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        Label {
            Text(toast.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: toast.systemImage)
                .foregroundStyle(color)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch toast.style {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

extension View {
    /// Overlays the model's current toast.
    func toastOverlay(_ toast: ToastMessage?) -> some View {
        overlay(alignment: .bottom) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }
}

/// A centered message for empty and error states.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ClipDeskButtonStyle(kind: .secondary))
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
