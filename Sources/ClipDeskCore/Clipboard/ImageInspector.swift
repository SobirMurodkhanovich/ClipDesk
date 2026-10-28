import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers. Reads image headers and produces downsampled images without decoding
/// full-resolution bitmaps.
public enum ImageInspector {
    public struct Info: Sendable, Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var typeIdentifier: String?
        /// The image carries macOS screenshot metadata (EXIF user comment "Screenshot").
        public var hasScreenshotMetadata: Bool
    }

    public static func inspect(data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return inspect(source: source)
    }

    public static func inspect(url: URL) -> Info? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return inspect(source: source)
    }

    private static func inspect(source: CGImageSource) -> Info? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let comment = exif?[kCGImagePropertyExifUserComment] as? String
        return Info(
            pixelWidth: width,
            pixelHeight: height,
            typeIdentifier: CGImageSourceGetType(source) as String?,
            hasScreenshotMetadata: comment?.localizedCaseInsensitiveContains("screenshot") ?? false
        )
    }

    /// Creates a downsampled image whose longest side is at most `maxPixelSize`.
    public static func downsampledImage(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    public static func downsampledImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsample(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
