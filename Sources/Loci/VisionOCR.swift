import AppKit
import Vision

enum VisionOCR {
    static func extractText(from imageURL: URL) async -> String? {
        guard let cgImage = await LociImageLoader.downsampledCGImage(from: imageURL, maxPixelSize: 2200) else {
            return nil
        }
        return await recognizeText(in: cgImage)
    }

    static func extractText(fromPDF url: URL) async -> String? {
        guard let pdfDocument = PDFDocument(url: url) else { return nil }
        var allText: [String] = []

        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex) {
                let pageRect = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0
                let size = NSSize(width: pageRect.width * scale, height: pageRect.height * scale)

                let image = page.thumbnail(of: size, for: .mediaBox)
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    if let text = await recognizeText(in: cgImage), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        allText.append(text)
                    }
                }
            }
        }

        return allText.isEmpty ? nil : allText.joined(separator: "\n\n---\n\n")
    }

    static func extractText(fromImageAt path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        return await extractText(from: url)
    }

    private static func recognizeText(in cgImage: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    print("Vision OCR error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-Hans", "zh-Hant", "ko-KR"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("Vision OCR perform failed: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}

import PDFKit
