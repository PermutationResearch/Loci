@preconcurrency import AppKit
@preconcurrency import CoreImage

struct VariationResult: Identifiable, Hashable {
    let id: UUID
    let sourceReferenceID: ReferenceItem.ID
    let variationType: VariationType
    let imageURL: URL
    let title: String
    let createdAt: Date
}

enum VariationType: String, CaseIterable, Hashable {
    case colorShift = "Color Shift"
    case filterApply = "Filter"
    case flipHorizontal = "Flip H"
    case rotate90 = "Rotate 90"
    case grayscale = "Grayscale"
    case sepia = "Sepia"

    var symbol: String {
        switch self {
        case .colorShift: "paintpalette.fill"
        case .filterApply: "camera.filters"
        case .flipHorizontal: "arrow.left.arrow.right"
        case .rotate90: "arrow.triangle.2.circlepath"
        case .grayscale: "circle.lefthalf.filled"
        case .sepia: "sun.max.fill"
        }
    }
}

enum VariationGenerator {
    @MainActor
    static func generateVariation(
        _ type: VariationType,
        for item: ReferenceItem,
        persistence: LociPersistentStore? = nil
    ) async -> VariationResult? {
        guard let fileURL = persistence?.originalsURL.appendingPathComponent(item.fileName),
              let cgImage = await LociImageLoader.downsampledCGImage(from: fileURL, maxPixelSize: 2400) else {
            return nil
        }

        let originalsURL = persistence?.originalsURL ?? FileManager.default.temporaryDirectory
        let sourceID = item.id
        let sourceTitle = item.title
        let typeName = type.rawValue

        return await Task.detached(priority: .utility) {
            let ciImage = CIImage(cgImage: cgImage)
            guard let outputImage = applyVariation(type, to: ciImage) else { return nil }

            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let outputCGImage = ctx.createCGImage(outputImage, from: outputImage.extent) else {
                return nil
            }

            let rep = NSBitmapImageRep(cgImage: outputCGImage)
            guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

            let fileName = "\(sourceID.uuidString.lowercased())_\(typeName.replacingOccurrences(of: " ", with: "_").lowercased()).png"
            let saveURL = originalsURL.appendingPathComponent(fileName)

            guard (try? pngData.write(to: saveURL, options: .atomic)) != nil,
                  FileManager.default.fileExists(atPath: saveURL.path) else { return nil }

            return VariationResult(
                id: UUID(),
                sourceReferenceID: sourceID,
                variationType: type,
                imageURL: saveURL,
                title: "\(sourceTitle) - \(typeName)",
                createdAt: Date()
            )
        }.value
    }

    @MainActor
    static func importVariation(_ result: VariationResult, into store: LibraryStore, undoManager: UndoManager? = nil) {
        let persistence = LociPersistentStore.shared
        let managedURL = persistence?.importFileToOriginals(from: result.imageURL)
        let fileName = managedURL?.lastPathComponent ?? result.imageURL.lastPathComponent

        store.addImportedReference(
            title: result.title,
            subtitle: "Variation",
            fileName: fileName,
            kind: .product,
            group: .file,
            aspectRatio: 1.0,
            source: .file,
            payload: managedURL?.path ?? result.imageURL.path,
            undoManager: undoManager
        )
    }

    private static func applyVariation(_ type: VariationType, to image: CIImage) -> CIImage? {
        switch type {
        case .colorShift:
            guard let f = CIFilter(name: "CIHueAdjust") else { return nil }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(Double.random(in: 0.3...0.8), forKey: kCIInputAngleKey)
            return f.outputImage
        case .filterApply:
            guard let name = ["CIPhotoEffectNoir", "CIPhotoEffectProcess", "CIPhotoEffectTonal"].randomElement(),
                  let f = CIFilter(name: name) else { return nil }
            f.setValue(image, forKey: kCIInputImageKey)
            return f.outputImage
        case .flipHorizontal:
            return image.oriented(.upMirrored)
        case .rotate90:
            return image.oriented(.right)
        case .grayscale:
            guard let f = CIFilter(name: "CIColorControls") else { return nil }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.0, forKey: kCIInputSaturationKey)
            return f.outputImage
        case .sepia:
            guard let f = CIFilter(name: "CISepiaTone") else { return nil }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.8, forKey: kCIInputIntensityKey)
            return f.outputImage
        }
    }
}
