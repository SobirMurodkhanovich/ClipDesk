import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipDeskCore

/// Isolated, temporary test fixtures. Tests never touch the user's clipboard or history.
enum TestSupport {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeItem(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func representation(_ type: String, _ string: String) -> PasteboardSnapshot.Representation {
        .init(type: type, data: Data(string.utf8))
    }

    static func textSnapshot(_ text: String, extra: [PasteboardSnapshot.Representation] = [], at date: Date = Date()) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: [.init(representations: [representation(PasteboardTypes.plainText, text)] + extra)],
            capturedAt: date
        )
    }

    static func imageSnapshot(_ png: Data, at date: Date = Date()) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [.init(representations: [.init(type: PasteboardTypes.png, data: png)])], capturedAt: date)
    }

    static func fileSnapshot(_ urls: [URL], at date: Date = Date()) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: urls.map { url in
                .init(representations: [
                    representation(PasteboardTypes.fileURL, url.absoluteString),
                    representation(PasteboardTypes.plainText, url.lastPathComponent),
                ])
            },
            capturedAt: date
        )
    }

    /// A PNG, optionally carrying the EXIF user comment macOS writes into screenshots.
    static func pngData(width: Int = 4, height: Int = 3, userComment: String? = nil) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let userComment {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: userComment]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @discardableResult
    static func writeFile(_ name: String, in directory: URL, bytes: Int = 64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Number of capture directories currently under `Payloads/`.
    static func payloadDirectoryCount(in root: URL) -> Int {
        let path = root.appendingPathComponent("Payloads").path
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).count
    }
}

/// Thread-safe collector for values delivered on background queues.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}
