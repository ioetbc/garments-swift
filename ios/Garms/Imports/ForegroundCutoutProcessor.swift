import Foundation
import Vision
import CoreImage
import ImageIO
import CoreML

nonisolated enum ForegroundCutoutProcessor {
    enum CutoutError: LocalizedError {
        case invalidInput, noForeground, invalidMask, encoding, gpuUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidInput: "Background removal input could not be decoded or exceeds the 2,048-pixel limit."
            case .noForeground: "Vision detected no foreground subjects. The original image was kept."
            case .invalidMask: "Vision produced an empty, invalid or oversized foreground mask."
            case .encoding: "The foreground cutout could not be encoded as PNG."
            case .gpuUnavailable: "Vision does not offer a GPU for foreground segmentation on this device."
            }
        }
    }
    static func extract(_ source: ImportedImageDownload.Artwork,
                        diagnostic: @Sendable (String) async -> Void = { _ in }) async throws -> ImportedImageDownload.Artwork? {
        try Task.checkCancellation()
        #if targetEnvironment(simulator)
        await diagnostic("Running in iOS Simulator (\(ProcessInfo.processInfo.operatingSystemVersionString)). If Vision cannot initialise inference, test background removal on a physical iPhone.")
        #else
        await diagnostic("Vision runtime: \(ProcessInfo.processInfo.operatingSystemVersionString).")
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            var diagnostics: [String] = []
            let result = Result {
                try withInferenceRecovery(operation: { useGPU in
                    try autoreleasepool { try process(source, useGPU: useGPU) }
                }, diagnostic: { diagnostics.append($0) })
            }
            return (result, diagnostics)
        }
        // Await even after cancellation: the coordinator must not launch another
        // request while synchronous Vision work is still finishing.
        return try await withTaskCancellationHandler {
            let (result, diagnostics) = await worker.value
            try Task.checkCancellation()
            for line in diagnostics { await diagnostic(line) }
            return try result.get()
        } onCancel: {
            worker.cancel()
        }
    }

    // A fresh request/handler can recover an internal inference failure using a
    // supported GPU instead of Vision's automatic compute-device selection.
    // Never retry invalid input, missing subjects, or cancellation.
    static func withInferenceRecovery<T>(operation: (Bool) throws -> T,
                                        diagnostic: (String) -> Void) throws -> T {
        try Task.checkCancellation()
        do { return try operation(false) }
        catch {
            try Task.checkCancellation()
            let ns = error as NSError
            guard ns.domain == VNErrorDomain, ns.code == VNErrorCode.internalError.rawValue else { throw error }
            diagnostic("Vision automatic compute failed: " + ImportDiagnostics.describe(error))
            diagnostic("Retrying background removal once with a supported GPU.")
            do {
                let result = try operation(true)
                diagnostic("Vision GPU retry succeeded.")
                return result
            } catch {
                diagnostic("Vision GPU retry failed: " + ImportDiagnostics.describe(error))
                throw error
            }
        }
    }

    private static func process(_ source: ImportedImageDownload.Artwork, useGPU: Bool) throws -> ImportedImageDownload.Artwork? {
        try Task.checkCancellation()
        guard let input = CGImageSourceCreateWithData(source.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
              image.width > 0, image.height > 0, max(image.width, image.height) <= 2048 else { throw CutoutError.invalidInput }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        if useGPU {
            let devices = try request.supportedComputeStageDevices
            guard let gpu = devices[.main]?.first(where: {
                if case .gpu = $0 { return true }
                return false
            }) else { throw CutoutError.gpuUnavailable }
            request.setComputeDevice(gpu, for: .main)
        }
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw CutoutError.noForeground }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true)
        try Task.checkCancellation()
        let output = CIImage(cvPixelBuffer: buffer)
        let bounds = output.extent
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, max(bounds.width, bounds.height) <= 2048,
              let cutout = CIContext().createCGImage(output, from: bounds),
              let alpha = CanvasImageWorker.mask(cutout), alpha.bytes.contains(where: { $0 > 0 }) else { throw CutoutError.invalidMask }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CutoutError.encoding }
        CGImageDestinationAddImage(destination, cutout, nil)
        guard CGImageDestinationFinalize(destination) else { throw CutoutError.encoding }
        try Task.checkCancellation()
        return .init(data: data as Data, aspect: Double(cutout.width) / Double(cutout.height))
    }
}
