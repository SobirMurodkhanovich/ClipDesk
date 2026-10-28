import Foundation

/// Where ClipDesk keeps its data.
public enum StorageLocation {
    /// `~/Library/Application Support/ClipDesk`, or `CLIPDESK_DATA_DIR` when set (development and testing).
    public static func defaultDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CLIPDESK_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ClipDesk", isDirectory: true)
    }
}

/// Manages payload directories under the data root. Each capture gets its own directory
/// (`Payloads/<uuid>`) holding large representations, managed file copies and its thumbnail,
/// so deleting an entry removes exactly one directory.
struct PayloadStore: Sendable {
    let root: URL
    private static let payloadsFolder = "Payloads"

    var payloadsDirectory: URL {
        root.appendingPathComponent(Self.payloadsFolder, isDirectory: true)
    }

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: payloadsDirectory, withIntermediateDirectories: true)
    }

    /// Creates a new, empty capture directory and returns its path relative to the root.
    func makeCaptureDirectory() throws -> String {
        let relative = "\(Self.payloadsFolder)/\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: url(for: relative), withIntermediateDirectories: true)
        return relative
    }

    func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Returns a stored relative path for a file inside the data root, or nil for paths outside it.
    func relativePath(for url: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    func write(_ data: Data, named name: String, in directory: String) throws -> String {
        let relative = "\(directory)/\(name)"
        try data.write(to: url(for: relative), options: .atomic)
        return relative
    }

    /// Removes a capture directory. Refuses anything that is not a direct child of `Payloads/`,
    /// so a damaged database row can never cause deletion outside ClipDesk's own storage.
    func removeCaptureDirectory(_ relativePath: String) {
        guard isCaptureDirectoryPath(relativePath) else { return }
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }

    func isCaptureDirectoryPath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        return components.count == 2
            && components[0] == Self.payloadsFolder
            && UUID(uuidString: String(components[1])) != nil
    }

    /// Relative paths of every directory or file currently under `Payloads/`.
    func existingCaptureEntries() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: payloadsDirectory.path)) ?? []
        return names.map { "\(Self.payloadsFolder)/\($0)" }
    }

    /// Removes a stray item under `Payloads/` that is not a valid capture directory.
    func removeStrayPayload(_ relativePath: String) {
        let components = relativePath.split(separator: "/")
        guard components.count == 2, components[0] == Self.payloadsFolder else { return }
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }
}
