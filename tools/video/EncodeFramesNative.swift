import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct NativeVideoEncoder {
    let framesDirectory: URL
    let outputURL: URL
    let fps: Int32
    let width: Int
    let height: Int

    func encode() throws {
        let frameURLs = try FileManager.default
            .contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("frame_") && $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !frameURLs.isEmpty else {
            throw NSError(domain: "EncodeFramesNative", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No PNG frames found in \(framesDirectory.path)"
            ])
        }

        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422LT,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "EncodeFramesNative", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter could not add video input"
            ])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw NSError(domain: "EncodeFramesNative", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "startWriting failed: \(writer.error?.localizedDescription ?? "unknown")"
            ])
        }
        writer.startSession(atSourceTime: .zero)
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw NSError(domain: "EncodeFramesNative", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter did not create a pixel buffer pool"
            ])
        }

        for (index, frameURL) in frameURLs.enumerated() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            guard let image = cgImage(at: frameURL) else {
                throw NSError(domain: "EncodeFramesNative", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Could not read \(frameURL.path)"
                ])
            }

            guard let buffer = makePixelBuffer(from: image, pool: pixelBufferPool) else {
                throw NSError(domain: "EncodeFramesNative", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Could not create pixel buffer for \(frameURL.path)"
                ])
            }

            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw NSError(domain: "EncodeFramesNative", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Could not append frame \(index): \(writer.error?.localizedDescription ?? "unknown writer error")"
                ])
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "EncodeFramesNative", code: 7)
        }
    }

    private func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: true
        ] as CFDictionary)
    }

    private func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: swift EncodeFramesNative.swift <frames-dir> <output.mp4>\n", stderr)
    exit(64)
}

do {
    let encoder = NativeVideoEncoder(
        framesDirectory: URL(fileURLWithPath: args[1]),
        outputURL: URL(fileURLWithPath: args[2]),
        fps: 24,
        width: 1920,
        height: 1080
    )
    try encoder.encode()
    print("Wrote \(args[2])")
} catch {
    fputs("EncodeFramesNative failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
