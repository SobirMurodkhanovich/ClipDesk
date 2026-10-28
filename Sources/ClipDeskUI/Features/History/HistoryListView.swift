import ClipDeskCore
import SwiftUI

/// The center column: history entries for the selected category and search, grouped by day.
struct HistoryListView: View {
    @Environment(AppModel.self) private var model
    var isListFocused: FocusState<Bool>.Binding

    var body: some View {
        let query = model.history
        VStack(spacing: 0) {
            if !model.settings.hasDismissedWelcome && model.startupError == nil {
                WelcomeBanner()
            }
            content(query)
        }
        .background(Theme.panel)
        .task(id: QueryKey(category: query.category, search: query.searchText, revision: model.revision)) {
            if !query.searchText.isEmpty {
                // Debounce typing; the task is cancelled when the key changes again.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            await model.reload(query)
        }
    }

    @ViewBuilder
    private func content(_ query: HistoryQuery) -> some View {
        if let error = model.startupError {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "History Unavailable", message: error)
        } else if !query.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.entries.isEmpty {
            emptyState(query)
        } else {
            EntryList(query: query, isFocused: isListFocused)
        }
    }

    @ViewBuilder
    private func emptyState(_ query: HistoryQuery) -> some View {
        if !query.searchText.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No Results",
                message: "Nothing in \(query.category.title.lowercased()) matches “\(query.searchText)”.",
                actionTitle: "Clear Search",
                action: { query.searchText = "" }
            )
        } else if !model.isCapturing && query.category == .all {
            EmptyStateView(
                systemImage: "pause.circle",
                title: "Capture Is Paused",
                message: "ClipDesk isn’t recording what you copy. Resume to start building your history.",
                actionTitle: "Resume Capture",
                action: { model.setCaptureEnabled(true) }
            )
        } else {
            EmptyStateView(
                systemImage: query.category == .all ? "list.clipboard" : query.category.systemImage,
                title: query.category == .all ? "No Clipboard History Yet" : "No \(query.category.title)",
                message: query.category.emptyMessage
            )
        }
    }
}

private struct QueryKey: Equatable {
    var category: HistoryCategory
    var search: String
    var revision: Int
}

private struct EntryList: View {
    @Environment(AppModel.self) private var model
    @Bindable var query: HistoryQuery
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $query.selection) {
                if model.settings.groupByDate {
                    ForEach(HistorySection.group(query.entries)) { section in
                        Section {
                            rows(section.entries)
                        } header: {
                            // Headers stay pinned while scrolling, so they need an opaque background.
                            Text(section.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .background(Theme.panel)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                } else {
                    rows(query.entries)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused(isFocused)
            .environment(\.defaultMinListRowHeight, 50)
            .contextMenu(forSelectionType: ClipEntry.ID.self) { ids in
                if let id = ids.first, let entry = query.entries.first(where: { $0.id == id }) {
                    EntryContextMenu(entry: entry)
                }
            } primaryAction: { ids in
                copy(ids.first)
            }
            .onKeyPress(.return) {
                copy(query.selection)
                return .handled
            }
            .onDeleteCommand {
                if let selection = query.selection {
                    Task { await model.delete([selection]) }
                }
            }
            .onChange(of: query.scrollTarget, initial: true) { _, target in
                // Keyboard navigation scrolls natively; this handles selections made in code.
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                query.scrollTarget = nil
            }
            .accessibilityLabel("Clipboard history")
        }
    }

    private func rows(_ entries: [ClipEntry]) -> some View {
        ForEach(entries) { entry in
            HistoryRow(entry: entry)
                .tag(entry.id)
                .id(entry.id)
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Theme.stroke)
        }
    }

    private func copy(_ id: ClipEntry.ID?) {
        guard let id, let entry = query.entries.first(where: { $0.id == id }) else { return }
        Task { await model.copy(entry) }
    }
}

struct HistorySection: Identifiable {
    let id: Date
    let title: String
    let entries: [ClipEntry]

    /// Groups consecutive entries by the calendar day of their last activity.
    static func group(_ entries: [ClipEntry], now: Date = Date()) -> [HistorySection] {
        let calendar = Calendar.current
        var sections: [HistorySection] = []
        var currentDay: Date?
        var bucket: [ClipEntry] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.lastUsedAt)
            if day != currentDay, let currentDay, !bucket.isEmpty {
                sections.append(HistorySection(id: currentDay, title: Formatters.sectionTitle(for: currentDay, now: now), entries: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(entry)
        }
        if let currentDay, !bucket.isEmpty {
            sections.append(HistorySection(id: currentDay, title: Formatters.sectionTitle(for: currentDay, now: now), entries: bucket))
        }
        return sections
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: ClipEntry

    var body: some View {
        HStack(spacing: 12) {
            EntryIconTile(entry: entry, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text("\(entry.kindLabel) · \(Formatters.rowTimestamp(entry.lastUsedAt))")
                    if entry.hasUnavailableFiles {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Some files are no longer available")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            FavoriteButton(entry: entry)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kindLabel): \(entry.title)")
        .accessibilityValue(entry.isFavorite ? "Favorite" : "")
    }
}

struct FavoriteButton: View {
    @Environment(AppModel.self) private var model
    let entry: ClipEntry

    var body: some View {
        Button {
            Task { await model.toggleFavorite(entry) }
        } label: {
            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                .font(.system(size: 14))
                .foregroundStyle(entry.isFavorite ? AnyShapeStyle(Theme.favorite) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// Explains, on first use, that monitoring is active and data stays local.
private struct WelcomeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("ClipDesk is recording what you copy")
                    .font(.system(size: 12, weight: .semibold))
                Text("History is stored only on this Mac and never uploaded. Content marked private by apps such as password managers is skipped. Pause capture anytime.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Got It") {
                withAnimation { model.settings.hasDismissedWelcome = true }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}
