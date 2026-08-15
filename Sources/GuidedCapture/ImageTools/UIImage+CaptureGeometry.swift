import UIKit

extension UIImage {
    /// Renders any camera orientation into an upright image before geometry
    /// calculations. This gives Vision and SwiftUI one coordinate system.
    public func normalizedForDisplay() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        // Preserve the source pixel dimensions. The default renderer adopts
        // the screen scale (often 3x), which can unnecessarily triple each
        // axis of a full-resolution camera photo during normalization.
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Crops the receiver to a normalized (0...1) rectangle of the original
    /// image. The rectangle is clamped to the image bounds; returns `nil` when
    /// the intersection is empty.
    public func cropped(toNormalizedRect normalizedRect: CGRect) -> UIImage? {
        guard let cgImage else { return nil }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = normalizedRect.standardized.intersection(unit)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return nil }

        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(cgImage.width),
            y: normalized.minY * CGFloat(cgImage.height),
            width: normalized.width * CGFloat(cgImage.width),
            height: normalized.height * CGFloat(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }
}
