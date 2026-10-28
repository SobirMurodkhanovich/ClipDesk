import AppKit
import ClipDeskCore
import SwiftUI

/// Compact quick-access popover shown from the menu bar: search, recent items, quick copy.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var highlighted: ClipEntry.ID?

    static let size = CGSize(width: 360, height: 500)

    var body: some View {
        @Bindable var query = model.quickAccess
        VStack(spacing: 0) {
            header
            SearchField(text: $query.searchText, prompt: "Search clipboard history…", isFocused: $isSearchFocused, height: 32)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.return) {
                    copyHighlighted()
                    return .handled
                }
            Hairline(axis: .horizontal)
            content(query)
            Hairline(axis: .horizontal)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.panel)
        .toastOverlay(model.toast)
        .task(id: QuickKey(search: query.searchText, revision: model.revision)) {
            if !query.searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            await model.reload(query)
            if highlighted == nil || !query.entries.contains(where: { $0.id == highlighted }) {
                highlighted = query.entries.first?.id
            }
        }
        .task(id: model.revision) {
            await model.reloadCounts()
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: model.searchFocusRequest) {
            isSearchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("ClipDesk")
                    .font(.system(size: 14, weight: .bold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isCapturing ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(model.isCapturing ? "Capturing · \(Formatters.number(model.counts[.all])) items" : "Capture paused")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            IconButton(
                systemImage: model.isCapturing ? "pause.circle" : "play.circle",
                help: model.isCapturing ? "Pause Capture" : "Resume Capture",
                isActive: !model.isCapturing
            ) {
                model.setCaptureEnabled(!model.isCapturing)
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HeaderIconButtonStyle())
            .help("Settings")
            .simultaneousGesture(TapGesture().onEnded { dismiss() })
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func content(_ query: HistoryQuery) -> some View {
        if let error = model.startupError {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "History Unavailable", message: error)
        } else if query.hasLoaded && query.entries.isEmpty {
            if query.searchText.isEmpty {
                EmptyStateView(
                    systemImage: model.isCapturing ? "list.clipboard" : "pause.circle",
                    title: model.isCapturing ? "Nothing Copied Yet" : "Capture Is Paused",
                    message: model.isCapturing ? "Copy something and it will appear here." : "Resume capture to record what you copy."
                )
            } else {
                EmptyStateView(systemImage: "magnifyingglass", title: "No Results", message: "No items match “\(query.searchText)”.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(query.entries) { entry in
                            QuickAccessRow(
                                entry: entry,
                                isHighlighted: highlighted == entry.id,
                                onCopy: { copy(entry) }
                            )
                            .id(entry.id)
                            .onHover { hovering in
                                if hovering { highlighted = entry.id }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.showHistoryWindow(selecting: highlighted)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                    Text("Open Full History")
                    Text("⌘O")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(FooterButtonStyle())
            .keyboardShortcut("o", modifiers: .command)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
            }
            .buttonStyle(FooterButtonStyle())
            .help("Quit ClipDesk")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.canvas)
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        let entries = model.quickAccess.entries
        guard !entries.isEmpty else { return .ignored }
        let current = entries.firstIndex { $0.id == highlighted } ?? (offset > 0 ? -1 : entries.count)
        let next = min(max(current + offset, 0), entries.count - 1)
        highlighted = entries[next].id
        return .handled
    }

    private func copyHighlighted() {
        guard let entry = model.quickAccess.entries.first(where: { $0.id == highlighted }) else { return }
        copy(entry)
    }

    private func copy(_ entry: ClipEntry) {
        Task {
            if await model.copy(entry) {
                dismiss()
            }
        }
    }
}

private struct QuickKey: Equatable {
    var search: String
    var revision: Int
}

private struct QuickAccessRow: View {
    let entry: ClipEntry
    let isHighlighted: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            EntryIconTile(entry: entry, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(entry.kindLabel) · \(Formatters.rowTimestamp(entry.lastUsedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.favorite)
                    .accessibilityLabel("Favorite")
            }
            IconButton(systemImage: "doc.on.doc", help: "Copy", size: 26, action: onCopy)
                .opacity(isHighlighted ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Theme.accent.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .contextMenu {
            EntryContextMenu(entry: entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kindLabel): \(entry.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy", onCopy)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.hover.opacity(1.6) : (isHovered ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
