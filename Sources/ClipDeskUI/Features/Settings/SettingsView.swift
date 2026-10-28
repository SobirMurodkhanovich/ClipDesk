import AppKit
import ClipDeskCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Capture clipboard history", isOn: $settings.isCaptureEnabled)
                Picker("Check clipboard every", selection: $settings.pollingInterval) {
                    ForEach(AppSettings.pollingOptions, id: \.self) { interval in
                        Text(interval < 1 ? "\(Int(interval * 1_000)) ms" : "\(Int(interval)) s").tag(interval)
                    }
                }
                .disabled(!settings.isCaptureEnabled)
            } footer: {
                Text("While capture is on, ClipDesk checks whether the clipboard changed and saves new content. Content copied while paused is never recorded.")
                    .settingsFootnote()
            }

            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Open ClipDesk at login", isOn: Binding(
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: { setLoginItem($0) }
                ))
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Approve ClipDesk in System Settings to finish turning this on.")
                            .settingsFootnote()
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .settingsFootnote()
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn’t change the login item: \(error.localizedDescription) Make sure ClipDesk is in your Applications folder."
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}

private struct StorageSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isDeleteAllPresented = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Keep up to", selection: $settings.maxHistoryEntries) {
                    ForEach(AppSettings.historySizeOptions, id: \.self) { count in
                        Text("\(Formatters.number(count)) items").tag(count)
                    }
                }
                Picker("Remove items after", selection: $settings.retentionDays) {
                    ForEach(AppSettings.retentionOptions, id: \.self) { days in
                        Text(retentionTitle(days)).tag(days)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Older items are removed automatically, with their stored copies. Favorites are never removed automatically.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Keep copies of copied files", isOn: $settings.storeFileCopies)
                Picker("Maximum size per item", selection: $settings.maxItemSizeMB) {
                    ForEach(AppSettings.itemSizeOptions, id: \.self) { megabytes in
                        Text("\(megabytes) MB").tag(megabytes)
                    }
                }
            } header: {
                Text("Files and Large Items")
            } footer: {
                Text("With copies on, a copied file stays available even if the original is moved or deleted. Files larger than the limit are kept as references, and larger images or data are not saved. Reading files in Desktop, Documents or Downloads may prompt for permission.")
                    .settingsFootnote()
            }

            Section {
                LabeledContent("Stored") {
                    if let usage = model.storageUsage {
                        Text("\(Formatters.number(usage.entryCount)) items · \(Formatters.bytes(usage.payloadBytes + usage.databaseBytes))")
                    } else {
                        Text("—")
                    }
                }
                if let directory = model.dataDirectory {
                    LabeledContent("Location") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([directory])
                        }
                    }
                }
                HStack {
                    Button("Clear History…") {
                        model.isClearConfirmationPresented = true
                    }
                    Spacer()
                    Button("Delete All Data…", role: .destructive) {
                        isDeleteAllPresented = true
                    }
                }
            } header: {
                Text("Data")
            }
        }
        .formStyle(.grouped)
        .task(id: model.revision) {
            await model.reloadStorageUsage()
        }
        .clearHistoryConfirmation()
        .alert("Delete all ClipDesk data?", isPresented: $isDeleteAllPresented) {
            Button("Delete All Data", role: .destructive) {
                Task { await model.clearHistory(includingFavorites: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every item, including favorites, along with all stored copies, files and thumbnails.")
        }
    }

    private func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: "Never"
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
}

private struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Skip content marked private or temporary", isOn: $settings.ignorePrivacyMarkedContent)
            } footer: {
                Text("Password managers and other apps can mark clipboard content as concealed or transient. ClipDesk does not save such content when this is on.")
                    .settingsFootnote()
            }

            Section("How ClipDesk handles your data") {
                PrivacyPoint(systemImage: "internaldrive", text: "History, images and file copies are stored only on this Mac, in your user Library.")
                PrivacyPoint(systemImage: "network.slash", text: "ClipDesk makes no network connections. Nothing is uploaded, and there is no analytics or telemetry.")
                PrivacyPoint(systemImage: "pause.circle", text: "You can pause capture at any time from the menu bar, the history window or here.")
                PrivacyPoint(systemImage: "trash", text: "Deleting items removes their stored data. Like any app on modern SSDs, ClipDesk can’t guarantee forensic erasure.")
                PrivacyPoint(systemImage: "lock.open", text: "ClipDesk is not an encrypted vault. Anyone with access to your user account can read its history.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyPoint: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            BrandMark(size: 64)
            Text("ClipDesk")
                .font(.system(size: 20, weight: .bold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("A local-first clipboard and screenshot manager for macOS.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
