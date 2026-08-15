import UIKit

/// Result of a guided capture.
///
/// The capture keeps both the complete upright camera frame and a centered
/// crop so downstream processing (Vision segmentation, sticker rendering)
/// has every coordinate system it needs:
///
/// - `previewImage`: the complete upright photo. Use it to keep the processing
///   transition visually identical to the live aspect-fill preview.
/// - `subjectImage`: a search crop centered on the visible guide. It
///   intentionally includes a margin so an object may extend beyond the guide.
/// - `subjectRegion`: the normalized region (in the original image) that was
///   actually handed to segmentation — the guide expanded as a safety margin.
/// - `subjectSeedRegion`: the visible guide expressed in `subjectImage`
///   coordinates. Segmentation uses it as the seed for choosing one primary
///   instance rather than merging every object in the wider search image.
public struct CameraCapture {
    public let previewImage: UIImage
    public let subjectImage: UIImage
    public let subjectRegion: CGRect
    public let subjectSeedRegion: CGRect

    public init(
        previewImage: UIImage,
        subjectImage: UIImage,
        subjectRegion: CGRect,
        subjectSeedRegion: CGRect
    ) {
        self.previewImage = previewImage
        self.subjectImage = subjectImage
        self.subjectRegion = subjectRegion
        self.subjectSeedRegion = subjectSeedRegion
    }
}
