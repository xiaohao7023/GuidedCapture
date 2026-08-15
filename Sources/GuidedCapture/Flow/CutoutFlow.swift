import UIKit

/// A ready-made processing pipeline: capture → segmentation → sticker.
///
/// This mirrors the interaction used by a food-cabinet app:
///
/// 1. `GuidedCaptureView` produces a `CameraCapture`.
/// 2. `CutoutFlow.process` runs Vision segmentation off the main thread.
/// 3. The transparent cutout is alpha-bounds cropped, and a white outlined
///    sticker plus a normalized contour (for trace animations) are returned.
///
/// A failed segmentation falls back to the raw image so the caller can still
/// continue instead of blocking the flow.
public actor CutoutFlow {
    private let cutout: SubjectCutout

    public init(cutout: SubjectCutout = SubjectCutout()) {
        self.cutout = cutout
    }

    /// Everything a caller needs to render a sticker confirmation page.
    public struct StickerResult: Sendable {
        /// Transparent cutout with transparent margins removed, ready to save.
        public let sticker: UIImage
        /// The same sticker with a white outline applied (persist this if you
        /// want to ship the exact visual the user saw).
        public let outlined: UIImage
        /// Normalized contour points (0...1 relative to the cutout) for a
        /// "trace along the subject edge" animation. `nil` when no reliable
        /// foreground outline exists.
        public let outlinePoints: [CGPoint]?

        public init(sticker: UIImage, outlined: UIImage, outlinePoints: [CGPoint]?) {
            self.sticker = sticker
            self.outlined = outlined
            self.outlinePoints = outlinePoints
        }
    }

    /// Process a guided capture from `GuidedCaptureView`.
    public func process(_ capture: CameraCapture) async throws -> StickerResult {
        try await process(subject: capture.subjectImage, seedRegion: capture.subjectSeedRegion)
    }

    /// Process a plain image (photo-library pick, simulator demo, etc.).
    public func process(_ image: UIImage) async throws -> StickerResult {
        try await process(subject: image, seedRegion: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func process(subject: UIImage, seedRegion: CGRect) async throws -> StickerResult {
        let processor = cutout
        // Cutout + normalization run off the main thread; a failed cutout
        // falls back to the raw image so the caller can still proceed.
        let (sticker, outlined, normalized) = try await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage, [CGPoint]?) in
            let cutoutImage = (try? await processor.process(subject, seedRegion: seedRegion))?.image ?? subject
            let outline = StickerRenderer.alphaOutline(cgImage: cutoutImage.cgImage)
            let normalized = outline.map { pts in
                let w = cutoutImage.size.width
                let h = cutoutImage.size.height
                return pts.map { CGPoint(x: $0.x / w, y: $0.y / h) }
            }
            let cropped = StickerRenderer.cropToAlphaBounds(cutoutImage)
            return (cropped, StickerRenderer.whiteOutlined(cropped), normalized)
        }.value

        return StickerResult(sticker: sticker, outlined: outlined, outlinePoints: normalized)
    }
}
