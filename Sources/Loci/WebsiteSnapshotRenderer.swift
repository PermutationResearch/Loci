import AppKit
import WebKit

@MainActor
final class WebsiteSnapshotRenderer: NSObject, WKNavigationDelegate {
    private static var activeRenderers: [UUID: WebsiteSnapshotRenderer] = [:]

    private let id: UUID
    private let url: URL
    private let size: CGSize
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var hasFinished = false

    static func snapshotPNGData(for url: URL, size: CGSize = CGSize(width: 1280, height: 920)) async -> Data? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let renderer = WebsiteSnapshotRenderer(id: id, url: url, size: size, continuation: continuation)
                activeRenderers[id] = renderer
                renderer.start()
            }
        } onCancel: {
            Task { @MainActor in
                activeRenderers[id]?.finish(with: nil)
            }
        }
    }

    private init(id: UUID, url: URL, size: CGSize, continuation: CheckedContinuation<Data?, Never>) {
        self.id = id
        self.url = url
        self.size = size
        self.continuation = continuation
        super.init()
    }

    private func start() {
        let configuration = LociWebSession.configuration(suppressesIncrementalRendering: true)

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.customUserAgent = LociWebSession.userAgent
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        webView.load(LociWebSession.request(for: url, timeoutInterval: 8))

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            self?.finish(with: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.capture()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    private func capture() {
        guard let webView else {
            finish(with: nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.snapshotWidth = NSNumber(value: Double(size.width))

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let image, image.isUsefulWebsiteSnapshot else {
                    self?.finish(with: nil)
                    return
                }
                self?.finish(with: image.pngData(maxSize: CGSize(width: 900, height: 650)))
            }
        }
    }

    private func finish(with data: Data?) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(returning: data)
        continuation = nil
        Self.activeRenderers[id] = nil
    }
}

private extension NSImage {
    var isUsefulWebsiteSnapshot: Bool {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let width = min(96, cgImage.width)
        let height = min(72, cgImage.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var nonWhite = 0
        var dark = 0
        var saturated = 0
        var transitions = 0
        var lastBrightness: Int?

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            let brightness = (red + green + blue) / 3
            let chroma = max(red, green, blue) - min(red, green, blue)

            if brightness < 242 { nonWhite += 1 }
            if brightness < 92 { dark += 1 }
            if chroma > 42 { saturated += 1 }
            if let lastBrightness, abs(brightness - lastBrightness) > 18 {
                transitions += 1
            }
            lastBrightness = brightness
        }

        let total = max(1, width * height)
        let nonWhiteRatio = Double(nonWhite) / Double(total)
        let darkRatio = Double(dark) / Double(total)
        let saturatedRatio = Double(saturated) / Double(total)
        let transitionRatio = Double(transitions) / Double(total)

        // Reject blank pages, raw unstyled documents, and tiny text-only renders.
        return nonWhiteRatio > 0.18
            && (darkRatio > 0.05 || saturatedRatio > 0.04 || transitionRatio > 0.12)
    }

    func pngData(maxSize: CGSize) -> Data? {
        let fittedSize = size.aspectFitting(NSSize(width: maxSize.width, height: maxSize.height))
        guard let resized = resized(to: fittedSize),
              let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
