import AppKit
import ClipDeskCore
import SwiftUI

enum WindowID {
    static let history = "history"
}

/// ClipDesk's scenes: the full history window, the Menu Bar popover, and Settings.
public struct ClipDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        Window("ClipDesk", id: WindowID.history) {
            HistoryWindow()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_040, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            ClipDeskCommands(model: model)
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The status item icon. It also hands the `openWindow` action to the model so non-view code
/// (the Dock icon, the popover) can open the history window.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.isCapturing ? "list.clipboard" : "clipboard")
            .accessibilityLabel(model.isCapturing ? "ClipDesk" : "ClipDesk (capture paused)")
            .onAppear {
                model.openHistoryWindowAction = { openWindow(id: WindowID.history) }
                model.openSettingsAction = { openSettings() }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activationController: ActivationPolicyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activationController = ActivationPolicyController()
        AppModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.showHistoryWindow()
        }
        return true
    }
}

/// ClipDesk lives in the menu bar. It shows a Dock icon and app menu only while one of its
/// regular windows (history or Settings) is open.
@MainActor
final class ActivationPolicyController {
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let closingWindow = name == NSWindow.willCloseNotification ? notification.object as? NSWindow : nil
                MainActor.assumeIsolated {
                    self?.update(excludingWindowNumber: closingWindow?.windowNumber)
                }
            }
            observers.append(observer)
        }
        update(excludingWindowNumber: nil)
    }

    private func update(excludingWindowNumber excluded: Int?) {
        let hasAppWindow = NSApp.windows.contains { window in
            window.windowNumber != excluded && window.isVisible && Self.isRegularAppWindow(window)
        }
        let policy: NSApplication.ActivationPolicy = hasAppWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate()
        }
    }

    private static func isRegularAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.level == .normal
    }
}

struct ClipDeskCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .textEditing) {
            Button("Find in History") {
                model.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("History") {
            Button(model.isCapturing ? "Pause Capture" : "Resume Capture") {
                model.setCaptureEnabled(!model.isCapturing)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Copy to Clipboard") {
                if let entry = model.history.selectedEntry {
                    Task { await model.copy(entry) }
                }
            }
            .disabled(model.history.selectedEntry == nil)

            Button("Copy as Plain Text") {
                if let entry = model.history.selectedEntry {
                    Task { await model.copy(entry, asPlainText: true) }
                }
            }
            .disabled(model.history.selectedEntry?.kind.isTextual != true)

            Button(model.history.selectedEntry?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let entry = model.history.selectedEntry {
                    Task { await model.toggleFavorite(entry) }
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.history.selectedEntry == nil)

            Button("Delete") {
                if let entry = model.history.selectedEntry {
                    Task { await model.delete([entry.id]) }
                }
            }
            .disabled(model.history.selectedEntry == nil)

            Divider()

            Button("Clear History…") {
                model.isClearConfirmationPresented = true
            }
        }
    }
}
