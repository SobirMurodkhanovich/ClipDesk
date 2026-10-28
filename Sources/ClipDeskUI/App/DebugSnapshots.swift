#if DEBUG
import AppKit
import ClipDeskCore
import SwiftUI

/// Development aid, compiled into debug builds only.
///
/// When `CLIPDESK_DEBUG_SNAPSHOT_DIR` is set, ClipDesk walks through representative UI states
/// (each item type, light and dark appearance, compact width, the Menu Bar popover and Settings)
/// and renders its own windows to PNG files with `NSView.cacheDisplay`. This allows visual review
/// in environments where screen recording is not permitted. It never runs in release builds.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["CLIPDESK_DEBUG_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { await run(model: model, directory: directory) }
    }

    private static func run(model: AppModel, directory: URL) async {
        var log: [String] = []
        func capture(_ window: NSWindow?, _ name: String) {
            guard let window else {
                log.append("missing window for \(name)")
                return
            }
            log.append(write(window, to: directory.appendingPathComponent("\(name).png")) ? "captured \(name)" : "failed \(name)")
        }

        // Record whether outside input reaches the app during the run (event types only, no content).
        let inputLog = InputLog()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            inputLog.record(event)
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        await pause(2.5)
        model.showHistoryWindow()
        await pause(1.5)
        let window = historyWindow()
        window?.setContentSize(NSSize(width: 1_040, height: 660))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        await pause(0.5)
        log.append("history window key: \(window?.isKeyWindow == true), app active: \(NSApp.isActive), first responder: \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")

        let selections: [(String, (ClipEntry) -> Bool)] = [
            ("text", { $0.kind == .text }),
            ("code", { $0.kind == .code }),
            ("link", { $0.kind == .link }),
            ("image", { $0.kind == .image && !$0.isScreenshot }),
            ("screenshot", { $0.kind == .image && $0.isScreenshot }),
            ("file", { $0.kind == .file && $0.files.count == 1 && $0.files.first?.fileExtension == "pdf" }),
            ("files", { $0.kind == .file && $0.files.count > 1 }),
        ]
        for appearance in [AppearancePreference.light, .dark] {
            model.settings.appearance = appearance
            await pause(1)
            for (name, matches) in selections {
                guard let entry = model.history.entries.first(where: matches) else {
                    log.append("no entry for \(name) (category \(model.history.category.rawValue), \(model.history.entries.count) entries)")
                    continue
                }
                model.history.selection = entry.id
                model.history.scrollTarget = entry.id
                await pause(1.2)
                log.append("category before \(name): \(model.history.category.rawValue)")
                capture(window, "main-\(appearance.rawValue)-\(name)")
            }
        }

        model.settings.appearance = .light
        model.history.selection = model.history.entries.first?.id
        window?.setContentSize(NSSize(width: 800, height: 540))
        await pause(1.2)
        capture(window, "main-light-compact")
        window?.setContentSize(NSSize(width: 1_040, height: 660))

        model.history.category = .files
        await pause(1.2)
        capture(window, "main-light-category-files")
        model.history.category = .all
        model.history.searchText = "swiftui"
        await pause(1.2)
        capture(window, "main-light-search")
        model.history.searchText = "no-such-content"
        await pause(1.2)
        capture(window, "main-light-no-results")
        model.history.searchText = ""
        await pause(0.8)

        for appearance in [AppearancePreference.light, .dark] {
            model.settings.appearance = appearance
            await pause(0.8)
            if let button = statusItemButton() {
                button.performClick(nil)
                await pause(1.5)
                let popover = popoverWindow(excluding: window)
                if let popover {
                    log.append("popover window: \(popover.className), appearance \(popover.effectiveAppearance.name.rawValue), visual effect views: \(countVisualEffectViews(in: popover.contentView?.superview))")
                }
                capture(popover, "popover-\(appearance.rawValue)")
                button.performClick(nil)
                await pause(0.8)
            } else {
                log.append("status item button not found")
            }

            // The same popover content hosted in a plain, non-vibrant window, for comparison.
            let host = NSWindow(contentRect: NSRect(origin: .zero, size: MenuBarPopover.size), styleMask: [.borderless], backing: .buffered, defer: false)
            host.contentView = NSHostingView(rootView: MenuBarPopover().environment(model))
            host.orderFront(nil)
            await pause(1.2)
            capture(host, "popover-content-\(appearance.rawValue)")
            host.orderOut(nil)
        }

        model.settings.appearance = .light
        model.openSettingsAction?()
        NSApp.activate()
        await pause(1.5)
        let settingsWindow = NSApp.windows.first { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        capture(settingsWindow, "settings-general")
        settingsWindow?.close()
        await pause(0.5)

        // App-level behavior checks against the private test pasteboard.
        await verifyCopyBack(model: model, log: &log)
        await verifyPause(model: model, log: &log)

        log.append("outside input events during run: \(inputLog.summary)")
        log.append("done")
        try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }

    /// Copying an entry back must restore it, move it to the top and not create a duplicate.
    private static func verifyCopyBack(model: AppModel, log: inout [String]) async {
        model.history.category = .all
        await pause(0.8)
        let before = model.counts[.all]
        guard let entry = model.history.entries.first(where: { $0.title.hasPrefix("Meeting notes") }) else {
            log.append("copy-back: FAIL (no meeting notes entry)")
            return
        }
        let copied = await model.copy(entry)
        await pause(2)
        let restored = model.pasteboard.string(forType: .string) ?? ""
        let top = model.history.entries.first
        let ok = copied && model.counts[.all] == before && top?.id == entry.id && restored.hasPrefix("Meeting notes")
            && top?.useCount == entry.useCount + 1
        log.append("copy-back: \(ok ? "PASS" : "FAIL") (count \(before) -> \(model.counts[.all]), top=\(top?.title.prefix(20) ?? "-"), uses \(entry.useCount) -> \(top?.useCount ?? -1))")
    }

    /// Content copied while paused must not be recorded; content copied after resuming must be.
    private static func verifyPause(model: AppModel, log: inout [String]) async {
        func externalCopy(_ text: String) {
            model.pasteboard.clearContents()
            model.pasteboard.setString(text, forType: .string)
        }
        let before = model.counts[.all]
        model.setCaptureEnabled(false)
        await pause(0.8)
        externalCopy("copied while paused \(UUID().uuidString)")
        await pause(1.5)
        let whilePaused = model.counts[.all]
        model.setCaptureEnabled(true)
        await pause(0.8)
        externalCopy("copied after resume \(UUID().uuidString)")
        await pause(1.5)
        let afterResume = model.counts[.all]
        let ok = whilePaused == before && afterResume == before + 1
        log.append("pause/resume: \(ok ? "PASS" : "FAIL") (count \(before) -> paused \(whilePaused) -> resumed \(afterResume))")
    }

    private static func countVisualEffectViews(in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is NSVisualEffectView ? 1 : 0) + view.subviews.reduce(0) { $0 + countVisualEffectViews(in: $1) }
    }

    @MainActor
    private final class InputLog {
        private var events: [String] = []

        func record(_ event: NSEvent) {
            let command = event.modifierFlags.contains(.command) ? "+cmd" : ""
            events.append("\(event.type == .keyDown ? "key" : "click")\(command)")
        }

        var summary: String { events.isEmpty ? "none" : events.joined(separator: ", ") }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func historyWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == "ClipDesk" && !($0 is NSPanel) }
    }

    private static func popoverWindow(excluding main: NSWindow?) -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window !== main && window.className != "NSStatusBarWindow"
                && window.frame.width > 200 && window.frame.height > 200
        }
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBar") {
            if let button = findButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }

    /// Renders the window's frame view (including the title bar area) into a PNG.
    private static func write(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
