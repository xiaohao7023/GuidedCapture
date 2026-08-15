import CoreImage
import UIKit

/// Pure post-processing helpers that turn a transparent cutout into a sticker:
/// transparent-margin cropping, alpha contour extraction (for outline
/// animations), white edge rendering, and downsampling.
public enum StickerRenderer {
    // MARK: - Transparent-margin crop

    /// Removes transparent margins from a cutout so identical camera framing
    /// produces stickers with a consistent visual scale. Adds a small padding
    /// proportional to the subject size so edges stay visually even.
    public static func cropToAlphaBounds(_ image: UIImage) -> UIImage {
        let canvas = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let source = canvas.cgImage else { return image }

        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * 4 + 3]
                guard alpha > 10 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        // A fully opaque source (for example an image where segmentation did
        // not return a mask) should remain untouched.
        guard maxX >= minX, maxY >= minY,
              let cropped = source.cropping(to: CGRect(x: minX, y: minY,
                                                         width: maxX - minX + 1,
                                                         height: maxY - minY + 1)) else {
            return image
        }

        let pad = max(4, Int(Double(max(cropped.width, cropped.height)) * 0.06))
        let cropRect = CGRect(
            x: max(0, minX - pad),
            y: max(0, minY - pad),
            width: min(width - max(0, minX - pad), maxX - minX + 1 + pad * 2),
            height: min(height - max(0, minY - pad), maxY - minY + 1 + pad * 2)
        )
        guard let padded = source.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: padded, scale: image.scale, orientation: .up)
    }

    // MARK: - Alpha contour (outline animation)

    /// Extracts the alpha foreground contour of a transparent sticker
    /// (Moore boundary tracing, pixel coordinates, y-down). Returns points
    /// sampled at a fixed step; returns `nil` when there is no foreground.
    public static func alphaOutline(
        cgImage: CGImage?,
        threshold: UInt8 = 20
    ) -> [CGPoint]? {
        guard let cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        guard let mask = alphaMask(cgImage: cgImage, threshold: threshold) else { return nil }

        func isForeground(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] == 1
        }

        // Start at the top-left-most foreground pixel.
        var start: (Int, Int)?
        outer: for y in 0..<h {
            for x in 0..<w where isForeground(x, y) {
                start = (x, y)
                break outer
            }
        }
        guard let start else { return nil }

        // Moore boundary tracing (8-neighborhood, counter-clockwise).
        let dirs: [(Int, Int)] = [
            (1, 0), (1, 1), (0, 1), (-1, 1),
            (-1, 0), (-1, -1), (0, -1), (1, -1)
        ]
        var points: [CGPoint] = []
        var current = start
        var backIndex = 4
        var guardCount = 0
        let maxCount = w * h * 2

        while guardCount < maxCount {
            points.append(CGPoint(x: current.0, y: current.1))
            guardCount += 1
            var found = false
            for step in 1...8 {
                let dir = dirs[(backIndex + step) % 8]
                let nx = current.0 + dir.0
                let ny = current.1 + dir.1
                if isForeground(nx, ny) {
                    current = (nx, ny)
                    backIndex = (backIndex + step + 4) % 8
                    found = true
                    break
                }
            }
            if !found { break }
            if current == start, points.count > 4 { break }
        }

        guard points.count > 3 else { return nil }
        // Sample simplification: keep every 3rd point and close the loop.
        var sampled: [CGPoint] = []
        for (i, p) in points.enumerated() where i % 3 == 0 {
            sampled.append(p)
        }
        if let first = sampled.first, sampled.count > 1 {
            sampled.append(first)
        }
        return sampled
    }

    /// Reads the alpha as a binary foreground mask (1 above `threshold`).
    private static func alphaMask(cgImage: CGImage, threshold: UInt8) -> [UInt8]? {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let provider = cgImage.dataProvider else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                mask[y * w + x] = pixels[y * bytesPerRow + x * 4 + 3] > threshold ? 1 : 0
            }
        }
        return mask
    }

    // MARK: - White outline (sticker edge)

    /// Adds a soft white edge along the transparent subject's contour to cover
    /// the rough segmentation border and give the image a sticker feel.
    ///
    /// Implementation: white stroke (alpha contour dilation) → solid white
    /// backing inside the contour → original image on top. The solid backing
    /// keeps semi-transparent edge pixels composited over clean white instead
    /// of over a semi-transparent white stroke, avoiding a dark halo.
    public static func whiteOutlined(_ image: UIImage, stroke requestedStroke: CGFloat? = nil) -> UIImage {
        // A fixed 8 pt floor scales larger sources to the same visual
        // proportion once persisted and downscaled.
        let stroke = requestedStroke ?? max(8, max(image.size.width, image.size.height) * 0.04)
        let pad = stroke
        let size = CGSize(width: image.size.width + pad * 2, height: image.size.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(x: pad, y: pad, width: image.size.width, height: image.size.height)
            let cg = ctx.cgContext

            // 1. White stroke: dilate the alpha mask in the transparent
            //    padding. The subject is drawn last so white stays only
            //    outside the subject, avoiding a halo.
            if let source = image.cgImage {
                let context = CIContext(options: [.priorityRequestLow: true])
                let paddedRect = CGRect(
                    x: 0, y: 0,
                    width: CGFloat(source.width) + stroke * 2 * image.scale,
                    height: CGFloat(source.height) + stroke * 2 * image.scale
                )
                let translated = CIImage(cgImage: source).transformed(
                    by: CGAffineTransform(translationX: stroke * image.scale, y: stroke * image.scale)
                )
                let clear = CIImage(color: .clear).cropped(to: paddedRect)
                let padded = translated.composited(over: clear)
                let radius = max(1, Float(stroke * image.scale))
                let dilated = padded.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
                if let output = context.createCGImage(dilated, from: paddedRect) {
                    Self.whiteFilled(UIImage(cgImage: output, scale: image.scale, orientation: .up))
                        .draw(in: CGRect(origin: .zero, size: size))
                }
            }

            // 2. Solid white backing (sourceAtop white fill preserving alpha).
            Self.whiteFilled(image).draw(in: rect)

            // 3. Original image on top.
            image.draw(in: rect)
        }
    }

    /// Paints the image white while preserving its alpha (sourceAtop: the new
    /// color only affects existing pixels).
    private static func whiteFilled(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            ctx.cgContext.saveGState()
            ctx.cgContext.setBlendMode(.sourceAtop)
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: image.size))
            ctx.cgContext.restoreGState()
        }
    }

    // MARK: - Downsampling

    /// Downscales an image so its longest side does not exceed `maxDimension`.
    /// Preserves the aspect ratio and transparency.
    public static func downsampleIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
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
}
