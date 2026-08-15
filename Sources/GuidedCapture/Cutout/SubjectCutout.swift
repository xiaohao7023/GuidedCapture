import CoreImage
import CoreVideo
import UIKit
import Vision

/// A reusable, on-device subject-cutout capability.
///
/// Input: any `UIImage`.
/// Output: a transparent-background image plus its 8-bit grayscale mask.
public actor SubjectCutout {
    public struct Configuration: Sendable {
        /// Keep the capture interaction feeling instant. Vision runs on a
        /// small working image; the original camera frame is not needed for
        /// a sticker.
        ///
        /// Quality/speed balance: 960px keeps edges sharp enough for a clean
        /// white outline while staying well under ~1s on modern devices.
        public var foregroundTimeout: TimeInterval = 0.9
        public var fallbackTimeout: TimeInterval = 0.35
        public var visionMaxDimension: CGFloat = 960
        public var edgeExpansion: Float = 1.5
        public var edgeSoftness: Float = 0.8

        public init() {}

        public static let `default` = Configuration()
    }

    public struct Result: @unchecked Sendable {
        public let image: UIImage
        public let mask: Data
        public let maskWidth: Int
        public let maskHeight: Int
        public let maskBytesPerRow: Int

        public init(
            image: UIImage,
            mask: Data,
            maskWidth: Int,
            maskHeight: Int,
            maskBytesPerRow: Int
        ) {
            self.image = image
            self.mask = mask
            self.maskWidth = maskWidth
            self.maskHeight = maskHeight
            self.maskBytesPerRow = maskBytesPerRow
        }
    }

    public enum CutoutError: LocalizedError {
        case invalidImage
        case noSubject
        case processingFailed
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .invalidImage: "无法读取图片"
            case .noSubject: "没有识别到清晰主体"
            case .processingFailed: "抠图处理失败"
            case .timedOut: "抠图处理超时"
            }
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// `seedRegion` is the camera's visible guide in normalized input-image
    /// coordinates. The selected foreground must originate there; the chosen
    /// instance may still extend beyond it as one continuous subject.
    public func process(
        _ input: UIImage,
        seedRegion: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) async throws -> Result {
        let normalized = Self.normalizeOrientation(input)
        let working = Self.downsample(normalized, maxDimension: configuration.visionMaxDimension)
        guard let source = working.cgImage else {
            throw CutoutError.invalidImage
        }

        let maskBuffer = try await generateMask(for: source, seedRegion: seedRegion)
        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let maskData = Self.extractUInt8Mask(from: maskBuffer)

        guard let rawMask = Self.makeCGImage(from: maskBuffer) else {
            throw CutoutError.processingFailed
        }

        let refinedMask = Self.refine(
            rawMask,
            expansion: configuration.edgeExpansion,
            softness: configuration.edgeSoftness
        )
        let output = try Self.apply(mask: refinedMask, to: source, scale: working.scale)

        return Result(
            image: output,
            mask: maskData,
            maskWidth: maskWidth,
            maskHeight: maskHeight,
            maskBytesPerRow: maskWidth
        )
    }

    private func generateMask(
        for image: CGImage,
        seedRegion: CGRect
    ) async throws -> CVPixelBuffer {
        do {
            return try await Self.foregroundMask(
                for: image,
                seedRegion: seedRegion,
                timeout: configuration.foregroundTimeout
            )
        } catch {
            return try await Self.saliencyFallbackMask(
                for: image,
                seedRegion: seedRegion,
                timeout: configuration.fallbackTimeout
            )
        }
    }

    private static func foregroundMask(
        for image: CGImage,
        seedRegion: CGRect,
        timeout: TimeInterval
    ) async throws -> CVPixelBuffer {
        try await runVision(timeout: timeout) { state in
            let handler = VNImageRequestHandler(cgImage: image)
            let request = VNGenerateForegroundInstanceMaskRequest { request, error in
                if let error {
                    state.finish(error: error)
                    return
                }

                guard let observation = request.results?.first as? VNInstanceMaskObservation,
                      !observation.allInstances.isEmpty else {
                    state.finish(error: CutoutError.noSubject)
                    return
                }

                do {
                    let instances = try primaryInstance(
                        in: observation,
                        seedRegion: seedRegion
                    )
                    let buffer = try observation.generateScaledMaskForImage(
                        forInstances: instances,
                        from: handler
                    )
                    state.finish(result: buffer)
                } catch {
                    state.finish(error: error)
                }
            }

            do {
                try handler.perform([request])
            } catch {
                state.finish(error: error)
            }
        }
    }

    /// Fallback for devices where the foreground instance request is
    /// unavailable or cannot isolate a subject: keeps the most salient region
    /// that overlaps the guide.
    private static func saliencyFallbackMask(
        for image: CGImage,
        seedRegion: CGRect,
        timeout: TimeInterval
    ) async throws -> CVPixelBuffer {
        try await runVision(timeout: timeout) { state in
            let handler = VNImageRequestHandler(cgImage: image)
            let request = VNGenerateAttentionBasedSaliencyImageRequest { request, error in
                if let error {
                    state.finish(error: error)
                    return
                }

                guard let observation = request.results?.first as? VNSaliencyImageObservation,
                      let objects = observation.salientObjects,
                      let object = primarySalientObject(in: objects, seedRegion: seedRegion) else {
                    state.finish(error: CutoutError.noSubject)
                    return
                }

                let box = object.boundingBox
                let rect = CGRect(
                    x: box.minX * CGFloat(image.width),
                    y: (1 - box.minY - box.height) * CGFloat(image.height),
                    width: box.width * CGFloat(image.width),
                    height: box.height * CGFloat(image.height)
                )

                do {
                    state.finish(result: try makeMask(from: rect, width: image.width, height: image.height))
                } catch {
                    state.finish(error: error)
                }
            }

            do {
                try handler.perform([request])
            } catch {
                state.finish(error: error)
            }
        }
    }

    /// Vision labels every disconnected foreground instance in one low-res
    /// buffer. Count labels only where the user placed the guide, then return
    /// the one with the largest presence there. Rendering that one label keeps
    /// all of its outside-the-guide pixels, while dropping a second item that
    /// merely happened to be in the wider search crop.
    private static func primaryInstance(
        in observation: VNInstanceMaskObservation,
        seedRegion: CGRect
    ) throws -> IndexSet {
        let mask = observation.instanceMask
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { throw CutoutError.noSubject }

        let seed = normalizedSeedRect(seedRegion)
        let xRange = pixelRange(seed.minX, seed.maxX, limit: width)
        let yRange = pixelRange(seed.minY, seed.maxY, limit: height)
        guard !xRange.isEmpty, !yRange.isEmpty else { throw CutoutError.noSubject }

        var coverage: [Int: Int] = [:]
        let instances = observation.allInstances
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else {
            throw CutoutError.processingFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        switch CVPixelBufferGetPixelFormatType(mask) {
        case kCVPixelFormatType_OneComponent32Float:
            let source = base.assumingMemoryBound(to: Float.self)
            let stride = bytesPerRow / MemoryLayout<Float>.size
            for y in yRange {
                for x in xRange {
                    let label = Int(source[y * stride + x].rounded())
                    if instances.contains(label) { coverage[label, default: 0] += 1 }
                }
            }
        case kCVPixelFormatType_OneComponent8:
            let source = base.assumingMemoryBound(to: UInt8.self)
            for y in yRange {
                for x in xRange {
                    let label = Int(source[y * bytesPerRow + x])
                    if instances.contains(label) { coverage[label, default: 0] += 1 }
                }
            }
        default:
            throw CutoutError.processingFailed
        }

        guard let primary = coverage.max(by: { $0.value < $1.value })?.key else {
            throw CutoutError.noSubject
        }
        return IndexSet(integer: primary)
    }

    private static func primarySalientObject(
        in objects: [VNRectangleObservation],
        seedRegion: CGRect
    ) -> VNRectangleObservation? {
        let seed = normalizedSeedRect(seedRegion)
        return objects.max { lhs, rhs in
            overlapArea(of: topLeftRect(for: lhs.boundingBox), with: seed)
                < overlapArea(of: topLeftRect(for: rhs.boundingBox), with: seed)
        }.flatMap { object in
            overlapArea(of: topLeftRect(for: object.boundingBox), with: seed) > 0 ? object : nil
        }
    }

    private static func normalizedSeedRect(_ rect: CGRect) -> CGRect {
        rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func pixelRange(_ start: CGFloat, _ end: CGFloat, limit: Int) -> Range<Int> {
        let lower = max(0, min(limit, Int(floor(start * CGFloat(limit)))))
        let upper = max(lower, min(limit, Int(ceil(end * CGFloat(limit)))))
        return lower..<upper
    }

    private static func topLeftRect(for visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    private static func overlapArea(of lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func runVision(
        timeout: TimeInterval,
        operation: @escaping @Sendable (VisionState) -> Void
    ) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { continuation in
            let state = VisionState()

            DispatchQueue.global(qos: .userInitiated).async {
                operation(state)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                guard state.semaphore.wait(timeout: .now() + timeout) == .success else {
                    continuation.resume(throwing: CutoutError.timedOut)
                    return
                }

                if let result = state.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: state.error ?? CutoutError.processingFailed)
                }
            }
        }
    }

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func refine(_ mask: CGImage, expansion: Float, softness: Float) -> CGImage {
        let source = CIImage(cgImage: mask)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var output = source

        if expansion > 0, let filter = CIFilter(name: "CIMorphologyMaximum") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(expansion, forKey: kCIInputRadiusKey)
            output = filter.outputImage ?? output
        }

        if softness > 0, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(softness, forKey: kCIInputRadiusKey)
            output = filter.outputImage ?? output
        }

        return context.createCGImage(output, from: source.extent) ?? mask
    }

    private static func apply(mask: CGImage, to source: CGImage, scale: CGFloat) throws -> UIImage {
        let sourceImage = CIImage(cgImage: source)
        let maskImage = CIImage(cgImage: mask)
        let transparent = CIImage(color: .clear).cropped(to: sourceImage.extent)

        guard let filter = CIFilter(name: "CIBlendWithMask") else {
            throw CutoutError.processingFailed
        }
        filter.setValue(sourceImage, forKey: kCIInputImageKey)
        filter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        filter.setValue(maskImage, forKey: kCIInputMaskImageKey)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: sourceImage.extent) else {
            throw CutoutError.processingFailed
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    private static func makeMask(from rect: CGRect, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw CutoutError.processingFailed
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)

        guard let hardMask = context.makeImage() else {
            throw CutoutError.processingFailed
        }

        let source = CIImage(cgImage: hardMask)
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(source, forKey: kCIInputImageKey)
        blur?.setValue(3, forKey: kCIInputRadiusKey)
        let output = blur?.outputImage ?? source
        guard let blurred = CIContext().createCGImage(output, from: source.extent) else {
            throw CutoutError.processingFailed
        }

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes,
            &buffer
        )
        guard let buffer else { throw CutoutError.processingFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer),
              let provider = blurred.dataProvider,
              let sourceData = provider.data else {
            throw CutoutError.processingFailed
        }

        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = sourceData as Data
        data.withUnsafeBytes { bytes in
            guard let sourceAddress = bytes.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * destinationBytesPerRow),
                    sourceAddress.advanced(by: row * width),
                    width
                )
            }
        }
        return buffer
    }

    private static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let data: Data
        let outputBytesPerRow: Int
        if format == kCVPixelFormatType_OneComponent32Float {
            let source = base.assumingMemoryBound(to: Float.self)
            var bytes = Data(count: width * height)
            bytes.withUnsafeMutableBytes { rawBuffer in
                guard let destination = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<height {
                    for x in 0..<width {
                        let value = source[y * (bytesPerRow / MemoryLayout<Float>.size) + x]
                        destination[y * width + x] = UInt8(max(0, min(255, value * 255)))
                    }
                }
            }
            data = bytes
            outputBytesPerRow = width
        } else if format == kCVPixelFormatType_OneComponent8 {
            data = Data(bytes: base, count: bytesPerRow * height)
            outputBytesPerRow = bytesPerRow
        } else {
            return nil
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: outputBytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func extractUInt8Mask(from buffer: CVPixelBuffer) -> Data {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Data(count: width * height)
        }

        var result = Data(count: width * height)
        result.withUnsafeMutableBytes { rawBuffer in
            guard let destination = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            if format == kCVPixelFormatType_OneComponent32Float {
                let source = base.assumingMemoryBound(to: Float.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let value = source[y * (bytesPerRow / MemoryLayout<Float>.size) + x]
                        destination[y * width + x] = UInt8(max(0, min(255, value * 255)))
                    }
                }
            } else {
                for y in 0..<height {
                    memcpy(destination.advanced(by: y * width), base.advanced(by: y * bytesPerRow), width)
                }
            }
        }
        return result
    }
}

private final class VisionState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var result: CVPixelBuffer?
    private(set) var error: Error?
    private var finished = false

    func finish(result: CVPixelBuffer? = nil, error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.result = result
        self.error = error
        semaphore.signal()
    }
}
