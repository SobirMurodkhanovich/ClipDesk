import AppKit
import Foundation
import os

/// Watches a pasteboard for changes by polling `changeCount` on a background queue.
///
/// Polling `changeCount` is a cheap call; contents are read only when the count changes.
/// macOS provides no change notification for the general pasteboard, so polling at a
/// modest, configurable interval is the standard approach.
public final class ClipboardMonitor: @unchecked Sendable {
    public typealias CaptureHandler = @Sendable (PasteboardSnapshot) -> Void

    private static let logger = Logger(subsystem: "io.github.sobirmurodkhanovich.ClipDesk", category: "ClipboardMonitor")

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(label: "ClipDesk.ClipboardMonitor", qos: .utility)
    private let pasteboard: NSPasteboard
    private let sourceAppProvider: @Sendable () -> SourceApplication?
    private let handler: CaptureHandler
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var ignoredChangeCounts: Set<Int> = []
    private var options: PasteboardReadOptions
    private var interval: TimeInterval

    public init(
        pasteboard: NSPasteboard = .general,
        options: PasteboardReadOptions = .default,
        interval: TimeInterval = 0.5,
        sourceAppProvider: @escaping @Sendable () -> SourceApplication? = { nil },
        handler: @escaping CaptureHandler
    ) {
        self.pasteboard = pasteboard
        self.options = options
        self.interval = interval
        self.sourceAppProvider = sourceAppProvider
        self.handler = handler
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
    }

    public var isRunning: Bool {
        queue.sync { timer != nil }
    }

    /// Starts monitoring. Content already on the pasteboard, or copied while paused, is not captured.
    public func start() {
        queue.sync {
            guard timer == nil else { return }
            lastChangeCount = pasteboard.changeCount
            scheduleTimer()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    public func update(options: PasteboardReadOptions) {
        queue.async { self.options = options }
    }

    public func update(interval: TimeInterval) {
        queue.sync {
            self.interval = interval
            if timer != nil {
                timer?.cancel()
                scheduleTimer()
            }
        }
    }

    /// Tells the monitor that a change was made by ClipDesk itself and must not be captured.
    public func ignoreChange(count: Int) {
        queue.sync { _ = ignoredChangeCounts.insert(count) }
    }

    /// Checks the pasteboard immediately. Returns the read result when the pasteboard changed.
    @discardableResult
    public func pollNow() -> PasteboardReadResult? {
        queue.sync { poll() }
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanoseconds = Int(max(0.1, interval) * 1_000_000_000)
        // A generous leeway lets macOS coalesce wakeups and save energy.
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    private func poll() -> PasteboardReadResult? {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return nil }
        lastChangeCount = changeCount
        if ignoredChangeCounts.remove(changeCount) != nil {
            return .skipped(.ownWrite)
        }
        ignoredChangeCounts = ignoredChangeCounts.filter { $0 > changeCount }

        let result = PasteboardReader.read(pasteboard, options: options, sourceApp: sourceAppProvider())
        switch result {
        case .captured(let snapshot):
            Self.logger.debug("Captured change \(changeCount, privacy: .public) with \(snapshot.items.count, privacy: .public) item(s)")
            handler(snapshot)
        case .skipped(let reason):
            Self.logger.debug("Skipped change \(changeCount, privacy: .public): \(String(describing: reason), privacy: .public)")
        }
        return result
    }
}

/// Tracks the frontmost application so captures can record a likely source app.
/// Updated on the main thread from workspace notifications; read from any thread.
public final class FrontmostApplicationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SourceApplication?
    private var observer: NSObjectProtocol?

    public init() {}

    @MainActor
    public func start() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(app)
        }
    }

    private func update(_ app: NSRunningApplication?) {
        let source = app.map { SourceApplication(name: $0.localizedName, bundleIdentifier: $0.bundleIdentifier) }
        lock.withLock { current = source }
    }

    public var frontmostApplication: SourceApplication? {
        lock.withLock { current }
    }
}
