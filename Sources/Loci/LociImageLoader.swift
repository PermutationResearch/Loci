import AppKit
import ImageIO

enum LociImageLoader {
    static func downsampledImage(from url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                downsampledImageSync(from: url, maxPixelSize: maxPixelSize)
            }
        }.value
    }

    static func downsampledCGImage(from url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                downsampledCGImageSync(from: url, maxPixelSize: maxPixelSize)
            }
        }.value
    }

    static func downsampledImage(from data: Data, maxPixelSize: Int) -> NSImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            guard let cgImage = cgImage(from: source, maxPixelSize: maxPixelSize) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    static func pngData(from data: Data, maxPixelSize: Int) -> Data? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  let cgImage = cgImage(from: source, maxPixelSize: maxPixelSize) else {
                return nil
            }
            return pngData(from: cgImage)
        }
    }

    static func pngData(from url: URL, maxPixelSize: Int) async -> Data? {
        await Task.detached(priority: .utility) {
            pngDataSync(from: url, maxPixelSize: maxPixelSize)
        }.value
    }

    static func pngDataSync(from url: URL, maxPixelSize: Int) -> Data? {
        autoreleasepool {
            guard let cgImage = downsampledCGImageSync(from: url, maxPixelSize: maxPixelSize) else {
                return nil
            }
            return pngData(from: cgImage)
        }
    }

    static func imageAspectRatio(from url: URL) -> CGFloat? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                  pixelWidth > 0,
                  pixelHeight > 0 else {
                return nil
            }

            let orientation = properties[kCGImagePropertyOrientation] as? Int
            if orientation == 5 || orientation == 6 || orientation == 7 || orientation == 8 {
                return pixelHeight / pixelWidth
            }
            return pixelWidth / pixelHeight
        }
    }

    private static func downsampledImageSync(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cgImage = downsampledCGImageSync(from: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func downsampledCGImageSync(from url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return cgImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func cgImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}
