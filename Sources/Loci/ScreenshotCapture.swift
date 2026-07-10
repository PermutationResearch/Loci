@preconcurrency import ScreenCaptureKit
import AppKit
import Vision

@MainActor
enum ScreenshotCapture {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case captureFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Screen recording permission is required for screenshot capture."
            case .captureFailed: "Failed to capture screenshot."
            case .saveFailed: "Failed to save screenshot."
            }
        }
    }

    static func requestPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return await withCheckedContinuation { continuation in
            CGRequestScreenCaptureAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: CGPreflightScreenCaptureAccess())
            }
        }
    }

    static func captureScreen() async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.captureFailed
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.captureResolution = .best

        let cgImage = try await captureImage(filter: filter, config: config)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return try saveScreenshot(nsImage)
    }

    static func captureRegion(_ rect: CGRect) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.captureFailed
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.captureResolution = .best

        let fullImage = try await captureImage(filter: filter, config: config)

        guard let cropped = fullImage.cropping(to: rect) else {
            throw CaptureError.captureFailed
        }

        let nsImage = NSImage(cgImage: cropped, size: rect.size)
        return try saveScreenshot(nsImage)
    }

    static func captureWindow(_ windowID: CGWindowID) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              let display = content.displays.first(where: { display in
                  display.frame.contains(window.frame.origin)
              }) else {
            throw CaptureError.captureFailed
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [window])
        let config = SCStreamConfiguration()

        let cgImage = try await captureImage(filter: filter, config: config)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return try saveScreenshot(nsImage)
    }

    private static func captureImage(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CaptureError.captureFailed)
                }
            }
        }
    }

    private static func saveScreenshot(_ image: NSImage) throws -> URL {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.saveFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "screenshot_\(UUID().uuidString.lowercased()).png"
        let fileURL = tempDir.appendingPathComponent(fileName)

        try pngData.write(to: fileURL, options: .atomic)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CaptureError.saveFailed
        }
        return fileURL
    }
}
