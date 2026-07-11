import Foundation
import Testing
@testable import Loci

@Suite("Telemetry")
struct TelemetryTests {
    @Test("Telemetry defaults off, honors opt-in, and allowlists properties")
    func telemetryDefaultAndAllowlist() async throws {
        LociTelemetry.clearLocalQueue()
        LociTelemetry.endpointString = ""

        UserDefaults.standard.removeObject(forKey: LociTelemetry.enabledKey)
        UserDefaults.standard.removeObject(forKey: "AtlasTelemetryEnabled")
        #expect(!LociTelemetry.isEnabled)

        LociTelemetry.isEnabled = false

        LociTelemetry.record(.importCompleted, properties: [
            "source": "file",
            "count": "2"
        ])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!FileManager.default.fileExists(atPath: LociTelemetry.localQueueURL.path))

        LociTelemetry.isEnabled = true
        LociTelemetry.record(.importCompleted, properties: [
            "source": "file",
            "count": "2",
            "file_name": "private.png",
            "prompt": "private question"
        ])
        try await Task.sleep(nanoseconds: 200_000_000)

        let eventText = try String(contentsOf: LociTelemetry.localQueueURL, encoding: .utf8)
        #expect(eventText.contains("\"source\":\"file\""))
        #expect(eventText.contains("\"count\":\"2\""))
        #expect(!eventText.contains("private.png"))
        #expect(!eventText.contains("private question"))
        #expect(!eventText.contains("file_name"))
        #expect(!eventText.contains("prompt"))

        LociTelemetry.clearLocalQueue()
        LociTelemetry.isEnabled = false
    }
}
