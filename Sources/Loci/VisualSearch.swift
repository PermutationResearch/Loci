import AppKit
import Vision
import Accelerate

struct VisualFeaturePrint: Hashable {
    let referenceID: UUID
    let featureData: Data

    func cosineSimilarity(with other: VisualFeaturePrint) -> Double {
        guard let a = Self.vectorFromData(featureData),
              let b = Self.vectorFromData(other.featureData),
              a.count == b.count else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(a.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return Double(dotProduct / denominator)
    }

    private static func vectorFromData(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

@MainActor
enum VisualSearch {
    static func computeFeaturePrint(for imageURL: URL) async -> VisualFeaturePrint? {
        guard let cgImage = await LociImageLoader.downsampledCGImage(from: imageURL, maxPixelSize: 1024) else {
            return nil
        }

        return await Task<VisualFeaturePrint?, Never>.detached(priority: .utility) {
            await withCheckedContinuation { (continuation: CheckedContinuation<VisualFeaturePrint?, Never>) in
                let request = VNGenerateImageFeaturePrintRequest { request, error in
                    guard error == nil,
                          let observation = request.results?.first as? VNFeaturePrintObservation else {
                        continuation.resume(returning: nil as VisualFeaturePrint?)
                        return
                    }
                    let featureData = observation.data as Data
                    continuation.resume(returning: VisualFeaturePrint(
                        referenceID: UUID(),
                        featureData: featureData
                    ))
                }

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil as VisualFeaturePrint?)
                }
            }
        }.value
    }

    static func computeFeaturePrints(for items: [ReferenceItem]) async -> [UUID: VisualFeaturePrint] {
        var results: [UUID: VisualFeaturePrint] = [:]
        let persistence = LociPersistentStore.shared

        let candidates = items.compactMap { item -> (UUID, URL)? in
            guard let fileURL = persistence?.originalsURL.appendingPathComponent(item.fileName),
                  FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return (item.id, fileURL)
        }
        let maxConcurrent = min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 2), 6)

        await withTaskGroup(of: (UUID, VisualFeaturePrint?).self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < candidates.count else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    let print = await computeFeaturePrint(for: candidate.1)
                    return (candidate.0, print)
                }
            }

            for _ in 0..<min(maxConcurrent, candidates.count) {
                enqueueNext()
            }

            while let (id, print) = await group.next() {
                if let print {
                    results[id] = print
                }
                enqueueNext()
            }
        }
        return results
    }

    static func findSimilar(
        to targetPrint: VisualFeaturePrint,
        in prints: [UUID: VisualFeaturePrint],
        threshold: Double = 0.5,
        maxResults: Int = 20
    ) -> [(UUID, Double)] {
        var similarities: [(UUID, Double)] = []

        for (id, print) in prints {
            guard id != targetPrint.referenceID else { continue }
            let similarity = targetPrint.cosineSimilarity(with: print)
            if similarity >= threshold {
                similarities.append((id, similarity))
            }
        }

        return similarities
            .sorted { $0.1 > $1.1 }
            .prefix(maxResults)
            .map { ($0.0, $0.1) }
    }

    static func searchByImage(
        queryImageURL: URL,
        allItems: [ReferenceItem],
        threshold: Double = 0.5
    ) async -> [(ReferenceItem, Double)] {
        guard let queryPrint = await computeFeaturePrint(for: queryImageURL) else { return [] }
        let allPrints = await computeFeaturePrints(for: allItems)
        let matches = findSimilar(to: queryPrint, in: allPrints, threshold: threshold)

        return matches.compactMap { id, similarity in
            guard let item = allItems.first(where: { $0.id == id }) else { return nil }
            return (item, similarity)
        }
    }
}
