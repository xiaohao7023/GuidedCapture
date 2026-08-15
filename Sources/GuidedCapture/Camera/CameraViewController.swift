import AVFoundation
import PhotosUI
import UIKit

/// AVFoundation custom camera controller.
///
/// - Preview uses `resizeAspectFill` full-screen, matching the crop applied to
///   the captured photo so the framing never jumps between live preview and
///   processing.
/// - Supports shutter capture and photo-library selection (PHPicker, no photo
///   library permission needed).
public final class CameraViewController: UIViewController {
    var onCapture: ((CameraCapture) -> Void)?
    var onCancel: (() -> Void)?
    var strings = GuidedCaptureView.Strings()

    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoOutput: AVCapturePhotoOutput?
    private weak var cameraOverlay: CameraOverlayView?
    private var pendingRegionOfInterest: CGRect?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAndSetup()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func requestCameraAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.onCancel?()
                    }
                }
            }
        default:
            onCancel?()
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onCancel?()
            return
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            onCancel?()
            return
        }
        session.addOutput(output)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        if let connection = layer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        view.layer.addSublayer(layer)

        let overlay = CameraOverlayView(
            frame: view.bounds,
            strings: strings,
            onCapture: { [weak self] in
                guard let self, let photoOutput else { return }
                if let guideFrame = cameraOverlay?.guideFrame {
                    pendingRegionOfInterest = layer.metadataOutputRectConverted(fromLayerRect: guideFrame)
                } else {
                    pendingRegionOfInterest = nil
                }
                if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                let settings = AVCapturePhotoSettings()
                photoOutput.capturePhoto(with: settings, delegate: self)
            },
            onPick: { [weak self] in self?.presentPhotoPicker() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
        view.addSubview(overlay)
        cameraOverlay = overlay

        self.session = session
        self.previewLayer = layer
        self.photoOutput = output

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        // Keep the complete camera photo. Preview framing is only guidance;
        // drawing and Vision must operate on the original upright image.
        let upright = image.normalizedForDisplay()
        let region = pendingRegionOfInterest ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        // The guide is a starting hint, not a hard mask. Expand it before
        // Vision so a tall bottle or wide bag crossing the guide can remain
        // a complete subject while distant background stays out.
        let expandedRegion = region.expandedAroundCenter(by: 1.8)
        let subject = upright.cropped(toNormalizedRect: expandedRegion) ?? upright
        let seedRegion = region.relative(to: expandedRegion)
        pendingRegionOfInterest = nil
        onCapture?(CameraCapture(
            previewImage: upright,
            subjectImage: subject,
            subjectRegion: expandedRegion,
            subjectSeedRegion: seedRegion
        ))
    }
}

extension CameraViewController: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                let upright = image.normalizedForDisplay()
                self?.onCapture?(CameraCapture(
                    previewImage: upright,
                    subjectImage: upright,
                    subjectRegion: CGRect(x: 0, y: 0, width: 1, height: 1),
                    subjectSeedRegion: CGRect(x: 0, y: 0, width: 1, height: 1)
                ))
            }
        }
    }
}
