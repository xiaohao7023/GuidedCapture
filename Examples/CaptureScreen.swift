import GuidedCapture
import SwiftUI

/// A minimal, complete capture → sticker screen.
///
/// Wire this into any app: present it full screen, the user frames a subject,
/// shoots (or picks from the library), and the sticker lands on screen.
/// `CutoutFlow` runs segmentation off the main thread and falls back to the
/// raw image when no subject is found, so the flow never dead-ends.
struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var flow = CutoutFlow()
    @State private var sticker: CutoutFlow.StickerResult?
    @State private var isProcessing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let sticker {
                resultView(sticker)
            } else {
                GuidedCaptureView(
                    onCapture: { capture in
                        isProcessing = true
                        Task {
                            sticker = try? await flow.process(capture)
                            isProcessing = false
                        }
                    },
                    onCancel: { dismiss() },
                    strings: .init(
                        guideTip: "Place the subject inside the frame",
                        libraryAccessibility: "Choose from library"
                    )
                )
                .ignoresSafeArea()
            }

            if isProcessing {
                ProgressView("Cutting out…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
    }

    private func resultView(_ sticker: CutoutFlow.StickerResult) -> some View {
        VStack(spacing: 20) {
            Image(uiImage: sticker.outlined)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 360)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            Button("Retake") {
                self.sticker = nil
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.white.opacity(0.18), in: Capsule())
        }
    }
}
