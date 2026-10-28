import AppKit
import ClipDeskCore
import SwiftUI

/// ClipDesk's "Native Minimal" palette. Light surfaces are white and light gray; dark surfaces
/// are graphite. Every color adapts to the effective appearance.
enum Theme {
    static let accent = Color(nsColor: .systemBlue)
    static let canvas = dynamic(light: 0xF4F5F7, dark: 0x1D1E21)
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x252629)
    static let well = dynamic(light: 0xF4F5F8, dark: 0x1B1C1F)
    static let tile = dynamic(light: 0xEEF1F5, dark: 0x34363B)
    /// Fixed (non-hierarchical) glyph color so tile icons stay visible inside a selected list row.
    static let tileGlyph = dynamic(light: 0x7C8696, dark: 0xA3A9B4)
    /// Solid tint for code and link tiles; translucent tints vanish on a blue selection.
    static let accentTile = dynamic(light: 0xE5EFFF, dark: 0x233652)
    static let stroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.08)
    })
    static let hover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    })
    static let favorite = Color(nsColor: .systemYellow)

    static let cornerRadius: CGFloat = 10

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension HistoryCategory {
    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "textformat"
        case .images: "photo"
        case .screenshots: "camera"
        case .files: "doc"
        case .favorites: "star"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Copy text, images, or files and they’ll appear here."
        case .text: "Copied text, links, and code will appear here."
        case .images: "Copied images will appear here."
        case .screenshots: "Screenshots copied to the clipboard will appear here."
        case .files: "Files copied in Finder will appear here."
        case .favorites: "Star an item to keep it here. Favorites are never removed automatically."
        }
    }
}

extension ContentKind {
    var systemImage: String {
        switch self {
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .other: "shippingbox"
        }
    }
}

/// Formatting helpers shared by list rows and previews.
enum Formatters {
    static func rowTimestamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let day = date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }

    static func detailTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }

    static func sectionTitle(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.wide).day() : .dateTime.month(.wide).day().year())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number)
    }
}
