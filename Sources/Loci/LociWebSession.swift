import Foundation
import WebKit

@MainActor
enum LociWebSession {
    static let processPool = WKProcessPool()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 Loci/1.0"

    static func configuration(suppressesIncrementalRendering: Bool = false) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = .default()
        configuration.suppressesIncrementalRendering = suppressesIncrementalRendering
        return configuration
    }

    static func request(for url: URL, timeoutInterval: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
