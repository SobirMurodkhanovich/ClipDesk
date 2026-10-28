import ClipDeskCore
import SwiftUI

/// Category list with live counts, capture status, Settings and Clear History.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(HistoryCategory.allCases.enumerated()), id: \.element) { index, category in
                Button {
                    model.history.category = category
                } label: {
                    SidebarRowLabel(
                        title: category.title,
                        systemImage: category.systemImage,
                        count: model.counts[category],
                        isCompact: isCompact
                    )
                }
                .buttonStyle(SidebarButtonStyle(isSelected: model.history.category == category))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help(isCompact ? "\(category.title) (\(model.counts[category]))" : "")
                .accessibilityAddTraits(model.history.category == category ? .isSelected : [])
            }

            Spacer(minLength: 16)

            CaptureStatusView(isCompact: isCompact)
                .padding(.bottom, 6)

            SettingsLink {
                SidebarRowLabel(title: "Settings", systemImage: "gearshape", isCompact: isCompact)
            }
            .buttonStyle(SidebarButtonStyle(isSelected: false))
            .help(isCompact ? "Settings" : "")

            Button {
                model.isClearConfirmationPresented = true
            } label: {
                SidebarRowLabel(title: "Clear History", systemImage: "trash", isCompact: isCompact)
            }
            .buttonStyle(SidebarButtonStyle(isSelected: false))
            .disabled(model.counts[.all] == model.counts[.favorites])
            .help(isCompact ? "Clear History" : "")
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    var count: Int?
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 20)
            if !isCompact {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(Formatters.number(count))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Theme.accent : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.12) : (configuration.isPressed ? Theme.hover.opacity(1.6) : (isHovered ? Theme.hover : .clear)))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// Makes clipboard monitoring visible and lets the user pause it.
private struct CaptureStatusView: View {
    @Environment(AppModel.self) private var model
    let isCompact: Bool

    var body: some View {
        let capturing = model.isCapturing
        let binding = Binding(get: { model.isCapturing }, set: { model.setCaptureEnabled($0) })
        Group {
            if isCompact {
                Button {
                    model.setCaptureEnabled(!capturing)
                } label: {
                    Image(systemName: capturing ? "record.circle" : "pause.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(capturing ? .green : .orange)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .help(capturing ? "Capturing — click to pause" : "Capture paused — click to resume")
            } else {
                HStack(spacing: 9) {
                    Circle()
                        .fill(capturing ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capturing ? "Capturing" : "Capture Paused")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Saved locally")
                            .lineLimit(1)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Toggle("Capture Clipboard", isOn: binding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(capturing ? "Clipboard capture is on" : "Clipboard capture is paused")
    }
}
