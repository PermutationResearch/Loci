import Foundation
import Testing
@testable import Loci

@Suite("curl.md client")
struct CurlMarkdownClientTests {
    @Test("Builds an authenticated Markdown request and preserves target query and anchor")
    func buildsRequest() throws {
        let target = try #require(URL(string: "https://example.com/docs?topic=swift&mode=full#install"))
        let request = try CurlMarkdownClient.makeRequest(
            for: target,
            baseURL: URL(string: "https://curl.md"),
            objective: "installation steps",
            keywords: ["Swift", "macOS"],
            fresh: true,
            token: "curlmd_test"
        )

        let absoluteString = try #require(request.url?.absoluteString)
        #expect(absoluteString.contains("https://curl.md/https://example.com/docs%3Ftopic%3Dswift%26mode%3Dfull"))
        #expect(absoluteString.contains("anchor=install"))
        #expect(absoluteString.contains("objective=installation%20steps"))
        #expect(absoluteString.contains("keywords=Swift,macOS") || absoluteString.contains("keywords=Swift%2CmacOS"))
        #expect(absoluteString.contains("fresh=true"))
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/markdown")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer curlmd_test")
    }

    @Test("Rejects credentials and private network targets")
    func rejectsUnsafeTargets() throws {
        let localhost = try #require(URL(string: "http://127.0.0.1:8080/private"))
        let privateNetwork = try #require(URL(string: "https://192.168.1.10/wiki"))
        let ipv6Literal = try #require(URL(string: "http://[::ffff:127.0.0.1]/private"))
        let integerLoopback = try #require(URL(string: "http://2130706433/private"))
        let abbreviatedLoopback = try #require(URL(string: "http://127.1/private"))
        let carrierGradeNAT = try #require(URL(string: "http://100.64.0.1/private"))
        let trailingDotLocalhost = try #require(URL(string: "http://localhost./private"))
        let singleLabelHost = try #require(URL(string: "http://printer/private"))
        let internalHost = try #require(URL(string: "https://wiki.internal/private"))
        let signedURL = try #require(URL(string: "https://example.com/private?token=secret-value"))
        let cloudSignedURL = try #require(URL(string: "https://example.com/file?X-Amz-Signature=secret-value"))
        let oauthFragment = try #require(URL(string: "https://example.com/callback#access_token=secret-value"))
        let credentialed = try #require(URL(string: "https://user:secret@example.com"))
        let publicTarget = try #require(URL(string: "https://example.com"))

        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: localhost)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: privateNetwork)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: ipv6Literal)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: integerLoopback)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: abbreviatedLoopback)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: carrierGradeNAT)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: trailingDotLocalhost)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: singleLabelHost)
        }
        #expect(throws: CurlMarkdownError.privateTarget) {
            try CurlMarkdownClient.makeRequest(for: internalHost)
        }
        #expect(throws: CurlMarkdownError.sensitiveTarget) {
            try CurlMarkdownClient.makeRequest(for: signedURL)
        }
        #expect(throws: CurlMarkdownError.sensitiveTarget) {
            try CurlMarkdownClient.makeRequest(for: cloudSignedURL)
        }
        #expect(throws: CurlMarkdownError.sensitiveTarget) {
            try CurlMarkdownClient.makeRequest(for: oauthFragment)
        }
        #expect(throws: CurlMarkdownError.invalidTarget) {
            try CurlMarkdownClient.makeRequest(for: credentialed)
        }
        #expect(throws: CurlMarkdownError.invalidEndpoint) {
            try CurlMarkdownClient.makeRequest(
                for: publicTarget,
                baseURL: URL(string: "https://user:secret@curl.md")
            )
        }
        #expect(throws: CurlMarkdownError.invalidEndpoint) {
            try CurlMarkdownClient.makeRequest(
                for: publicTarget,
                baseURL: URL(string: "https://curl.md?debug=true")
            )
        }
    }

    @Test(
        "Fetches live Markdown from the hosted service",
        .enabled(if: ProcessInfo.processInfo.environment["LOCI_LIVE_WEB_TESTS"] == "1")
    )
    func fetchesLiveMarkdown() async throws {
        let target = try #require(URL(string: "https://example.com"))
        let result = try await CurlMarkdownClient.fetchMarkdown(for: target)

        #expect(result.markdown.localizedCaseInsensitiveContains("Example Domain"))
        #expect(result.metadata.sourceURL == target.absoluteString)
    }
}
