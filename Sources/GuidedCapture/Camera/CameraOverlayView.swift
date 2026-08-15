import UIKit

/// The visible capture UI: subject guide, tip label, shutter, library button
/// and close button. Layout uses Auto Layout so it adapts to any screen size.
final class CameraOverlayView: UIView {
    private let guide = UIView()

    var guideFrame: CGRect {
        layoutIfNeeded()
        return guide.frame
    }

    init(
        frame: CGRect,
        strings: GuidedCaptureView.Strings,
        onCapture: @escaping () -> Void,
        onPick: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        // Subject guide: rounded rectangle with a thin bright edge and a soft
        // outer glow so it reads over any background.
        guide.translatesAutoresizingMaskIntoConstraints = false
        guide.layer.cornerRadius = 26
        guide.layer.cornerCurve = .continuous
        guide.layer.borderWidth = 2
        guide.layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        guide.backgroundColor = UIColor.white.withAlphaComponent(0.03)
        guide.layer.shadowColor = UIColor.white.cgColor
        guide.layer.shadowOpacity = 0.22
        guide.layer.shadowRadius = 20
        guide.layer.shadowOffset = .zero
        addSubview(guide)

        // Tip label: translucent pill above the guide.
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = strings.guideTip
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UIColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1)
        label.backgroundColor = UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 0.94)
        label.layer.cornerRadius = 17
        label.layer.masksToBounds = true
        label.layer.borderWidth = 0.5
        label.layer.borderColor = UIColor.white.cgColor
        addSubview(label)

        // Shutter: white disc with inner ring and soft shadow.
        let shutter = UIButton(type: .system)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 38
        shutter.layer.borderWidth = 4
        shutter.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        shutter.tintColor = UIColor.systemOrange
        shutter.layer.shadowColor = UIColor.black.cgColor
        shutter.layer.shadowOpacity = 0.28
        shutter.layer.shadowRadius = 10
        shutter.layer.shadowOffset = CGSize(width: 0, height: 3)
        shutter.setImage(UIImage(systemName: "camera.fill"), for: .normal)
        shutter.addAction(UIAction { _ in onCapture() }, for: .touchUpInside)
        addSubview(shutter)

        // Library: pick a photo from the library instead of shooting.
        let library = UIButton(type: .system)
        library.translatesAutoresizingMaskIntoConstraints = false
        library.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        library.layer.cornerRadius = 21
        library.tintColor = .white
        library.layer.borderWidth = 1
        library.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        library.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        library.addAction(UIAction { _ in onPick() }, for: .touchUpInside)
        library.accessibilityLabel = strings.libraryAccessibility
        addSubview(library)

        // Close: translucent dark circle with a white glyph.
        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        close.layer.cornerRadius = 21
        close.tintColor = .white
        close.layer.borderWidth = 1
        close.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.addAction(UIAction { _ in onCancel() }, for: .touchUpInside)
        addSubview(close)

        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            guide.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -55),
            guide.heightAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 1.16),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -18),
            label.widthAnchor.constraint(equalToConstant: 252),
            label.heightAnchor.constraint(equalToConstant: 34),

            shutter.centerXAnchor.constraint(equalTo: centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 76),
            shutter.heightAnchor.constraint(equalToConstant: 76),

            library.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            library.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            library.widthAnchor.constraint(equalToConstant: 42),
            library.heightAnchor.constraint(equalToConstant: 42),

            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            close.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 42),
            close.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
