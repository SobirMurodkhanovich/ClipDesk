import AppKit
import ClipDeskCore
import SwiftUI

/// The full history window: header, category sidebar, history list and preview panel.
struct HistoryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    static let minimumSize = CGSize(width: 760, height: 480)

    var body: some View {
        GeometryReader { proxy in
            let layout = HistoryLayout(width: proxy.size.width, showsPreview: model.settings.showPreviewPanel)
            VStack(spacing: 0) {
                HistoryHeader(layout: layout, isSearchFocused: $isSearchFocused, isListFocused: $isListFocused)
                HStack(spacing: 0) {
                    SidebarView(isCompact: layout.isSidebarCompact)
                        .frame(width: layout.sidebarWidth)
                    Hairline(axis: .vertical)
                    HistoryListView(isListFocused: $isListFocused)
                        .frame(width: layout.listWidth)
                        .frame(maxWidth: layout.listWidth == nil ? .infinity : nil)
                    if layout.showsPreview {
                        Hairline(axis: .vertical)
                        PreviewContainer()
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Theme.panel)
                .overlay(alignment: .top) { Hairline(axis: .horizontal) }
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(Theme.canvas)
        .toastOverlay(model.toast)
        .task(id: model.revision) {
            await model.reloadCounts()
        }
        .onAppear {
            model.openHistoryWindowAction = { openWindow(id: WindowID.history) }
        }
        .task(id: model.history.hasLoaded) {
            // Start with keyboard focus in the list (arrow keys, Return to copy) unless the user
            // already focused something else. Runs on open and once history first loads.
            try? await Task.sleep(for: .milliseconds(150))
            if !isSearchFocused {
                isListFocused = true
            }
        }
        .onChange(of: model.searchFocusRequest) {
            isSearchFocused = true
        }
        .clearHistoryConfirmation()
    }
}

/// Column widths for the current window width. Narrow windows get an icon-only sidebar.
struct HistoryLayout {
    let isSidebarCompact: Bool
    let sidebarWidth: CGFloat
    let listWidth: CGFloat?
    let showsPreview: Bool

    init(width: CGFloat, showsPreview: Bool) {
        isSidebarCompact = width < 900
        sidebarWidth = isSidebarCompact ? 60 : 210
        self.showsPreview = showsPreview
        let remaining = width - sidebarWidth - 2
        listWidth = showsPreview ? min(max(remaining * 0.45, 300), 440) : nil
    }
}

struct Hairline: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

private struct HistoryHeader: View {
    @Environment(AppModel.self) private var model
    let layout: HistoryLayout
    var isSearchFocused: FocusState<Bool>.Binding
    var isListFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var query = model.history
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                if !layout.isSidebarCompact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ClipDesk")
                            .font(.system(size: 15, weight: .bold))
                        Text("Clipboard Manager")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
            }
            .frame(width: layout.sidebarWidth - 28, alignment: .leading)

            SearchField(
                text: $query.searchText,
                prompt: "Search clipboard history…",
                isFocused: isSearchFocused,
                height: 36
            )
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .onKeyPress(.downArrow) {
                isListFocused.wrappedValue = true
                return .handled
            }

            HStack(spacing: 4) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HeaderIconButtonStyle())
                .help("Settings")

                ViewOptionsMenu()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 58)
        .padding(.bottom, 6)
    }
}

/// The sliders button: capture state and layout options.
private struct ViewOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Menu {
            Toggle("Capture Clipboard", isOn: Binding(
                get: { model.isCapturing },
                set: { model.setCaptureEnabled($0) }
            ))
            Divider()
            Toggle("Show Preview Panel", isOn: $settings.showPreviewPanel)
            Toggle("Group by Date", isOn: $settings.groupByDate)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .help("View Options")
    }
}

struct HeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(isPressed: configuration.isPressed) {
            configuration.label
                .foregroundStyle(Color.primary.opacity(0.8))
        }
    }

    private struct HoverBackground<Content: View>: View {
        let isPressed: Bool
        @ViewBuilder let content: Content
        @State private var isHovered = false

        var body: some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isPressed ? Theme.hover.opacity(1.5) : (isHovered ? Theme.hover : .clear))
                )
                .onHover { isHovered = $0 }
        }
    }
}

/// Search field used by the history window and the Menu Bar popover.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding
    var height: CGFloat = 32
    var showsShortcutHint = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
                .accessibilityLabel("Search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            } else if showsShortcutHint {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused.wrappedValue ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: isFocused.wrappedValue ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused.wrappedValue)
    }
}

extension View {
    /// Confirmation for the destructive "Clear History" bulk action.
    func clearHistoryConfirmation() -> some View {
        modifier(ClearHistoryConfirmation())
    }
}

private struct ClearHistoryConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        let removable = model.counts[.all] - model.counts[.favorites]
        content.alert("Clear clipboard history?", isPresented: $model.isClearConfirmationPresented) {
            Button("Clear History", role: .destructive) {
                Task { await model.clearHistory(includingFavorites: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(removable) \(removable == 1 ? "item" : "items") and their stored copies from this Mac. Favorites are kept.")
        }
    }
}
