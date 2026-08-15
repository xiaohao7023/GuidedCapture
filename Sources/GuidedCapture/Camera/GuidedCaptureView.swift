import SwiftUI
import UIKit

/// A full-screen AVFoundation camera with a visible subject guide, shutter,
/// photo-library picker, and cancel button.
///
/// The preview uses `resizeAspectFill` so the framing you see is exactly the
/// framing you get: the processing transition keeps the captured photo in the
/// same visual position.
///
/// ```swift
/// GuidedCaptureView(
///     onCapture: { capture in
///         // feed `capture` into `CutoutFlow`
///     },
///     onCancel: { dismiss() }
/// )
/// .ignoresSafeArea()
/// ```
public struct GuidedCaptureView: UIViewControllerRepresentable {
    /// User-visible strings. Defaults to English; localize per app.
    public struct Strings {
        public var guideTip: String
        public var libraryAccessibility: String

        public init(
            guideTip: String = "Place the subject inside the frame",
            libraryAccessibility: String = "Choose from library"
        ) {
            self.guideTip = guideTip
            self.libraryAccessibility = libraryAccessibility
        }
    }

    public let onCapture: (CameraCapture) -> Void
    public let onCancel: () -> Void
    public let strings: Strings

    public init(
        onCapture: @escaping (CameraCapture) -> Void,
        onCancel: @escaping () -> Void,
        strings: Strings = Strings()
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.strings = strings
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onCapture = onCapture
        controller.onCancel = onCancel
        controller.strings = strings
        return controller
    }

    public func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}

    public final class Coordinator: NSObject {}
}
