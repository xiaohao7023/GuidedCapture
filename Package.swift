// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GuidedCapture",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "GuidedCapture", targets: ["GuidedCapture"])
    ],
    targets: [
        .target(
            name: "GuidedCapture",
            path: "Sources/GuidedCapture",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("PhotosUI"),
                .linkedFramework("UIKit"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
