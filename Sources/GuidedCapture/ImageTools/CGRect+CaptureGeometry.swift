import UIKit

extension CGRect {
    /// Grows a normalized rectangle around its center by `factor` (≥ 1),
    /// clamped to the unit square. Used to turn the visible guide into a wider
    /// safety margin before segmentation.
    public func expandedAroundCenter(by factor: CGFloat) -> CGRect {
        let safeFactor = max(1, factor)
        let expanded = CGRect(
            x: midX - width * safeFactor / 2,
            y: midY - height * safeFactor / 2,
            width: width * safeFactor,
            height: height * safeFactor
        )
        return expanded.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Expresses this original-image rectangle inside a cropped rectangle.
    /// Both coordinate systems are normalized, top-left origin. Used to keep
    /// the guide region valid after the search crop is produced.
    public func relative(to container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let relative = CGRect(
            x: (minX - container.minX) / container.width,
            y: (minY - container.minY) / container.height,
            width: width / container.width,
            height: height / container.height
        )
        return relative.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
