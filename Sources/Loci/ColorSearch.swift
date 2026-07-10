import AppKit
import CoreImage
import Accelerate
import SwiftUI

struct ColorProfile: Hashable {
    let referenceID: UUID
    let dominantColors: [DominantColor]
    let averageHue: Double
    let averageSaturation: Double
    let averageBrightness: Double
}

struct DominantColor: Hashable {
    let hue: Double
    let saturation: Double
    let brightness: Double
    let percentage: Double

    var nsColor: SwiftUI.Color {
        SwiftUI.Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var hueRange: ClosedRange<Double> {
        let delta = 0.08
        return max(0, hue - delta)...min(1, hue + delta)
    }
}

@MainActor
enum ColorSearch {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func extractColorProfile(for imageURL: URL, referenceID: UUID) async -> ColorProfile? {
        guard let cgImage = await LociImageLoader.downsampledCGImage(from: imageURL, maxPixelSize: 512) else {
            return nil
        }

        return extractColorProfileSync(cgImage: cgImage, referenceID: referenceID)
    }

    private static func extractColorProfileSync(cgImage: CGImage, referenceID: UUID) -> ColorProfile? {
        let ciImage = CIImage(cgImage: cgImage)

        let kMeansColors = extractKMeansColors(from: ciImage, sampleCount: 6)
        let dominantColors = kMeansColors.map { color -> DominantColor in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor(cgColor: color)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return DominantColor(
                hue: Double(h),
                saturation: Double(s),
                brightness: Double(b),
                percentage: 1.0 / Double(max(1, kMeansColors.count))
            )
        }

        let avgHue = dominantColors.map(\.hue).reduce(0, +) / Double(max(1, dominantColors.count))
        let avgSat = dominantColors.map(\.saturation).reduce(0, +) / Double(max(1, dominantColors.count))
        let avgBri = dominantColors.map(\.brightness).reduce(0, +) / Double(max(1, dominantColors.count))

        return ColorProfile(
            referenceID: referenceID,
            dominantColors: dominantColors,
            averageHue: avgHue,
            averageSaturation: avgSat,
            averageBrightness: avgBri
        )
    }

    private static func extractKMeansColors(from ciImage: CIImage, sampleCount: Int) -> [CGColor] {
        guard let filter = CIFilter(name: "CIAreaHistogram") else { return [] }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(ciImage.extent, forKey: kCIInputExtentKey)
        filter.setValue(64, forKey: "inputHistogramCount")
        filter.setValue(1, forKey: "inputScaleFactor")

        guard let outputImage = filter.outputImage else { return [] }

        let width = Int(outputImage.extent.width)
        let height = Int(outputImage.extent.height)
        guard width > 0, height > 0 else { return [] }

        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(outputImage, toBitmap: &pixelData,
                        rowBytes: width * 4,
                        bounds: outputImage.extent,
                        format: .RGBA8,
                        colorSpace: CGColorSpaceCreateDeviceRGB())

        var colors: [CGColor] = []
        let step = max(1, pixelData.count / (sampleCount * 4))
        for i in stride(from: 0, to: pixelData.count - 3, by: step * 4) {
            let r = CGFloat(pixelData[i]) / 255.0
            let g = CGFloat(pixelData[i + 1]) / 255.0
            let b = CGFloat(pixelData[i + 2]) / 255.0
            if r > 0.01 || g > 0.01 || b > 0.01 {
                let color = CGColor(red: r, green: g, blue: b, alpha: 1)
                colors.append(color)
            }
            if colors.count >= sampleCount { break }
        }

        return colors
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b)
        return min(diff, 1.0 - diff)
    }

    static func searchByColor(
        targetHue: Double,
        targetSaturation: Double,
        targetBrightness: Double,
        profiles: [ColorProfile],
        hueWeight: Double = 0.6,
        satWeight: Double = 0.2,
        briWeight: Double = 0.2,
        maxResults: Int = 20
    ) -> [(UUID, Double)] {
        var results: [(UUID, Double)] = []

        for profile in profiles {
            let hueSim = 1.0 - hueDistance(targetHue, profile.averageHue)
            let satSim = 1.0 - abs(targetSaturation - profile.averageSaturation)
            let briSim = 1.0 - abs(targetBrightness - profile.averageBrightness)
            let score = hueSim * hueWeight + satSim * satWeight + briSim * briWeight
            results.append((profile.referenceID, score))
        }

        return results
            .sorted { $0.1 > $1.1 }
            .prefix(maxResults)
            .map { ($0.0, $0.1) }
    }

    static func dominantHueName(_ hue: Double) -> String {
        switch hue {
        case 0..<0.05, 0.95...1.0: "Red"
        case 0.05..<0.12: "Orange"
        case 0.12..<0.18: "Yellow"
        case 0.18..<0.35: "Green"
        case 0.35..<0.50: "Cyan"
        case 0.50..<0.65: "Blue"
        case 0.65..<0.75: "Purple"
        case 0.75..<0.85: "Magenta"
        case 0.85..<0.95: "Pink"
        default: "Neutral"
        }
    }
}
