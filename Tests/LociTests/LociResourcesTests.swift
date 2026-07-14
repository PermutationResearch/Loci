import Foundation
import Testing
@testable import Loci

@Suite("Loci resources")
struct LociResourcesTests {
    @Test("Resolves processed SwiftPM resources in development builds")
    func resolvesProcessedResources() throws {
        let iconURL = try #require(
            LociResources.url(forResource: "AppIcon", withExtension: "png")
        )
        let extractorURL = try #require(
            LociResources.url(
                forResource: "loci-extract",
                withExtension: "py",
                subdirectory: "scripts"
            )
        )

        #expect(FileManager.default.fileExists(atPath: iconURL.path))
        #expect(FileManager.default.fileExists(atPath: extractorURL.path))
    }
}
