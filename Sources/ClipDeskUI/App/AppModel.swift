import AppKit
import ClipDeskCore
import Observation
import os

/// A filtered, searchable view of history. The main window and the Menu Bar popover each own one.
@MainActor
@Observable
final class HistoryQuery {
    var category: HistoryCategory = .all
    var searchText = ""
    private(set) var entries: [ClipEntry] = []
    private(set) var hasLoaded = false
    var selection: ClipEntry.ID?
    /// Set when code (not the user) selects an entry that should be scrolled into view.
    var scrollTarget: ClipEntry.ID?
    let limit: Int?

    init(limit: Int? = nil) {
        self.limit = limit
    }

    var selectedEntry: ClipEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    fileprivate func update(_ entries: [ClipEntry]) {
        self.entries = entries
        hasLoaded = true
        if selection == nil || !entries.contains(where: { $0.id == selection }) {
            selection = entries.first?.id
        }
    }

    /// The entry that should be selected after `ids` are deleted: the next one, else the previous one.
    func selectionAfterRemoving(_ ids: Set<ClipEntry.ID>) -> ClipEntry.ID? {
        guard let selection, ids.contains(selection),
              let index = entries.firstIndex(where: { $0.id == selection }) else { return self.selection }
        let after = entries[index...].first { !ids.contains($0.id) }
        let before = entries[..<index].last { !ids.contains($0.id) }
        return (after ?? before)?.id
    }
}

struct ToastMessage: Identifiable, Equatable {
    enum Style {
        case success
        case warning
        case failure
    }

    let id = UUID()
    var text: String
    var style: Style

    var systemImage: String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

/// Application-level coordinator: owns the clipboard monitor and history store and exposes
/// the actions used by every window. Views never talk to the engine directly.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel(settings: AppSettings(defaults: AppModel.makeDefaults()))

    let settings: AppSettings
    private(set) var store: HistoryStore?
    private(set) var startupError: String?
    let history = HistoryQuery()
    let quickAccess = HistoryQuery(limit: 60)
    private(set) var counts = CategoryCounts.zero
    /// Incremented after every change to stored history; views reload when it changes.
    private(set) var revision = 0
    private(set) var storageUsage: StorageUsage?
    var toast: ToastMessage?
    /// Incremented to ask the visible search field to take keyboard focus.
    var searchFocusRequest = 0
    var isClearConfirmationPresented = false

    @ObservationIgnored private var monitor: ClipboardMonitor?
    @ObservationIgnored private let tracker = FrontmostApplicationTracker()
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored var openHistoryWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored let pasteboard: NSPasteboard
    private static let logger = Logger(subsystem: "io.github.sobirmurodkhanovich.ClipDesk", category: "AppModel")

    /// `CLIPDESK_DEFAULTS_SUITE` isolates preferences for development and automated UI runs.
    private static func makeDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["CLIPDESK_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }

    init(settings: AppSettings) {
        self.settings = settings
        // Development and automated testing can point ClipDesk at a private pasteboard
        // so the user's real clipboard is never touched.
        if let name = ProcessInfo.processInfo.environment["CLIPDESK_PASTEBOARD_NAME"], !name.isEmpty {
            pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        } else {
            pasteboard = .general
        }
        do {
            store = try HistoryStore(directory: StorageLocation.defaultDirectory())
        } catch {
            startupError = "ClipDesk could not open its history database. \(error.localizedDescription)"
            Self.logger.error("Failed to open history store: \(String(describing: error), privacy: .public)")
        }
    }

    /// Starts monitoring and maintenance. Called once the application has finished launching.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        applyAppearance()
        guard let store else { return }

        tracker.start()
        let tracker = tracker
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            options: settings.readOptions,
            interval: settings.pollingInterval,
            sourceAppProvider: { tracker.frontmostApplication },
            handler: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    await self?.ingest(snapshot)
                }
            }
        )
        self.monitor = monitor
        if settings.isCaptureEnabled {
            monitor.start()
        }
        observeSettings()

        if store.recoveredFromCorruption {
            showToast("The history database was damaged and has been reset. A backup was kept.", style: .warning)
        }
        Task { await performMaintenance() }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performMaintenance()
            }
        }
        #if DEBUG
        DebugSnapshots.runIfRequested(model: self)
        #endif
    }

    // MARK: Capture

    var isCapturing: Bool { settings.isCaptureEnabled }

    func setCaptureEnabled(_ enabled: Bool) {
        settings.isCaptureEnabled = enabled
    }

    private func ingest(_ snapshot: PasteboardSnapshot) async {
        guard let store, settings.isCaptureEnabled else { return }
        do {
            try await store.ingest(snapshot, policy: settings.capturePolicy)
            try await store.applyRetention(settings.retentionPolicy)
        } catch {
            Self.logger.error("Failed to store a capture: \(String(describing: error), privacy: .public)")
            showToast("ClipDesk couldn't save the copied item.", style: .failure)
        }
        historyDidChange()
    }

    private func performMaintenance() async {
        guard let store else { return }
        do {
            try await store.applyRetention(settings.retentionPolicy)
            await store.removeOrphanedPayloads()
        } catch {
            Self.logger.error("Maintenance failed: \(String(describing: error), privacy: .public)")
        }
        historyDidChange()
    }

    private func historyDidChange() {
        revision += 1
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.isCaptureEnabled
            _ = settings.pollingInterval
            _ = settings.readOptions
            _ = settings.retentionPolicy
            _ = settings.appearance
        } onChange: { [weak self] in
            // Fires before the new value is stored; apply on the next main-actor turn.
            Task { @MainActor [weak self] in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }

    private func applySettings() {
        applyAppearance()
        guard let monitor else { return }
        monitor.update(options: settings.readOptions)
        monitor.update(interval: settings.pollingInterval)
        if settings.isCaptureEnabled != monitor.isRunning {
            settings.isCaptureEnabled ? monitor.start() : monitor.stop()
        }
        Task { await performMaintenance() }
    }

    private func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Loading

    func reload(_ query: HistoryQuery) async {
        guard let store else { return }
        do {
            let entries = try await store.entries(in: query.category, matching: query.searchText, limit: query.limit)
            guard !Task.isCancelled else { return }
            query.update(entries)
        } catch {
            Self.logger.error("Failed to load history: \(String(describing: error), privacy: .public)")
        }
    }

    func reloadCounts() async {
        guard let store else { return }
        if let counts = try? await store.counts() {
            self.counts = counts
        }
    }

    func reloadStorageUsage() async {
        storageUsage = try? await store?.storageUsage()
    }

    func content(for entry: ClipEntry) async throws -> EntryContent {
        guard let store else { throw HistoryStoreError.entryNotFound }
        return try await store.content(for: entry.id)
    }

    // MARK: Actions

    /// Copies an entry back to the clipboard. The monitor ignores this write, and the entry moves
    /// to the top of history instead of being captured again as a duplicate.
    @discardableResult
    func copy(_ entry: ClipEntry, asPlainText: Bool = false) async -> Bool {
        guard let store else { return false }
        do {
            let payload = asPlainText
                ? try await store.plainTextPayload(for: entry.id)
                : try await store.restorePayload(for: entry.id)
            guard let changeCount = PasteboardWriter.write(payload, to: pasteboard) else {
                showToast("Couldn't write to the clipboard.", style: .failure)
                return false
            }
            monitor?.ignoreChange(count: changeCount)
            try await store.markUsed(entry.id)
            if payload.warnings.isEmpty {
                showToast(asPlainText ? "Copied as Plain Text" : "Copied to Clipboard", style: .success)
            } else {
                showToast(payload.warnings.joined(separator: " "), style: .warning)
            }
            historyDidChange()
            return true
        } catch {
            showToast(error.localizedDescription, style: .failure)
            historyDidChange()
            return false
        }
    }

    func toggleFavorite(_ entry: ClipEntry) async {
        await setFavorite(entry, !entry.isFavorite)
    }

    func setFavorite(_ entry: ClipEntry, _ isFavorite: Bool) async {
        do {
            try await store?.setFavorite(entry.id, isFavorite)
        } catch {
            showToast("Couldn't update favorites.", style: .failure)
        }
        historyDidChange()
    }

    func delete(_ ids: Set<ClipEntry.ID>) async {
        guard !ids.isEmpty else { return }
        history.selection = history.selectionAfterRemoving(ids)
        quickAccess.selection = quickAccess.selectionAfterRemoving(ids)
        do {
            try await store?.delete(Array(ids))
            showToast(ids.count == 1 ? "Deleted" : "Deleted \(ids.count) items", style: .success)
        } catch {
            showToast("Couldn't delete the item.", style: .failure)
        }
        historyDidChange()
    }

    /// Removes history and managed payloads. Favorites are kept unless `includingFavorites`.
    func clearHistory(includingFavorites: Bool) async {
        do {
            let removed = try await store?.clear(keepFavorites: !includingFavorites) ?? 0
            showToast(removed == 1 ? "Removed 1 item" : "Removed \(removed) items", style: .success)
        } catch {
            showToast("Couldn't clear history.", style: .failure)
        }
        historyDidChange()
    }

    func showHistoryWindow(selecting id: ClipEntry.ID? = nil) {
        if let id {
            history.category = .all
            history.searchText = ""
            history.selection = id
            history.scrollTarget = id
        }
        openHistoryWindowAction?()
        NSApp.activate()
    }

    // MARK: Feedback

    func showToast(_ text: String, style: ToastMessage.Style) {
        let message = ToastMessage(text: text, style: style)
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(style == .success ? 1.6 : 4))
            guard !Task.isCancelled, self?.toast?.id == message.id else { return }
            self?.toast = nil
        }
    }

    var dataDirectory: URL? { store?.directory }
}
